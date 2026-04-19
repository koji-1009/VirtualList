#if canImport(UIKit)
  import SwiftUI
  import UIKit

  /// Owner of all mutable state that backs a single `VirtualList` instance.
  ///
  /// SwiftUI re-creates the `VirtualList` value type on every parent update but retains a
  /// single `Coordinator` for the lifetime of the representable. The data source,
  /// registrations, and fingerprint of the last snapshot all live here so rebuilding
  /// the struct costs nothing and re-rendering with identical data applies zero work.
  ///
  /// Two data-source strategies are available, chosen by `VirtualListUpdatePolicy`:
  ///
  /// - `.diffed` installs a `UICollectionViewDiffableDataSource`. Animated
  ///   inserts / deletes / moves at the cost of an O(N) snapshot build per
  ///   *structural* change. No-op re-renders are deduped by fingerprint so the
  ///   snapshot path doesn't fire when nothing changed.
  /// - `.indexed` makes the coordinator itself the `UICollectionViewDataSource`
  ///   and answers `numberOfItemsInSection` from the stored count. O(1) applies,
  ///   O(1) memory, but reloads are unanimated (`reloadData`).
  @MainActor
  public final class VirtualListCoordinator: NSObject {
    // MARK: State captured from the latest update pass

    var sections: [VirtualListSection] = []
    var configuration = VirtualListConfiguration()

    // MARK: UIKit objects

    weak var collectionView: UICollectionView?

    /// Diffable data source — only set in `.diffed` mode.
    var dataSource: UICollectionViewDiffableDataSource<AnyHashable, InternalItemID>?

    /// Cell / supplementary registrations used by the indexed data-source path.
    /// The diffable path captures its own registrations inside the cellProvider
    /// / supplementaryViewProvider closures, so it never reads these properties;
    /// we only pay the storage when the caller opts into `.indexed`.
    private var indexedCellRegistration:
      UICollectionView.CellRegistration<UICollectionViewListCell, IndexPath>?
    private var indexedHeaderRegistration:
      UICollectionView.SupplementaryRegistration<UICollectionViewListCell>?
    private var indexedFooterRegistration:
      UICollectionView.SupplementaryRegistration<UICollectionViewListCell>?

    /// Policy the collection view is currently wired up for. Changing the policy
    /// between updates forces us to rebuild the data source.
    private var installedPolicy: VirtualListUpdatePolicy?

    /// Focus binder currently attached via `.virtualListFocusCoordinator`. Kept so
    /// we can detach it before swapping in a new binder (or on teardown).
    private var attachedFocusBinder: (any VirtualListFocusBinderProtocol)?

    // MARK: Refresh

    private var refreshControl: UIRefreshControl?

    // MARK: Debug

    /// Increments each time the cell registration builds a cell. Exposed to
    /// tests / benchmarks via `@testable import`; not part of the public API.
    private(set) var cellBuildCount: Int = 0

    /// Lazily-built reverse map for `.indexed` `indexPath(forItemID:)` lookups.
    /// The first lookup after a structural apply walks the sections once; all
    /// subsequent lookups until the next apply are O(1). Callers who never
    /// round-trip through IDs (the common shape for `.indexed`, which is why
    /// the policy exists) never pay for the map.
    private var indexedIDMap: [AnyHashable: IndexPath]?

    /// All per-IndexPath state for row-level modifiers lives in these
    /// dicts. Each is populated lazily when the owning modifier's
    /// `.onAppear` fires, and cleared on structural apply so stale
    /// IndexPaths do not survive a reorder / insert. `internal` so
    /// `@testable`-importing tests can inspect them directly — there
    /// is no reason to wrap them in `debug_*` accessors.
    var perRowBoxes: [IndexPath: VirtualListRowBox] = [:]
    var perRowBackgroundHosts: [IndexPath: UIHostingController<AnyView>] = [:]
    var perRowInsets: [IndexPath: EdgeInsets] = [:]
    var perRowSeparatorVisibility: [IndexPath: VirtualListRowSeparatorVisibility] = [:]
    var perRowBadgeHosts: [IndexPath: UIHostingController<AnyView>] = [:]
    var perRowTintColors: [IndexPath: Color] = [:]

    /// Benchmark / test entry-point used via `@testable import` to pick the
    /// data-source strategy before calling `install(on:)`. Normal callers set
    /// the policy via the `.virtualListUpdatePolicy(_:)` modifier, which
    /// mutates `configuration` during SwiftUI's update pass.
    func setUpdatePolicy(_ policy: VirtualListUpdatePolicy) {
      configuration.updatePolicy = policy
    }

    /// Drop every strong reference the coordinator owns. We deliberately do
    /// NOT touch the collection view's `dataSource` / diffable state —
    /// SwiftUI calls `dismantleUIView` mid-dismiss-transition, and mutating
    /// the data source there races UIKit's own teardown into EXC_BAD_ACCESS
    /// on back-swipe.
    func tearDown(collectionView _: UICollectionView) {
      refreshControl?.removeTarget(self, action: nil, for: .allEvents)

      attachedFocusBinder?.detach()
      attachedFocusBinder = nil

      dataSource = nil
      refreshControl = nil
      indexedCellRegistration = nil
      indexedHeaderRegistration = nil
      indexedFooterRegistration = nil
      indexedIDMap = nil
      perRowBoxes.removeAll()
      perRowBackgroundHosts.removeAll()
      perRowInsets.removeAll()
      perRowSeparatorVisibility.removeAll()
      perRowBadgeHosts.removeAll()
      perRowTintColors.removeAll()
      sections = []
      lastAppliedFingerprint = []
      // Reset configuration so environment-override closures don't outlive
      // the view — they may be holding ObservableObjects passed in via
      // `.virtualListEnvironmentObject`.
      configuration = VirtualListConfiguration()
      collectionView = nil
      installedPolicy = nil
    }

    // MARK: Setup

    /// Binds the coordinator to a collection view and wires up the data
    /// source appropriate for the current update policy. Called by
    /// `VirtualList.makeUIView`; reachable from tests / benchmarks through
    /// `@testable import`.
    func install(on collectionView: UICollectionView) {
      self.collectionView = collectionView
      collectionView.delegate = self
      switch configuration.updatePolicy {
      case .diffed: installDiffed(on: collectionView)
      case .indexed: installIndexed(on: collectionView)
      }
      // Hook the custom subclass that calls us back when it attaches to a
      // window so selection / refresh / focus resolution can run against
      // a live responder chain instead of on the first-render critical
      // path. Benchmarks / tests that hand in a plain `UICollectionView`
      // skip the deferral; their call sites drive the resolve methods
      // explicitly.
      if let host = collectionView as? VirtualListHostCollectionView {
        host.viewCoordinator = self
      }
      installedPolicy = configuration.updatePolicy
    }

    /// Called by `VirtualListHostCollectionView` when its `didMoveToWindow`
    /// fires. Resolving selection / refresh / focus before a window exists
    /// is useless — there's no responder chain and no `UIWindow` to host
    /// the refresh control — and it adds work to the first-render critical
    /// path. Running it here lets `makeUIView` stay lean.
    func didAttachToWindow() {
      resolveSelection()
      resolveRefreshControl()
      resolveFocusBinder()
    }

    /// Allocates (or returns) the per-row box for an IndexPath. Called
    /// from a row modifier's `.onAppear` via the environment-injected
    /// `VirtualListRowBoxProvider`. The heavy work — class allocation,
    /// dict insertion, callback closure allocation — only runs here,
    /// so rows that never declare a row-level modifier skip it
    /// entirely and pay nothing beyond the environment struct.
    func ensureRowBox(at indexPath: IndexPath) -> VirtualListRowBox {
      if let existing = perRowBoxes[indexPath] {
        return existing
      }
      let fresh = VirtualListRowBox()
      fresh.background.onChange = { [weak self] newBackground in
        self?.applyRowBackground(newBackground, at: indexPath)
      }
      fresh.insets.onChange = { [weak self] newInsets in
        self?.applyRowInsets(newInsets, at: indexPath)
      }
      fresh.separator.onChange = { [weak self] newVisibility in
        self?.applyRowSeparatorVisibility(newVisibility, at: indexPath)
      }
      fresh.badge.onChange = { [weak self] newBadge in
        self?.applyRowBadge(newBadge, at: indexPath)
      }
      fresh.tint.onChange = { [weak self] newTint in
        self?.applyRowTint(newTint, at: indexPath)
      }
      perRowBoxes[indexPath] = fresh
      return fresh
    }

    /// Returns the swipe-actions configuration written by a per-row
    /// `.swipeActions { ... }` modifier for `indexPath`, or `nil` if none
    /// was recorded. The layout's swipe provider uses this as the primary
    /// source and falls back to the list-level
    /// `.virtualListSwipeActions(edge:actions:)` closure when absent.
    func swipeActionsConfiguration(
      for indexPath: IndexPath,
      edge: VirtualListRowSwipeEdge
    ) -> UISwipeActionsConfiguration? {
      guard let box = perRowBoxes[indexPath] else { return nil }
      let actions: [VirtualListSwipeAction]
      switch edge {
      case .leading: actions = box.leadingSwipeActions
      case .trailing: actions = box.trailingSwipeActions
      }
      guard !actions.isEmpty else { return nil }
      let contextual: [UIContextualAction] = actions.map { action in
        let ca = UIContextualAction(
          style: action.style == .destructive ? .destructive : .normal,
          title: action.title
        ) { _, _, completion in
          action.handler(indexPath, completion)
        }
        ca.backgroundColor = action.backgroundColor
        ca.image = action.image
        return ca
      }
      return UISwipeActionsConfiguration(actions: contextual)
    }

    /// Materialises the default destructive "Delete" trailing-swipe
    /// action from `.onDelete(perform:)` when no per-row or
    /// list-level trailing swipe actions were set. Returns `nil` when
    /// `.onDelete` is absent.
    ///
    /// The layout's trailing-swipe provider calls this as its final
    /// fallback so the three registration paths compose cleanly:
    /// per-row → list-level → onDelete default.
    func defaultDeleteSwipeConfiguration(
      for indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
      guard let onDelete = configuration.onDelete else { return nil }
      let action = UIContextualAction(
        style: .destructive,
        title: virtualListSystemDeleteTitle()
      ) { _, _, completion in
        onDelete(IndexSet(integer: indexPath.item))
        completion(true)
      }
      return UISwipeActionsConfiguration(actions: [action])
    }

    // MARK: Diffable path

    private func installDiffed(on collectionView: UICollectionView) {
      let cellReg = makeCellRegistration()
      let headerReg = makeHeaderRegistration()
      let footerReg = makeFooterRegistration()
      let dataSource = UICollectionViewDiffableDataSource<AnyHashable, InternalItemID>(
        collectionView: collectionView
      ) { collectionView, indexPath, _ in
        collectionView.dequeueConfiguredReusableCell(
          using: cellReg,
          for: indexPath,
          item: indexPath
        )
      }
      dataSource.supplementaryViewProvider = { cv, kind, indexPath in
        switch kind {
        case UICollectionView.elementKindSectionHeader:
          cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        case UICollectionView.elementKindSectionFooter:
          cv.dequeueConfiguredReusableSupplementary(using: footerReg, for: indexPath)
        default:
          nil
        }
      }
      dataSource.reorderingHandlers.canReorderItem = { [weak self] _ in
        self?.configuration.onMove != nil
      }
      dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
        self?.applyReorder(transaction)
      }
      self.dataSource = dataSource
    }

    private func applyDiffedSnapshot(_ newSections: [VirtualListSection], animated: Bool) {
      guard let dataSource else { return }
      var snapshot = NSDiffableDataSourceSnapshot<AnyHashable, InternalItemID>()
      snapshot.appendSections(newSections.map(\.id))
      for section in newSections {
        var ids: [InternalItemID] = []
        ids.reserveCapacity(section.itemCount)
        for i in 0..<section.itemCount {
          ids.append(InternalItemID(sectionID: section.id, itemID: section.itemID(i)))
        }
        snapshot.appendItems(ids, toSection: section.id)
      }
      dataSource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: Indexed path

    /// Wires the coordinator up as a classic `UICollectionViewDataSource`. No
    /// identifiers are materialised ahead of time; cells are produced directly
    /// from their `IndexPath`.
    private func installIndexed(on collectionView: UICollectionView) {
      dataSource = nil
      collectionView.dataSource = self
      indexedCellRegistration = makeCellRegistration()
      indexedHeaderRegistration = makeHeaderRegistration()
      indexedFooterRegistration = makeFooterRegistration()
    }

    private func applyIndexedUpdate(
      newSections: [VirtualListSection],
      oldFingerprint: [SectionFingerprint],
      newFingerprint: [SectionFingerprint],
      animated: Bool
    ) -> VirtualListApplyOutcome {
      guard let collectionView else {
        sections = newSections
        return .reloaded
      }
      guard
        let delta = tailDelta(from: oldFingerprint, to: newFingerprint)
      else {
        sections = newSections
        collectionView.reloadData()
        return .reloaded
      }
      // Surgical tail update via the classic-data-source batch path.
      //
      // `performBatchUpdates` validates its own consistency by querying the
      // data source for the row counts before and after the block. That's
      // why we assign `sections` INSIDE the block, not before — pre-setting
      // would make UIKit's "before" query see the new count and the
      // inserts/deletes would fail the `before + inserts - deletes = after`
      // check with an assertion.
      //
      // `performBatchUpdates` is animated by default; `.indexed` callers
      // who pass `animated: false` get `UIView.performWithoutAnimation`
      // wrapping so reloads stay snappy.
      let apply = {
        collectionView.performBatchUpdates({
          self.sections = newSections
          switch delta {
          case .insert(let indexPaths):
            collectionView.insertItems(at: indexPaths)
          case .remove(let indexPaths):
            collectionView.deleteItems(at: indexPaths)
          }
        })
      }
      if animated {
        apply()
      } else {
        UIView.performWithoutAnimation(apply)
      }
      return .incremental
    }

    private enum TailDelta {
      case insert([IndexPath])
      case remove([IndexPath])
    }

    /// Returns the tail-change delta as a list of inserted or removed
    /// `IndexPath`s, or `nil` when the transition isn't a pure tail change
    /// (and the caller needs to fall back to a full `reloadData`).
    private func tailDelta(
      from old: [SectionFingerprint],
      to new: [SectionFingerprint]
    ) -> TailDelta? {
      guard !old.isEmpty, old.count == new.count else { return nil }
      for i in 0..<(old.count - 1) where old[i] != new[i] {
        return nil
      }
      let lastOld = old[old.count - 1]
      let lastNew = new[new.count - 1]
      guard lastOld.id == lastNew.id, lastOld.itemCount != lastNew.itemCount else {
        return nil
      }
      let section = old.count - 1
      if lastNew.itemCount > lastOld.itemCount {
        let paths = (lastOld.itemCount..<lastNew.itemCount).map {
          IndexPath(item: $0, section: section)
        }
        return .insert(paths)
      } else {
        let paths = (lastNew.itemCount..<lastOld.itemCount).map {
          IndexPath(item: $0, section: section)
        }
        return .remove(paths)
      }
    }

    // MARK: Cell registrations

    private func makeCellRegistration()
      -> UICollectionView.CellRegistration<UICollectionViewListCell, IndexPath>
    {
      UICollectionView.CellRegistration<UICollectionViewListCell, IndexPath> {
        [weak self] cell, indexPath, _ in
        self?.configure(cell: cell, at: indexPath)
      }
    }

    /// Re-runs cell configuration for every visible cell. Used on updateUIView to
    /// propagate environment changes that don't show up as snapshot diffs.
    func reconfigureVisibleCells() {
      guard let collectionView else { return }
      for cell in collectionView.visibleCells {
        guard let listCell = cell as? UICollectionViewListCell,
          let indexPath = collectionView.indexPath(for: listCell)
        else { continue }
        configure(cell: listCell, at: indexPath)
      }
    }

    private func configure(cell: UICollectionViewListCell, at indexPath: IndexPath) {
      guard indexPath.section < sections.count else { return }
      let section = sections[indexPath.section]
      guard indexPath.item < section.itemCount else { return }
      cellBuildCount &+= 1

      let rawView = section.itemView(indexPath.item)
      let decorated = decorate(view: rawView)

      // Inject the provider so row modifiers can lazily allocate their
      // box on the first `.onAppear`. Rows with no modifier keep the
      // box path dormant.
      let provider = VirtualListRowBoxProvider(coordinator: self, indexPath: indexPath)
      let hostedContent = decorated.environment(\.virtualListRowBoxProvider, provider)
      var hostingConfig: UIHostingConfiguration<AnyView, EmptyView>
      if let fixed = configuration.fixedRowHeight {
        hostingConfig = UIHostingConfiguration {
          AnyView(hostedContent.frame(height: fixed))
        }
      } else {
        hostingConfig = UIHostingConfiguration {
          AnyView(hostedContent)
        }
      }
      if let insets = perRowInsets[indexPath] {
        hostingConfig = hostingConfig.margins(.top, insets.top)
        hostingConfig = hostingConfig.margins(.bottom, insets.bottom)
        hostingConfig = hostingConfig.margins(.leading, insets.leading)
        hostingConfig = hostingConfig.margins(.trailing, insets.trailing)
      }
      cell.contentConfiguration = hostingConfig

      // Rebind cached background on reuse — the modifier `.onAppear`
      // may not fire again for a recycled cell. Skip the `= nil` branch
      // when no row anywhere has a background, since assigning
      // `backgroundConfiguration` on every reconfigure triggers
      // non-trivial UIKit work.
      if let cached = perRowBackgroundHosts[indexPath] {
        applyBackgroundConfiguration(on: cell, using: cached)
      } else if !perRowBackgroundHosts.isEmpty {
        cell.backgroundConfiguration = nil
      }

      // Rebind an existing badge for this IndexPath on reconfigure.
      // Assemble the trailing accessory set — badge for this row (if
      // any) plus a reorder handle when the list declared an
      // `.virtualListReorder` handler. Without the handle the user
      // has no visible drag affordance; the long-press gesture would
      // still trigger reorder but nothing on screen signals that.
      // Fast-path stays in place: if no row anywhere declares either
      // a badge or reorder, skip the `cell.accessories` assignment so
      // we don't pay UIKit invalidation per reconfigure.
      applyAccessories(on: cell, at: indexPath)

      // Rebind the per-row tint the accessory pass above reads from.
      // `applyAccessories` intentionally runs first so the tint is
      // applied after the reorder handle is in place (the handle
      // picks up `tintColor` at draw time, so ordering only affects
      // readability). Cache-empty fast path skips the property
      // assignment entirely for lists with no `.listItemTint` anywhere.
      if let cached = perRowTintColors[indexPath] {
        cell.tintColor = UIColor(cached)
      } else if !perRowTintColors.isEmpty {
        cell.tintColor = nil
      }
    }

    /// Rebuilds the cell's trailing accessory set from current state —
    /// badge host (if any) + reorder handle (when onMove is set).
    /// Both `configure(cell:at:)` and `applyRowBadge` route through
    /// here so `cell.accessories` is never stamped with just one of
    /// the two, which would wipe out the other.
    private func applyAccessories(
      on cell: UICollectionViewListCell,
      at indexPath: IndexPath
    ) {
      let reorderEnabled = configuration.onMove != nil
      var accessories: [UICellAccessory] = []
      if let cachedBadge = perRowBadgeHosts[indexPath] {
        accessories.append(badgeAccessory(for: cachedBadge))
      }
      if reorderEnabled {
        accessories.append(.reorder(displayed: .always))
      }
      if !perRowBadgeHosts.isEmpty || reorderEnabled {
        cell.accessories = accessories
      }
    }

    /// Installs / updates the hosting controller that backs the cell's
    /// background, or tears it down when `view` is nil.
    private func applyRowBackground(_ view: AnyView?, at indexPath: IndexPath) {
      guard let collectionView,
        let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
      else { return }
      if let view {
        let host: UIHostingController<AnyView>
        if let existing = perRowBackgroundHosts[indexPath] {
          existing.rootView = view
          host = existing
        } else {
          // `sizingOptions` lets the hosting view size itself without a
          // parent VC — its `view` is used as a `customView`, not
          // attached as a child.
          let fresh = UIHostingController(rootView: view)
          fresh.sizingOptions = [.preferredContentSize]
          fresh.view.backgroundColor = .clear
          perRowBackgroundHosts[indexPath] = fresh
          host = fresh
        }
        applyBackgroundConfiguration(on: cell, using: host)
      } else {
        perRowBackgroundHosts.removeValue(forKey: indexPath)
        cell.backgroundConfiguration = nil
      }
    }

    private func applyBackgroundConfiguration(
      on cell: UICollectionViewListCell,
      using host: UIHostingController<AnyView>
    ) {
      var config = UIBackgroundConfiguration.listPlainCell()
      config.customView = host.view
      cell.backgroundConfiguration = config
    }

    /// Fires on a `.badge(_:)` commit. Updates the per-IndexPath host
    /// dict and re-composes the full accessory set so a concurrent
    /// reorder handle survives the rebuild.
    private func applyRowBadge(_ view: AnyView?, at indexPath: IndexPath) {
      guard let collectionView,
        let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
      else { return }
      if let view {
        if let existing = perRowBadgeHosts[indexPath] {
          existing.rootView = view
        } else {
          let fresh = UIHostingController(rootView: view)
          fresh.sizingOptions = [.preferredContentSize]
          fresh.view.backgroundColor = .clear
          perRowBadgeHosts[indexPath] = fresh
        }
      } else {
        perRowBadgeHosts.removeValue(forKey: indexPath)
      }
      applyAccessories(on: cell, at: indexPath)
    }

    private func badgeAccessory(for host: UIHostingController<AnyView>) -> UICellAccessory {
      let config = UICellAccessory.CustomViewConfiguration(
        customView: host.view,
        placement: .trailing(displayed: .always)
      )
      return .customView(configuration: config)
    }

    /// Caches the tint and writes it onto the cell. UIKit's
    /// `UICellAccessory.reorder` and default swipe-action icons read
    /// `cell.tintColor`; the SwiftUI content cascade (`.tint(_:)`) is
    /// applied separately inside the modifier, so this handler only
    /// needs to touch the UIKit side. The previous-value guard matches
    /// `applyRowInsets`'s callback-loop break.
    private func applyRowTint(_ tint: Color?, at indexPath: IndexPath) {
      let previous = perRowTintColors[indexPath]
      guard previous != tint else { return }
      if let tint {
        perRowTintColors[indexPath] = tint
      } else {
        perRowTintColors.removeValue(forKey: indexPath)
      }
      guard let collectionView,
        let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
      else { return }
      cell.tintColor = tint.map { UIColor($0) }
    }

    /// Caches the new insets and reconfigures the cell. The previous-
    /// value guard breaks the callback loop: `configure` reinstalls a
    /// fresh hosted view whose modifier fires `.onAppear` and re-commits
    /// the same value, which this short-circuits.
    private func applyRowInsets(_ insets: EdgeInsets?, at indexPath: IndexPath) {
      guard let collectionView,
        let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
      else { return }
      let previous = perRowInsets[indexPath]
      guard previous != insets else { return }
      if let insets {
        perRowInsets[indexPath] = insets
      } else {
        perRowInsets.removeValue(forKey: indexPath)
      }
      configure(cell: cell, at: indexPath)
    }

    /// Caches the visibility and invalidates just this item so the
    /// layout re-queries `itemSeparatorHandler`. The previous-value
    /// guard avoids layout invalidation on redundant commits.
    private func applyRowSeparatorVisibility(
      _ visibility: VirtualListRowSeparatorVisibility?,
      at indexPath: IndexPath
    ) {
      let previous = perRowSeparatorVisibility[indexPath]
      guard previous != visibility else { return }
      if let visibility {
        perRowSeparatorVisibility[indexPath] = visibility
      } else {
        perRowSeparatorVisibility.removeValue(forKey: indexPath)
      }
      guard let collectionView else { return }
      let context = UICollectionViewLayoutInvalidationContext()
      context.invalidateItems(at: [indexPath])
      collectionView.collectionViewLayout.invalidateLayout(with: context)
    }

    /// Returns the cached separator-visibility override for the given
    /// IndexPath, or `nil` when no `.listRowSeparator(_:edges:)`
    /// modifier has fired for the row. Read by the layout's
    /// `itemSeparatorHandler`.
    func rowSeparatorVisibility(
      at indexPath: IndexPath
    ) -> VirtualListRowSeparatorVisibility? {
      perRowSeparatorVisibility[indexPath]
    }

    private func makeHeaderRegistration()
      -> UICollectionView.SupplementaryRegistration<UICollectionViewListCell>
    {
      UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
        elementKind: UICollectionView.elementKindSectionHeader
      ) { [weak self] view, _, indexPath in
        guard let self,
          indexPath.section < self.sections.count,
          let header = sections[indexPath.section].header
        else {
          view.contentConfiguration = nil
          return
        }
        let built = header()
        let decorated = decorate(view: built)
        view.contentConfiguration = UIHostingConfiguration { decorated }
      }
    }

    private func makeFooterRegistration()
      -> UICollectionView.SupplementaryRegistration<UICollectionViewListCell>
    {
      UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
        elementKind: UICollectionView.elementKindSectionFooter
      ) { [weak self] view, _, indexPath in
        guard let self,
          indexPath.section < self.sections.count,
          let footer = sections[indexPath.section].footer
        else {
          view.contentConfiguration = nil
          return
        }
        let built = footer()
        let decorated = decorate(view: built)
        view.contentConfiguration = UIHostingConfiguration { decorated }
      }
    }

    // MARK: Environment forwarding

    /// Wraps the caller's view with user-supplied environment overrides.
    ///
    /// We deliberately do *not* forward standard `EnvironmentValues` from the
    /// representable's context. Values backed by `UITraitCollection`
    /// (colorScheme, layoutDirection, dynamicTypeSize, displayScale, locale…)
    /// already propagate into `UIHostingConfiguration` through the cell's trait
    /// chain. Wrapping every hosted view in 10 nested `AnyView.environment(...)`
    /// calls just to re-insert values UIKit already inherited is pure waste on
    /// a hot path that runs for every visible cell on every re-render.
    ///
    /// Values that *don't* propagate through traits (parent `.font`, `.disabled`,
    /// custom `EnvironmentKey`s, `ObservableObject`s) are opt-in via
    /// `.virtualListEnvironment(_:_:)` and `.virtualListEnvironmentObject(_:)`.
    private func decorate(view: AnyView) -> AnyView {
      guard !configuration.environmentOverrides.isEmpty else { return view }
      var wrapped = view
      for override in configuration.environmentOverrides {
        wrapped = override.apply(wrapped)
      }
      return wrapped
    }

    // MARK: Snapshot application

    /// Identity fingerprint of the last snapshot we pushed to the data source.
    /// Pair of `(section id, item count)` per section. We refuse to rebuild the
    /// snapshot when SwiftUI re-renders with the same structure — diffable's
    /// snapshot construction is O(N) and naïvely running it on every parent
    /// state change turns a 1M-row list into a 66ms/update tax the user's CPU
    /// pays for no reason.
    private var lastAppliedFingerprint: [SectionFingerprint] = []

    private struct SectionFingerprint: Equatable {
      let id: AnyHashable
      let itemCount: Int
    }

    /// Applies a fresh set of sections to the data source. Called from
    /// `VirtualList.updateUIView`; reachable from tests / benchmarks
    /// through `@testable import`.
    ///
    /// The returned outcome tells the caller whether the apply already
    /// re-dequeued every visible cell (in which case running
    /// `reconfigureVisibleCells` on top would be redundant) or only a subset
    /// (so the caller must still reconfigure remaining visible cells to
    /// propagate freshly-captured closure state).
    @discardableResult
    func apply(
      sections newSections: [VirtualListSection],
      animated: Bool
    ) -> VirtualListApplyOutcome {
      let priorFingerprint = lastAppliedFingerprint

      // If the SwiftUI-level policy changed since last install, rewire the data
      // source before pushing data through it. The policy-change install path
      // reads `sections`, so it needs the updated array right away.
      let policyChanged = installedPolicy != configuration.updatePolicy
      if policyChanged, let cv = collectionView {
        sections = newSections
        install(on: cv)
      }

      let nextFingerprint = newSections.map {
        SectionFingerprint(id: $0.id, itemCount: $0.itemCount)
      }
      let structureChanged = policyChanged || nextFingerprint != priorFingerprint
      guard structureChanged else {
        // Structure identical. Assign now so in-place closure-state changes
        // that the fingerprint can't observe still show up when the caller
        // runs `reconfigureVisibleCells` next.
        sections = newSections
        return .unchanged
      }
      lastAppliedFingerprint = nextFingerprint
      // Structural change invalidates the lazy `.indexed` reverse map and
      // the per-row state — an inserted row shifts following IndexPaths,
      // so entries keyed by the old paths are no longer valid.
      indexedIDMap = nil
      perRowBoxes.removeAll(keepingCapacity: true)
      perRowBackgroundHosts.removeAll(keepingCapacity: true)
      perRowInsets.removeAll(keepingCapacity: true)
      perRowSeparatorVisibility.removeAll(keepingCapacity: true)
      perRowBadgeHosts.removeAll(keepingCapacity: true)
      perRowTintColors.removeAll(keepingCapacity: true)

      switch configuration.updatePolicy {
      case .diffed:
        // Diffable apply only dequeues items whose identifiers are new —
        // existing visible cells stay in place, so this is incremental.
        sections = newSections
        applyDiffedSnapshot(newSections, animated: animated)
        return .incremental
      case .indexed:
        if policyChanged {
          // Data source just rewired — no prior state is valid, so a full
          // reload is mandatory. `sections` was already updated above.
          collectionView?.reloadData()
          return .reloaded
        }
        return applyIndexedUpdate(
          newSections: newSections,
          oldFingerprint: priorFingerprint,
          newFingerprint: nextFingerprint,
          animated: animated
        )
      }
    }

    // MARK: Reorder application (diffable only)

    private func applyReorder(
      _ transaction: NSDiffableDataSourceTransaction<AnyHashable, InternalItemID>
    ) {
      guard let onMove = configuration.onMove else { return }
      let initial = transaction.initialSnapshot
      let final = transaction.finalSnapshot

      var initialIndex: [InternalItemID: IndexPath] = [:]
      for (sIdx, sectionID) in initial.sectionIdentifiers.enumerated() {
        for (iIdx, itemID) in initial.itemIdentifiers(inSection: sectionID).enumerated() {
          initialIndex[itemID] = IndexPath(item: iIdx, section: sIdx)
        }
      }
      for (sIdx, sectionID) in final.sectionIdentifiers.enumerated() {
        for (iIdx, itemID) in final.itemIdentifiers(inSection: sectionID).enumerated() {
          let finalIP = IndexPath(item: iIdx, section: sIdx)
          if let initialIP = initialIndex[itemID], initialIP != finalIP {
            onMove(initialIP, finalIP)
            return
          }
        }
      }
    }

    // MARK: Selection

    func resolveSelection() {
      guard let collectionView, let box = configuration.selectionBox else {
        collectionView?.allowsSelection = false
        collectionView?.allowsMultipleSelection = false
        return
      }
      let desired = box.read()
      collectionView.allowsSelection = box.allowsSelection
      collectionView.allowsMultipleSelection = box.allowsMultipleSelection

      let currentIndexPaths = collectionView.indexPathsForSelectedItems ?? []
      let currentIDs = Set(currentIndexPaths.compactMap { itemID(at: $0) })
      let toDeselect = currentIDs.subtracting(desired)
      let toSelect = desired.subtracting(currentIDs)
      for id in toDeselect {
        if let ip = indexPath(forItemID: id) {
          collectionView.deselectItem(at: ip, animated: false)
        }
      }
      for id in toSelect {
        if let ip = indexPath(forItemID: id) {
          collectionView.selectItem(at: ip, animated: false, scrollPosition: [])
        }
      }
    }

    // MARK: Focus binder

    /// Attaches the focus binder from the latest configuration, detaching the
    /// previous one if it changed. Called from updateUIView / makeUIView.
    func resolveFocusBinder() {
      let next = configuration.focusBinder
      let nextIsSame: Bool = {
        guard let next, let attached = attachedFocusBinder else {
          return next == nil && attachedFocusBinder == nil
        }
        return ObjectIdentifier(next) == ObjectIdentifier(attached)
      }()
      if nextIsSame { return }
      attachedFocusBinder?.detach()
      attachedFocusBinder = next
      next?.attachScrollHandler { [weak self] id in
        self?.scroll(toFocusedID: id)
      }
    }

    // MARK: Refresh

    func resolveRefreshControl() {
      guard let collectionView else { return }
      if configuration.refreshAction != nil {
        if refreshControl == nil {
          let rc = UIRefreshControl()
          rc.addTarget(self, action: #selector(refreshTriggered), for: .valueChanged)
          refreshControl = rc
          collectionView.refreshControl = rc
        }
      } else if refreshControl != nil {
        collectionView.refreshControl = nil
        refreshControl = nil
      }
    }

    @objc private func refreshTriggered() {
      guard let action = configuration.refreshAction, let refreshControl else { return }
      Task { @MainActor in
        await action()
        refreshControl.endRefreshing()
      }
    }

    // MARK: IndexPath <-> ID helpers

    func itemID(at indexPath: IndexPath) -> AnyHashable? {
      switch configuration.updatePolicy {
      case .diffed:
        return dataSource?.itemIdentifier(for: indexPath)?.itemID
      case .indexed:
        guard indexPath.section < sections.count else { return nil }
        let section = sections[indexPath.section]
        guard indexPath.item < section.itemCount else { return nil }
        return section.itemID(indexPath.item)
      }
    }

    func indexPath(forItemID itemID: AnyHashable) -> IndexPath? {
      switch configuration.updatePolicy {
      case .diffed:
        // We iterate section IDs from our own `sections` array instead of
        // `dataSource.snapshot().sectionIdentifiers` — calling
        // `dataSource.snapshot()` copies the *entire* snapshot (all N items)
        // just to get a list of section identifiers. We already have those.
        guard let dataSource else { return nil }
        for section in sections {
          let probe = InternalItemID(sectionID: section.id, itemID: itemID)
          if let ip = dataSource.indexPath(for: probe) {
            return ip
          }
        }
        return nil
      case .indexed:
        // First lookup after a structural apply builds the reverse map
        // (O(N)); subsequent lookups are O(1). Amortises to O(1) when the
        // caller performs multiple lookups — e.g. synchronising an
        // N-element selection binding — without forcing `.indexed` apply
        // itself to leave its O(1) contract.
        if indexedIDMap == nil {
          var map: [AnyHashable: IndexPath] = [:]
          var total = 0
          for section in sections { total += section.itemCount }
          map.reserveCapacity(total)
          for (sIdx, section) in sections.enumerated() {
            for i in 0..<section.itemCount {
              map[section.itemID(i)] = IndexPath(item: i, section: sIdx)
            }
          }
          indexedIDMap = map
        }
        return indexedIDMap?[itemID]
      }
    }
  }

  // MARK: - VirtualListRowBoxHost

  extension VirtualListCoordinator: VirtualListRowBoxHost {}

  // MARK: - UICollectionViewDelegate

  extension VirtualListCoordinator: UICollectionViewDelegate {
    public func collectionView(
      _: UICollectionView,
      didSelectItemAt indexPath: IndexPath
    ) {
      guard let box = configuration.selectionBox else { return }
      if box.allowsMultipleSelection {
        var current = box.read()
        if let id = itemID(at: indexPath) { current.insert(id) }
        box.write(current)
      } else {
        if let id = itemID(at: indexPath) { box.write([id]) }
      }
    }

    public func collectionView(
      _: UICollectionView,
      didDeselectItemAt indexPath: IndexPath
    ) {
      guard let box = configuration.selectionBox, box.allowsMultipleSelection else { return }
      var current = box.read()
      if let id = itemID(at: indexPath) { current.remove(id) }
      box.write(current)
    }

    /// Frees the heavy per-IndexPath state when a cell leaves the
    /// viewport. Without this hook, scrolling through a large list
    /// monotonically grows `perRowBoxes` and the two hosting-controller
    /// dicts — 100k scrolled rows would keep 100k of each alive until
    /// the next structural apply. The lightweight value caches
    /// (`perRowInsets`, `perRowSeparatorVisibility`) stay so a scroll-
    /// back doesn't flicker through the default margins / separator
    /// between re-dequeue and the modifier's `.onAppear`.
    public func collectionView(
      _: UICollectionView,
      didEndDisplaying _: UICollectionViewCell,
      forItemAt indexPath: IndexPath
    ) {
      perRowBoxes.removeValue(forKey: indexPath)
      perRowBackgroundHosts.removeValue(forKey: indexPath)
      perRowBadgeHosts.removeValue(forKey: indexPath)
    }
  }

  // MARK: - UICollectionViewDataSource (indexed path only)

  extension VirtualListCoordinator: UICollectionViewDataSource {
    public func numberOfSections(in _: UICollectionView) -> Int {
      sections.count
    }

    public func collectionView(
      _: UICollectionView,
      numberOfItemsInSection section: Int
    ) -> Int {
      guard section < sections.count else { return 0 }
      return sections[section].itemCount
    }

    public func collectionView(
      _ collectionView: UICollectionView,
      cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
      guard let registration = indexedCellRegistration else {
        return UICollectionViewCell()
      }
      return collectionView.dequeueConfiguredReusableCell(
        using: registration,
        for: indexPath,
        item: indexPath
      )
    }

    public func collectionView(
      _ collectionView: UICollectionView,
      viewForSupplementaryElementOfKind kind: String,
      at indexPath: IndexPath
    ) -> UICollectionReusableView {
      switch kind {
      case UICollectionView.elementKindSectionHeader:
        if let reg = indexedHeaderRegistration {
          return collectionView.dequeueConfiguredReusableSupplementary(using: reg, for: indexPath)
        }
      case UICollectionView.elementKindSectionFooter:
        if let reg = indexedFooterRegistration {
          return collectionView.dequeueConfiguredReusableSupplementary(using: reg, for: indexPath)
        }
      default:
        break
      }
      return UICollectionReusableView()
    }

    public func collectionView(
      _: UICollectionView,
      canMoveItemAt _: IndexPath
    ) -> Bool {
      configuration.onMove != nil
    }

    public func collectionView(
      _: UICollectionView,
      moveItemAt sourceIndexPath: IndexPath,
      to destinationIndexPath: IndexPath
    ) {
      configuration.onMove?(sourceIndexPath, destinationIndexPath)
    }
  }
#endif
