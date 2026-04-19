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
      case let .insert(rows):
        // Tail insert: existing rows keep their indices. AppKit only
        // measures/dequeues the inserted rows, so sequential appends stay
        // O(visible) regardless of total row count.
        tableView.beginUpdates()
        tableView.insertRows(at: rows, withAnimation: animation)
        tableView.endUpdates()
        return .incremental
      case let .remove(rows):
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
        baseRow += (old[i].hasHeader ? 1 : 0)
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
        cell.host(decorate(view: sections[section].itemView(index)))
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

  // MARK: - NSTableViewDataSource

  extension VirtualListMacCoordinator: NSTableViewDataSource {
    public func numberOfRows(in _: NSTableView) -> Int {
      totalRowCount
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
      let view = tableView.makeView(withIdentifier: identifier, owner: nil)
        as? HostingTableCellView
      let cell = view ?? {
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

    func host(_ content: AnyView) {
      if let existing = hostingView {
        existing.rootView = content
        return
      }
      let hosting = NSHostingView(rootView: content)
      hosting.autoresizingMask = [.width, .height]
      hosting.frame = bounds
      addSubview(hosting)
      hostingView = hosting
    }

    public override func layout() {
      super.layout()
      hostingView?.frame = bounds
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
      scrollView.drawsBackground = false
      scrollView.autohidesScrollers = true

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
  }
#endif
