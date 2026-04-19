#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import SwiftUI

  /// AppKit counterpart of `VirtualListCoordinator`, backed by `NSTableView`.
  ///
  /// `NSTableView` is macOS's optimised primitive for list-shaped data. Its
  /// `reloadData()` is O(visible) and variable row heights are virtualised
  /// natively via `usesAutomaticRowHeights`. That gets AppKit out of the way
  /// so the library's O(1) apply path holds end-to-end on macOS.
  ///
  /// Sections are modelled by flattening header / items / footer into a flat
  /// row index. A binary search over section offsets maps a table row back
  /// to a `RowKind`, keeping per-query cost O(log sections) regardless of
  /// item count.
  @MainActor
  public final class VirtualListMacCoordinator: NSObject {
    // MARK: State

    var sections: [VirtualListSection] = []
    var configuration = VirtualListConfiguration()

    weak var tableView: NSTableView?

    private var attachedFocusBinder: (any VirtualListFocusBinderProtocol)?

    /// Cumulative row offsets per section, computed on apply. Enables O(log
    /// sections) row ↔ (section, item) mapping.
    private struct SectionRowInfo {
      let startRow: Int
      let hasHeader: Bool
      let itemCount: Int
      let hasFooter: Bool
      var totalRows: Int { (hasHeader ? 1 : 0) + itemCount + (hasFooter ? 1 : 0) }
    }

    private var sectionRowInfo: [SectionRowInfo] = []
    private(set) var totalRowCount: Int = 0

    /// Item ID → IndexPath map, populated on `.diffed` applies so
    /// `indexPath(forItemID:)` is O(1). Not populated on `.indexed`
    /// (matches UIKit's behaviour: `.indexed` trades fast apply for
    /// linear lookup). `nil` means "not built for the current apply".
    private var idIndex: [AnyHashable: IndexPath]?

    enum RowKind {
      case header(section: Int)
      case item(section: Int, index: Int)
      case footer(section: Int)
    }

    /// Per-apply identity. We dedup redundant applies by comparing the
    /// fingerprint instead of rebuilding the table content.
    private struct SectionFingerprint: Equatable {
      let id: AnyHashable
      let itemCount: Int
      let hasHeader: Bool
      let hasFooter: Bool
    }

    private var lastAppliedFingerprint: [SectionFingerprint] = []

    /// Per-IndexPath row-modifier state, populated lazily when the
    /// owning modifier's `.onAppear` fires and cleared on structural
    /// apply. The cached views/insets/visibility are re-applied on
    /// cell re-configuration so a row scrolled back into view doesn't
    /// flicker through the default.
    // `internal` (no access modifier) so `@testable` tests can read
    // these directly. There's no production caller outside the class.
    var perRowBoxes: [IndexPath: VirtualListRowBox] = [:]
    var perRowBackgroundViews: [IndexPath: AnyView] = [:]
    var perRowInsets: [IndexPath: EdgeInsets] = [:]
    var perRowBadgeViews: [IndexPath: AnyView] = [:]
    var perRowSeparatorVisibility: [IndexPath: VirtualListRowSeparatorVisibility] = [:]

    /// Increments each time the cell registration builds a cell. Exposed to
    /// tests / benchmarks via `@testable import`; not part of the public API.
    private(set) var cellBuildCount: Int = 0

    func setUpdatePolicy(_ policy: VirtualListUpdatePolicy) {
      // The macOS coordinator stores the policy on `configuration` only;
      // `apply` decides per-call whether to eager-build the id-index
      // (`.diffed`) or keep it lazy (`.indexed`). The structural-update
      // path (`insertRows` / `removeRows` / `reloadData`) is the same on
      // both policies — only the lookup contract differs.
      configuration.updatePolicy = policy
    }

    // MARK: Setup

    func install(on tableView: NSTableView) {
      self.tableView = tableView
      tableView.delegate = self
      tableView.dataSource = self
      // Register the internal pasteboard type so `.virtualListReorder`
      // can pick up drag sources originating in this table. Drops are
      // rejected unless the source is this same table, so the type's
      // presence doesn't affect outside drag-and-drop.
      tableView.registerForDraggedTypes([Self.reorderPasteboardType])
      tableView.headerView = nil
      tableView.rowSizeStyle = .custom
      tableView.intercellSpacing = NSSize(width: 0, height: 0)
      tableView.gridStyleMask = []
      tableView.backgroundColor = .clear
      tableView.style = .plain
      tableView.selectionHighlightStyle = .regular
      if tableView.tableColumns.isEmpty {
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        column.width = max(tableView.bounds.width, 320)
        tableView.addTableColumn(column)
      }
      applyRowSizing(on: tableView)
      // Hook the custom subclass that calls us back when it attaches to a
      // window so we can finish selection / focus resolution against a live
      // responder chain.
      if let host = tableView as? VirtualListHostTableView {
        host.macCoordinator = self
      }
    }

    /// Chooses `usesAutomaticRowHeights` vs `rowHeight` based on whether the
    /// caller has declared a fixed row height. When height is known up front
    /// AppKit skips the per-row `fittingSize` measurement pass entirely —
    /// that pass runs on every `insertRows` / `noteNumberOfRowsChanged`, so
    /// declaring a height makes repeated structural updates substantially
    /// cheaper.
    private func applyRowSizing(on tableView: NSTableView) {
      if let fixed = configuration.fixedRowHeight {
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = fixed
      } else {
        tableView.usesAutomaticRowHeights = true
      }
    }

    /// SwiftUI-path counterpart: called from `updateNSView` when the caller
    /// may have flipped `fixedRowHeight` between updates.
    func refreshRowSizing(on tableView: NSTableView) {
      applyRowSizing(on: tableView)
    }

    static let columnIdentifier = NSUserInterfaceItemIdentifier("VirtualList.Column")
    static let itemIdentifier = NSUserInterfaceItemIdentifier("VirtualList.Item")
    static let headerIdentifier = NSUserInterfaceItemIdentifier("VirtualList.Header")
    static let footerIdentifier = NSUserInterfaceItemIdentifier("VirtualList.Footer")

    // MARK: Apply

    @discardableResult
    func apply(
      sections newSections: [VirtualListSection],
      animated: Bool
    ) -> VirtualListApplyOutcome {
      let oldFingerprint = lastAppliedFingerprint
      // AppKit's `beginUpdates` / `insertRows` / `removeRows` adjust the
      // row count through delegate callbacks without running the
      // before/after consistency check that `UICollectionView.performBatchUpdates`
      // enforces — assigning `sections` here is safe and keeps the rest
      // of `apply` (fingerprint computation, id-index build) reading from
      // the new state.
      sections = newSections
      let fingerprint = newSections.map {
        SectionFingerprint(
          id: $0.id,
          itemCount: $0.itemCount,
          hasHeader: $0.header != nil,
          hasFooter: $0.footer != nil
        )
      }
      let structureChanged = fingerprint != oldFingerprint
      guard structureChanged else { return .unchanged }
      let delta = tailDelta(from: oldFingerprint, to: fingerprint)
      lastAppliedFingerprint = fingerprint

      // Structural change invalidates per-row state keyed by
      // IndexPath — an inserted row shifts every row after it, so
      // entries keyed by the old paths no longer describe the
      // intended rows. Modifier `.onAppear` callbacks repopulate the
      // entries for rows that still exist.
      perRowBoxes.removeAll(keepingCapacity: true)
      perRowBackgroundViews.removeAll(keepingCapacity: true)
      perRowInsets.removeAll(keepingCapacity: true)
      perRowBadgeViews.removeAll(keepingCapacity: true)
      perRowSeparatorVisibility.removeAll(keepingCapacity: true)

      rebuildOffsets()
      // `.diffed` promises O(1) id-to-indexPath lookup, parity with
      // `UICollectionViewDiffableDataSource`. Pay the O(N) map build
      // here so subsequent lookups stay constant.
      // `.indexed` skips this so apply itself stays O(1); lookups on
      // that path walk the sections linearly (same as UIKit).
      switch configuration.updatePolicy {
      case .diffed: buildIDIndex()
      case .indexed: idIndex = nil
      }

      guard let tableView else { return .reloaded }
      let animation: NSTableView.AnimationOptions = animated ? [.effectFade] : []
      switch delta {
      case .insert(let rows):
        // Tail insert: existing rows keep their indices. AppKit only
        // measures/dequeues the inserted rows, so sequential appends stay
        // O(visible) regardless of total row count.
        tableView.beginUpdates()
        tableView.insertRows(at: rows, withAnimation: animation)
        tableView.endUpdates()
        return .incremental
      case .remove(let rows):
        tableView.beginUpdates()
        tableView.removeRows(at: rows, withAnimation: animation)
        tableView.endUpdates()
        return .incremental
      case .reload:
        tableView.reloadData()
        return .reloaded
      }
    }

    private enum TailDelta {
      case insert(IndexSet)
      case remove(IndexSet)
      case reload
    }

    /// Classifies the transition. If only the trailing section's item count
    /// changed, returns an `insert`/`remove` describing the exact affected
    /// rows; otherwise the caller falls back to `reload`.
    private func tailDelta(
      from old: [SectionFingerprint],
      to new: [SectionFingerprint]
    ) -> TailDelta {
      guard !old.isEmpty, old.count == new.count else { return .reload }
      for i in 0..<(old.count - 1) where old[i] != new[i] {
        return .reload
      }
      let lastOld = old[old.count - 1]
      let lastNew = new[new.count - 1]
      guard
        lastOld.id == lastNew.id,
        lastOld.hasHeader == lastNew.hasHeader,
        lastOld.hasFooter == lastNew.hasFooter,
        lastOld.itemCount != lastNew.itemCount
      else { return .reload }

      // Flat-row offset of the tail section's first item row.
      var baseRow = 0
      for i in 0..<(old.count - 1) {
        baseRow +=
          (old[i].hasHeader ? 1 : 0)
          + old[i].itemCount
          + (old[i].hasFooter ? 1 : 0)
      }
      baseRow += lastOld.hasHeader ? 1 : 0

      if lastNew.itemCount > lastOld.itemCount {
        let range = (baseRow + lastOld.itemCount)..<(baseRow + lastNew.itemCount)
        return .insert(IndexSet(integersIn: range))
      } else {
        let range = (baseRow + lastNew.itemCount)..<(baseRow + lastOld.itemCount)
        return .remove(IndexSet(integersIn: range))
      }
    }

    private func buildIDIndex() {
      var map: [AnyHashable: IndexPath] = [:]
      map.reserveCapacity(totalRowCount)
      for (sIdx, section) in sections.enumerated() {
        for i in 0..<section.itemCount {
          map[section.itemID(i)] = IndexPath(item: i, section: sIdx)
        }
      }
      idIndex = map
    }

    private func rebuildOffsets() {
      sectionRowInfo.removeAll(keepingCapacity: true)
      var row = 0
      for section in sections {
        let info = SectionRowInfo(
          startRow: row,
          hasHeader: section.header != nil,
          itemCount: section.itemCount,
          hasFooter: section.footer != nil
        )
        sectionRowInfo.append(info)
        row += info.totalRows
      }
      totalRowCount = row
    }

    /// Groups a set of flat `NSTableView` row indices (as reported by
    /// `selectedRowIndexes`) into per-section `IndexSet`s keyed by
    /// section index. Header / footer rows are filtered out. Used by
    /// the Delete-key handler to fire `.onDelete` once per affected
    /// section — mirrors SwiftUI's `ForEach.onDelete`, which also
    /// reports item indices within the enclosing section.
    func itemIndexSetsForDelete(from rows: IndexSet) -> [(section: Int, items: IndexSet)] {
      var bySectionIndex: [Int: IndexSet] = [:]
      for row in rows {
        guard case .item(let section, let index) = rowKind(at: row) else { continue }
        bySectionIndex[section, default: IndexSet()].insert(index)
      }
      return
        bySectionIndex
        .sorted(by: { $0.key < $1.key })
        .map { (section: $0.key, items: $0.value) }
    }

    /// Maps a flat table row to a `RowKind`. O(log sections) via binary
    /// search over `sectionRowInfo`.
    func rowKind(at row: Int) -> RowKind? {
      guard !sectionRowInfo.isEmpty, row >= 0, row < totalRowCount else {
        return nil
      }
      var lo = 0
      var hi = sectionRowInfo.count - 1
      while lo < hi {
        let mid = (lo + hi + 1) / 2
        if sectionRowInfo[mid].startRow <= row {
          lo = mid
        } else {
          hi = mid - 1
        }
      }
      let info = sectionRowInfo[lo]
      var local = row - info.startRow
      if info.hasHeader {
        if local == 0 { return .header(section: lo) }
        local -= 1
      }
      if local < info.itemCount {
        return .item(section: lo, index: local)
      }
      return .footer(section: lo)
    }

    // MARK: Cell configuration

    fileprivate func configureCell(_ cell: HostingTableCellView, at row: Int) {
      guard let kind = rowKind(at: row) else { return }
      cellBuildCount &+= 1
      switch kind {
      case .item(let section, let index):
        // Unlike UIKit's `UIHostingConfiguration` (which self-sizes to
        // the content's intrinsic height and needs an explicit
        // `.frame(height:)` to honour a caller-declared fixed row
        // height), the macOS path routes row height through
        // `NSTableView.rowHeight` directly — `applyRowSizing(on:)` flips
        // `usesAutomaticRowHeights` off and pins each row to the fixed
        // value. The hosting view's autoresizing mask then keeps the
        // SwiftUI content bounded to the row frame, so no per-cell
        // `.frame(height:)` wrapper is needed.
        let indexPath = IndexPath(item: index, section: section)
        // Re-dequeue may hand us a cell that last rendered a different
        // IndexPath; clear any row-API decorations from that previous
        // use before re-installing this IndexPath's cached state.
        cell.resetRowDecorations()
        // Inject the lightweight provider so `.listRowBackground` /
        // `.listRowInsets` / `.listRowSeparator` / `.badge` modifier
        // `.onAppear`s can lazily allocate a `VirtualListRowBox` for
        // this row. Zero cost for rows that never declare any
        // row-level modifier — no box allocation, no dict entry.
        let provider = VirtualListRowBoxProvider(
          coordinator: self,
          indexPath: indexPath
        )
        let raw = sections[section].itemView(index)
        let hosted = decorate(view: raw)
          .environment(\.virtualListRowBoxProvider, provider)
        cell.host(AnyView(hosted))
        // Apply any cached state captured on a prior modifier fire for
        // this IndexPath. New rows have empty caches; scroll-back and
        // reconfigure paths restore what the modifier already committed.
        if let cached = perRowBackgroundViews[indexPath] {
          cell.setBackgroundContent(cached)
        }
        if let cached = perRowBadgeViews[indexPath] {
          cell.setBadgeContent(cached)
        }
        if let insets = perRowInsets[indexPath] {
          cell.contentInsets = insets
        }
        applySeparatorState(cell, for: indexPath, in: section, itemIndex: index)
      case .header(let section):
        if let builder = sections[section].header {
          cell.host(decorate(view: builder()))
        } else {
          cell.host(AnyView(EmptyView()))
        }
      case .footer(let section):
        if let builder = sections[section].footer {
          cell.host(decorate(view: builder()))
        } else {
          cell.host(AnyView(EmptyView()))
        }
      }
    }

    private func decorate(view: AnyView) -> AnyView {
      guard !configuration.environmentOverrides.isEmpty else { return view }
      var wrapped = view
      for override in configuration.environmentOverrides {
        wrapped = override.apply(wrapped)
      }
      return wrapped
    }

    /// Re-runs cell configuration for every visible row. Mirrors the UIKit
    /// coordinator's same-named method so environment changes flow through
    /// without rebuilding the table.
    func reconfigureVisibleCells() {
      guard let tableView else { return }
      let range = tableView.rows(in: tableView.visibleRect)
      for row in range.location..<(range.location + range.length) {
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
          as? HostingTableCellView
        {
          configureCell(cell, at: row)
        }
      }
    }

    // MARK: - Per-row modifier plumbing (macOS)

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
      perRowBoxes[indexPath] = fresh
      return fresh
    }

    /// Maps an `IndexPath` (the shape `VirtualListRowBox` uses) back
    /// to the flat `NSTableView` row the modifier's target lives at.
    /// Returns `nil` when the IndexPath is out of bounds relative to
    /// the current section layout — which happens naturally on
    /// structural applies that shift row counts; the box dict is
    /// cleared in `apply` before this gets reached.
    private func tableRow(for indexPath: IndexPath) -> Int? {
      guard indexPath.section < sectionRowInfo.count else { return nil }
      let info = sectionRowInfo[indexPath.section]
      guard indexPath.item < info.itemCount else { return nil }
      return info.startRow + (info.hasHeader ? 1 : 0) + indexPath.item
    }

    private func cellForRow(_ indexPath: IndexPath) -> HostingTableCellView? {
      guard let tableView,
        let row = tableRow(for: indexPath)
      else { return nil }
      return tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
        as? HostingTableCellView
    }

    private func applyRowBackground(_ view: AnyView?, at indexPath: IndexPath) {
      if let view {
        perRowBackgroundViews[indexPath] = view
      } else {
        perRowBackgroundViews.removeValue(forKey: indexPath)
      }
      cellForRow(indexPath)?.setBackgroundContent(view)
    }

    private func applyRowInsets(_ insets: EdgeInsets?, at indexPath: IndexPath) {
      let previous = perRowInsets[indexPath]
      guard previous != insets else { return }
      let resolved = insets ?? .init(top: 0, leading: 0, bottom: 0, trailing: 0)
      if let insets {
        perRowInsets[indexPath] = insets
      } else {
        perRowInsets.removeValue(forKey: indexPath)
      }
      if let cell = cellForRow(indexPath) {
        cell.contentInsets = resolved
        cell.needsLayout = true
      }
    }

    private func applyRowBadge(_ view: AnyView?, at indexPath: IndexPath) {
      if let view {
        perRowBadgeViews[indexPath] = view
      } else {
        perRowBadgeViews.removeValue(forKey: indexPath)
      }
      if let cell = cellForRow(indexPath) {
        cell.setBadgeContent(view)
        cell.needsLayout = true
      }
    }

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
      if let cell = cellForRow(indexPath) {
        applySeparatorState(
          cell,
          for: indexPath,
          in: indexPath.section,
          itemIndex: indexPath.item
        )
      }
    }

    /// Resolves the effective top / bottom separator draw state for a
    /// cell. Per-row overrides (from `.listRowSeparator(_:edges:)`)
    /// win; otherwise the list-level `.virtualListRowSeparators` flag
    /// applies; otherwise the separator falls back to `true` for
    /// non-last rows within a section (AppKit's usual default).
    private func applySeparatorState(
      _ cell: HostingTableCellView,
      for indexPath: IndexPath,
      in section: Int,
      itemIndex: Int
    ) {
      let listDefault = configuration.rowSeparators ?? true
      let override = perRowSeparatorVisibility[indexPath]
      let topVisibility = resolveSeparatorVisibility(override?.top, fallback: false)
      // Bottom separator shows by default between adjacent items
      // within a section, unless the list-level flag is off or this
      // is the last item in its section.
      let sectionItemCount = section < sections.count ? sections[section].itemCount : 0
      let isLastItemInSection = itemIndex == sectionItemCount - 1
      let bottomFallback = listDefault && !isLastItemInSection
      let bottomVisibility = resolveSeparatorVisibility(override?.bottom, fallback: bottomFallback)
      cell.setSeparator(top: topVisibility, bottom: bottomVisibility)
    }

    private func resolveSeparatorVisibility(_ value: Visibility?, fallback: Bool) -> Bool {
      switch value {
      case .visible: true
      case .hidden: false
      case .automatic, nil: fallback
      case .some(_): fallback
      }
    }

    // MARK: Selection

    func resolveSelection() {
      guard let tableView, let box = configuration.selectionBox else {
        tableView?.deselectAll(nil)
        tableView?.allowsMultipleSelection = false
        return
      }
      tableView.allowsMultipleSelection = box.allowsMultipleSelection

      let desired = box.read()
      let current = Set(tableView.selectedRowIndexes.compactMap { itemID(atRow: $0) })
      let toDeselect = current.subtracting(desired)
      let toSelect = desired.subtracting(current)
      for id in toDeselect {
        if let row = row(forItemID: id) {
          tableView.deselectRow(row)
        }
      }
      if !toSelect.isEmpty {
        var indices = IndexSet()
        for id in toSelect {
          if let row = row(forItemID: id) { indices.insert(row) }
        }
        if !indices.isEmpty {
          tableView.selectRowIndexes(indices, byExtendingSelection: true)
        }
      }
    }

    // MARK: Focus binder

    func resolveFocusBinder() {
      let next = configuration.focusBinder
      let same: Bool = {
        guard let next, let attached = attachedFocusBinder else {
          return next == nil && attachedFocusBinder == nil
        }
        return ObjectIdentifier(next) == ObjectIdentifier(attached)
      }()
      if same { return }
      attachedFocusBinder?.detach()
      attachedFocusBinder = next
      next?.attachScrollHandler { [weak self] id in
        self?.scroll(toFocusedID: id)
      }
    }

    // `scroll(toFocusedID:)` lives in `Focus/FocusBinder.swift` so both
    // platforms' implementations sit next to each other.

    // MARK: Window attachment

    /// Called by `VirtualListHostTableView` when its `viewDidMoveToWindow`
    /// fires. Resolving selection/focus before a window exists is useless —
    /// there's no responder chain or AX tree — and it adds work to the first-
    /// render critical path. Running it here lets `makeNSView` stay lean.
    fileprivate func didAttachToWindow() {
      resolveSelection()
      resolveFocusBinder()
    }

    // MARK: Tear-down

    func tearDown(collectionView _: NSTableView) {
      attachedFocusBinder?.detach()
      attachedFocusBinder = nil
      sections = []
      sectionRowInfo = []
      totalRowCount = 0
      lastAppliedFingerprint = []
      idIndex = nil
      perRowBoxes.removeAll()
      perRowBackgroundViews.removeAll()
      perRowInsets.removeAll()
      perRowBadgeViews.removeAll()
      perRowSeparatorVisibility.removeAll()
      configuration = VirtualListConfiguration()
      tableView = nil
    }

    // MARK: ID ↔ row / index-path helpers

    /// Flat-row → item id, used by selection.
    func itemID(atRow row: Int) -> AnyHashable? {
      guard case .item(let section, let index) = rowKind(at: row) else { return nil }
      return sections[section].itemID(index)
    }

    /// Item id → flat row, used by selection and focus scroll. Uses the same
    /// id-index as `indexPath(forItemID:)` so repeated lookups (e.g. a
    /// multi-row selection sync) share the O(N) map build.
    func row(forItemID id: AnyHashable) -> Int? {
      guard let ip = indexPath(forItemID: id), ip.section < sectionRowInfo.count else {
        return nil
      }
      let info = sectionRowInfo[ip.section]
      return info.startRow + (info.hasHeader ? 1 : 0) + ip.item
    }

    /// IndexPath interface kept for parity with the UIKit coordinator so
    /// cross-platform tests compile against the same method name.
    func itemID(at indexPath: IndexPath) -> AnyHashable? {
      guard indexPath.section < sections.count else { return nil }
      let section = sections[indexPath.section]
      guard indexPath.item < section.itemCount else { return nil }
      return section.itemID(indexPath.item)
    }

    /// Item id → IndexPath lookup. `.diffed` builds the map eagerly on apply
    /// so lookups are O(1) for snapshot parity with
    /// `UICollectionViewDiffableDataSource`. `.indexed` keeps the map
    /// unbuilt so `apply` itself stays O(1); the first lookup walks the
    /// sections (O(N)) to build the map, subsequent lookups are O(1).
    /// Callers who never round-trip through IDs — the usual shape for
    /// `.indexed` — never pay for it.
    func indexPath(forItemID itemID: AnyHashable) -> IndexPath? {
      if idIndex == nil {
        buildIDIndex()
      }
      return idIndex?[itemID]
    }
  }

  // MARK: - VirtualListRowBoxHost

  extension VirtualListMacCoordinator: VirtualListRowBoxHost {}

  // MARK: - NSTableViewDataSource

  extension VirtualListMacCoordinator: NSTableViewDataSource {
    public func numberOfRows(in _: NSTableView) -> Int {
      totalRowCount
    }

    // MARK: Drag-reorder

    /// Dragged-type ingredient: row indices travel through the
    /// pasteboard as a custom UTI. Using a private type (rather than
    /// `.string`) keeps the reorder drag from being consumable by
    /// arbitrary other views in the app.
    static let reorderPasteboardType = NSPasteboard.PasteboardType(
      "dev.virtuallist.internal.reorder"
    )

    public func tableView(
      _: NSTableView,
      pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
      guard configuration.onMove != nil,
        case .item = rowKind(at: row)
      else { return nil }
      let item = NSPasteboardItem()
      item.setString(String(row), forType: Self.reorderPasteboardType)
      return item
    }

    public func tableView(
      _ tableView: NSTableView,
      validateDrop info: any NSDraggingInfo,
      proposedRow row: Int,
      proposedDropOperation op: NSTableView.DropOperation
    ) -> NSDragOperation {
      guard configuration.onMove != nil,
        op == .above,
        info.draggingSource as? NSTableView === tableView
      else { return [] }
      return .move
    }

    public func tableView(
      _: NSTableView,
      acceptDrop info: any NSDraggingInfo,
      row destinationRow: Int,
      dropOperation: NSTableView.DropOperation
    ) -> Bool {
      guard let onMove = configuration.onMove,
        let item = info.draggingPasteboard.pasteboardItems?.first,
        let string = item.string(forType: Self.reorderPasteboardType),
        let sourceRow = Int(string),
        case let .item(sourceSection, sourceIndex) = rowKind(at: sourceRow)
      else { return false }
      // AppKit reports the destination as "drop above this row".
      // Translate that into (section, item) using the row immediately
      // at or above the drop position; if the drop lands past the end
      // of a section, clamp to the section's trailing slot.
      let destinationIP: IndexPath
      if destinationRow >= totalRowCount {
        destinationIP = IndexPath(
          item: sections[sourceSection].itemCount - 1,
          section: sourceSection
        )
      } else if case let .item(destSection, destIndex) = rowKind(at: destinationRow) {
        destinationIP = IndexPath(item: destIndex, section: destSection)
      } else {
        return false
      }
      let sourceIP = IndexPath(item: sourceIndex, section: sourceSection)
      guard sourceIP != destinationIP else { return false }
      onMove(sourceIP, destinationIP)
      return true
    }
  }

  // MARK: - NSTableViewDelegate

  extension VirtualListMacCoordinator: NSTableViewDelegate {
    public func tableView(
      _ tableView: NSTableView,
      viewFor _: NSTableColumn?,
      row: Int
    ) -> NSView? {
      let identifier = Self.itemIdentifier
      let view =
        tableView.makeView(withIdentifier: identifier, owner: nil)
        as? HostingTableCellView
      let cell =
        view
        ?? {
          let fresh = HostingTableCellView()
          fresh.identifier = identifier
          return fresh
        }()
      configureCell(cell, at: row)
      return cell
    }

    public func tableView(_: NSTableView, isGroupRow row: Int) -> Bool {
      if case .header = rowKind(at: row) { return true }
      if case .footer = rowKind(at: row) { return true }
      return false
    }

    public func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
      // Only item rows are user-selectable; headers and footers act as
      // non-interactive separators (matches SwiftUI.List behaviour).
      if case .item = rowKind(at: row) { return true }
      return false
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
      guard let tableView = notification.object as? NSTableView,
        let box = configuration.selectionBox
      else { return }
      let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { itemID(atRow: $0) })
      box.write(selectedIDs)
    }

    /// Frees the heavy per-IndexPath state when a row leaves the
    /// viewport. Mirrors the iOS `didEndDisplaying` hook: without
    /// cleanup, scrolling through a 100k-row table keeps one
    /// `VirtualListRowBox` plus up to two `NSHostingView` roots alive
    /// per scrolled IndexPath until the next structural apply. The
    /// lightweight value caches (`perRowInsets`,
    /// `perRowSeparatorVisibility`) are left in place so a scroll-back
    /// redraws without flickering through default margins / separators
    /// between re-dequeue and the modifier's `.onAppear`.
    public func tableView(
      _: NSTableView,
      didRemove _: NSTableRowView,
      forRow row: Int
    ) {
      guard case let .item(section, index) = rowKind(at: row) else { return }
      let indexPath = IndexPath(item: index, section: section)
      perRowBoxes.removeValue(forKey: indexPath)
      perRowBackgroundViews.removeValue(forKey: indexPath)
      perRowBadgeViews.removeValue(forKey: indexPath)
    }
  }

  // MARK: - Hosting cell

  /// `NSTableCellView` that hosts a SwiftUI view through `NSHostingView`.
  ///
  /// The hosting view is pinned to the cell via `autoresizingMask` rather
  /// than AutoLayout constraints. Four activated anchor constraints per
  /// visible row (36 × 4 = 144 constraint entries at N=100k) show up as
  /// the dominant first-render cost; relying on frame + autoresizing keeps
  /// the constraint engine off the per-cell critical path.
  /// `NSTableView.usesAutomaticRowHeights` still drives row sizing through
  /// `NSHostingView.fittingSize`, which is self-contained per cell and does
  /// not depend on the cell-level constraint wiring.
  public final class HostingTableCellView: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    // Per-row decoration views, populated on demand by the coordinator
    // when the matching `VirtualListRow` modifier fires. Rows with no
    // decorations pay nothing — these stay nil.
    var backgroundHostingView: NSHostingView<AnyView>?
    var badgeHostingView: NSHostingView<AnyView>?
    var topSeparator: NSView?
    var bottomSeparator: NSView?
    var contentInsets: EdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)

    func host(_ content: AnyView) {
      if let existing = hostingView {
        existing.rootView = content
        return
      }
      let hosting = NSHostingView(rootView: content)
      hosting.frame = bounds
      addSubview(hosting)
      hostingView = hosting
    }

    /// Installs (or updates) the SwiftUI view drawn behind the hosted
    /// content — drives `.listRowBackground(_:)`. `nil` removes any
    /// previously-installed background.
    func setBackgroundContent(_ view: AnyView?) {
      guard let view else {
        backgroundHostingView?.removeFromSuperview()
        backgroundHostingView = nil
        return
      }
      if let existing = backgroundHostingView {
        existing.rootView = view
        return
      }
      let host = NSHostingView(rootView: view)
      host.frame = bounds
      // Insert behind the content hosting view if one is already
      // attached; otherwise `addSubview` ordering puts it at z-index 0.
      if let content = hostingView {
        addSubview(host, positioned: .below, relativeTo: content)
      } else {
        addSubview(host)
      }
      backgroundHostingView = host
    }

    /// Installs (or updates) the SwiftUI view shown on the trailing
    /// edge of the cell — drives `.badge(_:)`. `nil` removes it.
    func setBadgeContent(_ view: AnyView?) {
      guard let view else {
        badgeHostingView?.removeFromSuperview()
        badgeHostingView = nil
        return
      }
      if let existing = badgeHostingView {
        existing.rootView = view
        return
      }
      let host = NSHostingView(rootView: view)
      addSubview(host)
      badgeHostingView = host
    }

    /// Sets the draw state of the row's top / bottom separator
    /// hair-lines. A separator is installed lazily on first use.
    func setSeparator(top: Bool, bottom: Bool) {
      if top {
        ensureSeparator(\.topSeparator)
      } else {
        topSeparator?.removeFromSuperview()
        topSeparator = nil
      }
      if bottom {
        ensureSeparator(\.bottomSeparator)
      } else {
        bottomSeparator?.removeFromSuperview()
        bottomSeparator = nil
      }
    }

    private func ensureSeparator(_ keyPath: ReferenceWritableKeyPath<HostingTableCellView, NSView?>)
    {
      if self[keyPath: keyPath] != nil { return }
      let line = NSView()
      line.wantsLayer = true
      line.layer?.backgroundColor = NSColor.separatorColor.cgColor
      addSubview(line)
      self[keyPath: keyPath] = line
    }

    public override func layout() {
      super.layout()
      let paddedFrame = bounds.inset(by: contentInsets)
      let badgeWidth: CGFloat
      if let badge = badgeHostingView {
        let size = badge.fittingSize
        badgeWidth = size.width
        // Trail-aligned, vertically centered in the padded area.
        let y = paddedFrame.midY - size.height / 2
        badge.frame = NSRect(
          x: paddedFrame.maxX - size.width,
          y: y,
          width: size.width,
          height: size.height
        )
      } else {
        badgeWidth = 0
      }
      let contentTrailing = paddedFrame.maxX - badgeWidth - (badgeWidth > 0 ? 8 : 0)
      hostingView?.frame = NSRect(
        x: paddedFrame.minX,
        y: paddedFrame.minY,
        width: max(0, contentTrailing - paddedFrame.minX),
        height: paddedFrame.height
      )
      backgroundHostingView?.frame = bounds
      let separatorHeight: CGFloat = 1.0 / (window?.backingScaleFactor ?? 1)
      topSeparator?.frame = NSRect(
        x: 0, y: bounds.maxY - separatorHeight, width: bounds.width, height: separatorHeight)
      bottomSeparator?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: separatorHeight)
    }

    /// Resets the cell's row-API decorations so a re-dequeue lands on a
    /// clean baseline. The coordinator calls this from `configureCell`
    /// before applying any per-IndexPath cached state so a cell that
    /// was previously the receiver for a decorated row doesn't carry
    /// those decorations into an undecorated reuse.
    func resetRowDecorations() {
      setBackgroundContent(nil)
      setBadgeContent(nil)
      setSeparator(top: false, bottom: false)
      contentInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
      needsLayout = true
    }
  }

  extension NSRect {
    /// Inset variant that speaks SwiftUI's `EdgeInsets` (which is
    /// leading/trailing rather than left/right). This is a reading-
    /// order-agnostic inset — the macOS path currently does not honour
    /// RTL layouts here, matching `SwiftUI.List` on macOS which also
    /// draws left-to-right regardless of writing direction.
    fileprivate func inset(by insets: EdgeInsets) -> NSRect {
      NSRect(
        x: origin.x + insets.leading,
        y: origin.y + insets.bottom,
        width: max(0, size.width - insets.leading - insets.trailing),
        height: max(0, size.height - insets.top - insets.bottom)
      )
    }
  }

  // MARK: - NSTableView subclass

  /// `NSTableView` subclass that notifies its coordinator when it becomes
  /// window-attached. Used so `VirtualList.makeNSView` can skip selection /
  /// focus resolution on the first-render critical path — those steps need
  /// a responder chain and an AX tree, neither of which exist until a
  /// window is present.
  final class VirtualListHostTableView: NSTableView {
    weak var macCoordinator: VirtualListMacCoordinator?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      macCoordinator?.didAttachToWindow()
    }

    /// Routes ⌫ (Delete) / forward-delete on the selected row(s)
    /// into the coordinator's `.onDelete` handler. The AppKit
    /// equivalent of iOS's swipe-to-delete — matches what AppKit
    /// users expect when a single row is focused and they press
    /// the Delete key. A selection that spans multiple sections
    /// fires the handler once per section with the item indices
    /// relative to that section, matching SwiftUI's
    /// `ForEach.onDelete` semantics.
    ///
    /// Falls back to `super` when `.onDelete` isn't set or the
    /// event isn't a delete key, so default AppKit behaviour (e.g.
    /// type-select) stays intact.
    override func keyDown(with event: NSEvent) {
      guard let characters = event.charactersIgnoringModifiers,
        characters.unicodeScalars.contains(where: { scalar in
          scalar == "\u{7F}"  // delete (backspace)
            || scalar == "\u{F728}"  // forward delete
        }),
        let coordinator = macCoordinator,
        let handler = coordinator.configuration.onDelete
      else {
        super.keyDown(with: event)
        return
      }
      let rows = selectedRowIndexes
      let grouped = coordinator.itemIndexSetsForDelete(from: rows)
      guard !grouped.isEmpty else {
        super.keyDown(with: event)
        return
      }
      for (_, items) in grouped { handler(items) }
    }
  }

  // MARK: - VirtualList NSViewRepresentable

  extension VirtualList: NSViewRepresentable {
    public func makeCoordinator() -> VirtualListMacCoordinator {
      VirtualListMacCoordinator()
    }

    public func makeNSView(context: Context) -> NSScrollView {
      let tableView = VirtualListHostTableView()
      tableView.autoresizingMask = [.width, .height]

      let scrollView = NSScrollView()
      scrollView.documentView = tableView
      scrollView.hasVerticalScroller = true
      scrollView.hasHorizontalScroller = false
      scrollView.autohidesScrollers = true
      applyScrollConfiguration(to: scrollView, from: configuration)

      context.coordinator.configuration = configuration
      context.coordinator.install(on: tableView)
      context.coordinator.apply(sections: sections, animated: false)
      // `resolveSelection` / `resolveFocusBinder` are deferred to
      // `viewDidMoveToWindow` — see `VirtualListHostTableView`.
      return scrollView
    }

    public static func dismantleNSView(
      _ nsView: NSScrollView,
      coordinator: VirtualListMacCoordinator
    ) {
      if let tv = nsView.documentView as? NSTableView {
        coordinator.tearDown(collectionView: tv)
      }
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
      guard let tableView = scrollView.documentView as? NSTableView else { return }
      let coordinator = context.coordinator
      coordinator.configuration = configuration
      coordinator.refreshRowSizing(on: tableView)
      applyScrollConfiguration(to: scrollView, from: configuration)
      let outcome = coordinator.apply(
        sections: sections,
        animated: !context.transaction.disablesAnimations
      )
      coordinator.resolveSelection()
      coordinator.resolveFocusBinder()
      // SwiftUI rebuilds the section closures with freshly captured state on
      // every parent update. Cells that this `apply` call did NOT
      // re-dequeue therefore still carry stale content; reconfigure them
      // here. Only the full `reloadData` path skips this step — AppKit
      // re-dequeues every visible row itself on the next layout pass there.
      if outcome != .reloaded {
        coordinator.reconfigureVisibleCells()
      }
    }

    /// Maps `.scrollContentBackground(_:)` onto `NSScrollView`'s
    /// drawing flags. Default (unset / `.automatic`) matches
    /// `SwiftUI.List`'s behaviour: draws against
    /// `NSColor.windowBackgroundColor` — the AppKit analogue to iOS's
    /// `systemBackground`. Explicit `.hidden` keeps the scroll surface
    /// transparent so a surrounding SwiftUI `.background(...)` shows
    /// through. Idempotency-guarded so `updateNSView` doesn't churn
    /// property setters on every SwiftUI update.
    private func applyScrollConfiguration(
      to scrollView: NSScrollView,
      from configuration: VirtualListConfiguration
    ) {
      let targetDraws: Bool
      let targetBackground: NSColor
      switch configuration.scrollContentBackground {
      case .visible, .automatic, nil:
        targetDraws = true
        targetBackground = .windowBackgroundColor
      case .hidden:
        targetDraws = false
        targetBackground = .clear
      @unknown default:
        targetDraws = true
        targetBackground = .windowBackgroundColor
      }
      if scrollView.drawsBackground != targetDraws {
        scrollView.drawsBackground = targetDraws
      }
      if scrollView.backgroundColor != targetBackground {
        scrollView.backgroundColor = targetBackground
      }
    }
  }
#endif
