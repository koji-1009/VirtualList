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
      #expect(coord.debug_perRowBackgroundView(at: indexPath) != nil)

      box.background.commit(nil)
      #expect(coord.debug_perRowBackgroundView(at: indexPath) == nil)
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
      #expect(coord.debug_perRowInsets(at: indexPath) == insets)

      box.insets.commit(nil)
      #expect(coord.debug_perRowInsets(at: indexPath) == nil)
    }

    @Test func applyRowBadgeCachesThroughSlotCommit() {
      let coord = VirtualListMacCoordinator()
      let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
      coord.install(on: table)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 1, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))
      #expect(coord.debug_perRowBadgeView(at: indexPath) != nil)

      box.badge.commit(nil)
      #expect(coord.debug_perRowBadgeView(at: indexPath) == nil)
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
      #expect(coord.debug_perRowSeparatorVisibility(at: indexPath) == visibility)

      box.separator.commit(nil)
      #expect(coord.debug_perRowSeparatorVisibility(at: indexPath) == nil)
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
      #expect(coord.debug_perRowBackgroundView(at: indexPath) != nil)

      // Structural change — row counts shifted, old IndexPath entries
      // no longer describe the intended rows.
      coord.apply(sections: [syntheticSection(count: 5)], animated: false)

      #expect(coord.debug_perRowBackgroundView(at: indexPath) == nil)
      #expect(coord.debug_perRowInsets(at: indexPath) == nil)
      #expect(coord.debug_perRowBadgeView(at: indexPath) == nil)
      #expect(coord.debug_perRowSeparatorVisibility(at: indexPath) == nil)
      #expect(coord.debug_perRowBox(at: indexPath) == nil)
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
  }
#endif
