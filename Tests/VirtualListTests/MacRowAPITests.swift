#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import SwiftUI
  import Testing

  @testable import VirtualList

  /// End-to-end coverage for the macOS row-level modifier pipeline:
  /// modifier `.onAppear` → `VirtualListRowBoxProvider.resolveBox()` →
  /// `VirtualListMacCoordinator.ensureRowBox(at:)` → apply callback →
  /// `HostingTableCellView` decoration update.
  ///
  /// The iOS path is covered by `RowAPITests.swift`; these tests exist
  /// because the macOS AppKit backing implements decorations
  /// independently (NSHostingView-backed background / badge / per-row
  /// separator hairlines rather than UIKit's
  /// `UIBackgroundConfiguration` / `UICellAccessory`).
  @Suite("VirtualListRow on macOS")
  @MainActor
  struct MacRowAPITests {
    @Test func ensureRowBoxAllocatesLazilyPerIndexPath() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let first = coord.ensureRowBox(at: IndexPath(item: 0, section: 0))
      let second = coord.ensureRowBox(at: IndexPath(item: 0, section: 0))
      #expect(first === second)

      let other = coord.ensureRowBox(at: IndexPath(item: 1, section: 0))
      #expect(other !== first)
    }

    @Test func applyRowBackgroundCachesThroughSlotCommit() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.background.commit(AnyView(Color.blue))
      #expect(coord.perRowBackgroundViews[indexPath] != nil)

      box.background.commit(nil)
      #expect(coord.perRowBackgroundViews[indexPath] == nil)
    }

    @Test func applyRowInsetsCachesThroughSlotCommit() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      let insets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      box.insets.commit(insets)
      #expect(coord.perRowInsets[indexPath] == insets)

      box.insets.commit(nil)
      #expect(coord.perRowInsets[indexPath] == nil)
    }

    @Test func applyRowBadgeCachesThroughSlotCommit() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 1, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))
      #expect(coord.perRowBadgeViews[indexPath] != nil)

      box.badge.commit(nil)
      #expect(coord.perRowBadgeViews[indexPath] == nil)
    }

    @Test func applyRowSeparatorVisibilityCachesThroughSlotCommit() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      let visibility = VirtualListRowSeparatorVisibility(top: .hidden, bottom: .hidden)
      box.separator.commit(visibility)
      #expect(coord.perRowSeparatorVisibility[indexPath] == visibility)

      box.separator.commit(nil)
      #expect(coord.perRowSeparatorVisibility[indexPath] == nil)
    }

    @Test func structuralApplyClearsPerRowCaches() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.background.commit(AnyView(Color.blue))
      box.badge.commit(AnyView(Text("5")))
      box.insets.commit(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
      box.separator.commit(VirtualListRowSeparatorVisibility(top: .hidden, bottom: .hidden))
      #expect(coord.perRowBackgroundViews[indexPath] != nil)

      // Structural change — row counts shifted, old IndexPath entries
      // no longer describe the intended rows.
      coord.apply(sections: [syntheticSection(count: 5)], animated: false)

      #expect(coord.perRowBackgroundViews[indexPath] == nil)
      #expect(coord.perRowInsets[indexPath] == nil)
      #expect(coord.perRowBadgeViews[indexPath] == nil)
      #expect(coord.perRowSeparatorVisibility[indexPath] == nil)
      #expect(coord.perRowBoxes[indexPath] == nil)
    }

    @Test func onDeleteFiresWithItemIndicesFromSelection() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      var config = VirtualListConfiguration()
      var received: [IndexSet] = []
      config.onDelete = { received.append($0) }
      coord.configuration = config
      coord.apply(sections: [syntheticSection(count: 5)], animated: false)

      // Selection {row 1, row 3} in a single-section list with no
      // header maps to items {1, 3}.
      let grouped = coord.itemIndexSetsForDelete(from: IndexSet([1, 3]))
      #expect(grouped.count == 1)
      #expect(grouped.first?.section == 0)
      #expect(grouped.first?.items == IndexSet([1, 3]))
    }

    /// Mirror of the iOS `didEndDisplaying` contract: `didRemove` is
    /// what bounds growth on a 100k-row scroll. The AppKit hook
    /// signature differs (`forRow: Int` rather than `forItemAt: IndexPath`),
    /// so we map through `rowKind(at:)` to get back to an item IndexPath.
    @Test func didRemoveDropsHeavyPerRowState() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.background.commit(AnyView(Color.blue))
      box.badge.commit(AnyView(Text("5")))
      #expect(coord.perRowBoxes[indexPath] != nil)
      #expect(coord.perRowBackgroundViews[indexPath] != nil)
      #expect(coord.perRowBadgeViews[indexPath] != nil)

      // Section has no header, so item 0 lives at table row 0.
      coord.tableView(table, didRemove: NSTableRowView(), forRow: 0)

      #expect(coord.perRowBoxes[indexPath] == nil)
      #expect(coord.perRowBackgroundViews[indexPath] == nil)
      #expect(coord.perRowBadgeViews[indexPath] == nil)
    }

    @Test func didRemoveKeepsLightweightValueCaches() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      let insets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      let separator = VirtualListRowSeparatorVisibility(top: .hidden, bottom: .hidden)
      box.insets.commit(insets)
      box.separator.commit(separator)

      coord.tableView(table, didRemove: NSTableRowView(), forRow: 0)

      #expect(coord.perRowInsets[indexPath] == insets)
      #expect(coord.perRowSeparatorVisibility[indexPath] == separator)
    }

    @Test func didRemoveIgnoresNegativeRow() {
      // AppKit fires `didRemove` with `row == -1` when a row has been
      // structurally removed. Treating that as a valid IndexPath would
      // crash or evict the wrong row — the hook must early-out.
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.background.commit(AnyView(Color.blue))

      coord.tableView(table, didRemove: NSTableRowView(), forRow: -1)

      #expect(coord.perRowBoxes[indexPath] != nil)
      #expect(coord.perRowBackgroundViews[indexPath] != nil)
    }
  }

  /// macOS drag-reorder lives on `NSTableViewDataSource`: a writer
  /// gates the drag start, `validateDrop` gates the drop-target
  /// visual, and `acceptDrop` forwards into the caller's `onMove`.
  /// Each of those three has a guard that matters — this suite
  /// covers the guards individually.
  @Suite("Drag-reorder wiring (macOS)")
  @MainActor
  struct MacDragReorderTests {
    @Test func pasteboardWriterNilWhenOnMoveMissing() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      #expect(coord.tableView(table, pasteboardWriterForRow: 0) == nil)
    }

    @Test func pasteboardWriterReturnedWhenOnMoveSet() {
      let coord = VirtualListMacCoordinator()
      var config = VirtualListConfiguration()
      config.onMove = { _, _ in }
      coord.configuration = config
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let writer = coord.tableView(table, pasteboardWriterForRow: 0)
      #expect(writer != nil)
      let item = writer as? NSPasteboardItem
      #expect(
        item?.string(forType: VirtualListMacCoordinator.reorderPasteboardType) == "0"
      )
    }

    @Test func validateDropRejectsCrossViewDrag() {
      // A drag whose `draggingSource` is a different table view must
      // not be treated as a reorder — otherwise the drop handler would
      // misinterpret arbitrary outside pasteboard items as row indices.
      let coord = VirtualListMacCoordinator()
      var config = VirtualListConfiguration()
      config.onMove = { _, _ in }
      coord.configuration = config
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let otherTable = NSTableView()
      let info = StubDraggingInfo(source: otherTable)
      let op = coord.tableView(
        table,
        validateDrop: info,
        proposedRow: 1,
        proposedDropOperation: .above
      )
      #expect(op == [])
    }

    @Test func validateDropRejectsOnRowOp() {
      // Only `.above` drops are valid reorder targets. `.on` lands in
      // the middle of a row and isn't a sensible reorder position —
      // the coordinator should refuse it so AppKit doesn't paint a
      // drop indicator on top of a cell.
      let coord = VirtualListMacCoordinator()
      var config = VirtualListConfiguration()
      config.onMove = { _, _ in }
      coord.configuration = config
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let info = StubDraggingInfo(source: table)
      let op = coord.tableView(
        table,
        validateDrop: info,
        proposedRow: 1,
        proposedDropOperation: .on
      )
      #expect(op == [])
    }

    @Test func acceptDropForwardsSourceAndDestinationIndexPaths() {
      let coord = VirtualListMacCoordinator()
      var received: (IndexPath, IndexPath)?
      var config = VirtualListConfiguration()
      config.onMove = { src, dst in received = (src, dst) }
      coord.configuration = config
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 5)], animated: false)

      let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "virtuallist.test.drag"))
      pasteboard.clearContents()
      let item = NSPasteboardItem()
      item.setString("0", forType: VirtualListMacCoordinator.reorderPasteboardType)
      pasteboard.writeObjects([item])
      let info = StubDraggingInfo(source: table, pasteboard: pasteboard)

      let ok = coord.tableView(
        table,
        acceptDrop: info,
        row: 3,
        dropOperation: .above
      )
      #expect(ok == true)
      #expect(received?.0 == IndexPath(item: 0, section: 0))
      #expect(received?.1 == IndexPath(item: 3, section: 0))
    }
  }

  /// Minimal `NSDraggingInfo` stand-in — AppKit's concrete drag-info
  /// objects can't be instantiated in-process, so we provide exactly
  /// the surface the coordinator reads (`draggingSource`,
  /// `draggingPasteboard`).
  @MainActor
  private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    private let _source: Any?
    private let _pasteboard: NSPasteboard

    init(source: Any?, pasteboard: NSPasteboard = .general) {
      self._source = source
      self._pasteboard = pasteboard
    }

    var draggingSource: Any? { _source }
    var draggingPasteboard: NSPasteboard { _pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation {
      get { .default }
      set { _ = newValue }
    }
    var animatesToDestination: Bool {
      get { false }
      set { _ = newValue }
    }
    var numberOfValidItemsForDrop: Int {
      get { 0 }
      set { _ = newValue }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    func enumerateDraggingItems(
      options _: NSDraggingItemEnumerationOptions = [],
      for _: NSView?,
      classes _: [AnyClass],
      searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
      using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
  }
#endif
