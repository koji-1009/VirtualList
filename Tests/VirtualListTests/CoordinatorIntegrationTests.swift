import Foundation
import SwiftUI
import Testing

@testable import VirtualList

/// End-to-end tests that drive the coordinator by hand (no SwiftUI render
/// path), so assertions land directly on the state the coordinator exposes
/// after apply.
///
/// Cross-platform via `VirtualListPlatformCoordinator`. Where the assertions
/// rely on the diffable data source, those branches are gated to UIKit —
/// the macOS backing is `NSTableView` and has no diffable data source. The
/// same apply / dedup / teardown contracts are still exercised on AppKit via
/// coordinator-level state (`sections`, `totalRowCount`).
@Suite("Coordinator integration")
@MainActor
struct CoordinatorIntegrationTests {
  @Test func installWiresUpTheCollectionView() {
    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)
    #if canImport(UIKit)
      // UIKit: default policy is `.diffed`, which installs a diffable data
      // source; the classic `.indexed` path leaves that nil.
      #expect(coord.dataSource != nil)
      #expect(cv.delegate === coord)
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      // macOS: coordinator is wired as both the delegate and the
      // data source of the NSTableView.
      #expect(cv.delegate === coord)
      #expect(cv.dataSource === coord)
    #endif
  }

  @Test func applySnapshotMatchesSections() {
    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)

    let sections = [
      VirtualListSection(id: "A", itemCount: 3, itemID: { $0 }, itemView: { _ in Text("x") }),
      VirtualListSection(id: "B", itemCount: 5, itemID: { $0 }, itemView: { _ in Text("x") }),
    ]
    coord.apply(sections: sections, animated: false)

    #expect(coord.sections.count == 2)
    #expect(coord.sections[0].itemCount == 3)
    #expect(coord.sections[1].itemCount == 5)

    #if canImport(UIKit)
      let snapshot = coord.dataSource?.snapshot()
      #expect(snapshot?.numberOfSections == 2)
      #expect(snapshot?.numberOfItems(inSection: AnyHashable("A")) == 3)
      #expect(snapshot?.numberOfItems(inSection: AnyHashable("B")) == 5)
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      #expect(coord.totalRowCount == 8)
    #endif
    _ = cv
  }

  @Test func applyIsIdempotentForEqualSnapshots() {
    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)

    coord.apply(sections: [syntheticSection(count: 2)], animated: false)
    coord.apply(sections: [syntheticSection(count: 2)], animated: false)
    #expect(coord.sections.count == 1)
    #expect(coord.sections[0].itemCount == 2)

    #if canImport(UIKit)
      #expect(coord.dataSource?.snapshot().itemIdentifiers.count == 2)
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      #expect(coord.totalRowCount == 2)
    #endif
    _ = cv
  }

  @Test func insertingItemGrowsSnapshot() {
    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)
    coord.apply(sections: [syntheticSection(count: 10)], animated: false)
    coord.apply(sections: [syntheticSection(count: 11)], animated: false)

    #expect(coord.sections[0].itemCount == 11)
    #if canImport(UIKit)
      #expect(coord.dataSource?.snapshot().numberOfItems == 11)
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      #expect(coord.totalRowCount == 11)
    #endif
    _ = cv
  }

  @Test func removingItemsShrinksSnapshot() {
    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)
    coord.apply(sections: [syntheticSection(count: 10)], animated: false)
    coord.apply(sections: [syntheticSection(count: 3)], animated: false)

    #expect(coord.sections[0].itemCount == 3)
    #if canImport(UIKit)
      #expect(coord.dataSource?.snapshot().numberOfItems == 3)
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      #expect(coord.totalRowCount == 3)
    #endif
    _ = cv
  }

  // The `.indexed` / `.diffed` distinction materialises differently on each
  // platform: UIKit flips the data-source class, macOS flips the eager vs
  // lazy id-index behaviour. Both tests exercise the same contract through
  // whichever observable the platform exposes.

  @Test func indexedPolicySkipsSnapshotAllocation() {
    let coord = VirtualListPlatformCoordinator()
    coord.setUpdatePolicy(.indexed)
    let cv = makePlatformCollectionView()
    coord.install(on: cv)
    coord.apply(sections: [syntheticSection(count: 1_000_000)], animated: false)
    #if canImport(UIKit)
      // `.indexed` on UIKit installs the classic data source and leaves the
      // diffable data source uninstantiated.
      #expect(coord.dataSource == nil)
      #expect(cv.numberOfSections == 1)
      #expect(cv.numberOfItems(inSection: 0) == 1_000_000)
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      // `.indexed` on macOS skips the eager id→IndexPath map build (the
      // `.diffed` path builds it on every apply for O(1) lookup parity).
      // The map stays lazy until a lookup asks for it.
      #expect(cv.numberOfRows == 1_000_000)
    #endif
  }

  @Test func switchingPolicyPreservesRowCount() {
    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)
    coord.apply(sections: [syntheticSection(count: 5)], animated: false)

    coord.setUpdatePolicy(.indexed)
    coord.apply(sections: [syntheticSection(count: 5)], animated: false)

    #if canImport(UIKit)
      // Switching to `.indexed` on UIKit unbinds the diffable data source
      // and routes through the classic one.
      #expect(coord.dataSource == nil)
      #expect(cv.numberOfItems(inSection: 0) == 5)
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      // macOS keeps the same NSTableView backing across both policies; the
      // row count is the observable that must stay consistent.
      #expect(cv.numberOfRows == 5)
    #endif
  }

  // `apply` reports what it did so the caller knows whether visible cells
  // still need reconfiguring. An incremental tail insert doesn't re-dequeue
  // existing rows, so the caller must follow up with
  // `reconfigureVisibleCells` to propagate fresh closure state — the old
  // `Bool` return confused that case with a full reload.
  @Test func applyOutcomeReflectsDataSourceMutation() {
    let coord = VirtualListPlatformCoordinator()
    // `.indexed` makes the tail-delta / reload distinction observable on
    // both platforms; the `.diffed` path always reports `.incremental`
    // because diffable data sources dequeue only changed items.
    coord.setUpdatePolicy(.indexed)
    let cv = makePlatformCollectionView()
    coord.install(on: cv)

    let first = coord.apply(sections: [syntheticSection(count: 10)], animated: false)
    #expect(first != .unchanged)

    let second = coord.apply(sections: [syntheticSection(count: 10)], animated: false)
    #expect(second == .unchanged)

    let third = coord.apply(sections: [syntheticSection(count: 11)], animated: false)
    // `.indexed` classifies pure tail inserts as `.tailIncremental` so the
    // representable's `reconfigureVisibleCells` step can be skipped —
    // existing visible rows keep their IndexPaths, so their content is
    // still correct for the new data without rebuild.
    #expect(third == .tailIncremental)

    // Non-tail structural change (swap for a section with a different id)
    // forces a full reload.
    let reloadSection = VirtualListSection(
      id: "other",
      itemCount: 5,
      itemID: { $0 },
      itemView: { i in Text("\(i)") }
    )
    let fourth = coord.apply(sections: [reloadSection], animated: false)
    #expect(fourth == .reloaded)
    _ = cv
  }

  @Test func fingerprintDedupSkipsSnapshotRebuild() {
    let coord = VirtualListPlatformCoordinator()
    coord.install(on: makePlatformCollectionView())
    coord.apply(sections: [syntheticSection(count: 10)], animated: false)

    // Second apply with a section whose itemID closure would trip if
    // invoked: matching fingerprint should short-circuit before we reach it.
    var itemIDCalls = 0
    let probe = VirtualListSection(
      id: "s",
      itemCount: 10,
      itemID: { i in
        itemIDCalls += 1
        return i
      },
      itemView: { idx in Text("\(idx)") }
    )
    coord.apply(sections: [probe], animated: false)
    #expect(itemIDCalls == 0)
  }

  @Test func tearDownReleasesReferences() {
    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)
    coord.apply(sections: [syntheticSection(count: 3)], animated: false)
    #if canImport(UIKit)
      #expect(coord.dataSource != nil)
    #endif

    coord.tearDown(collectionView: cv)
    #expect(coord.sections.isEmpty)
    #if canImport(UIKit)
      #expect(coord.dataSource == nil)
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      #expect(coord.totalRowCount == 0)
    #endif
  }

  // Regression guard for the correctness bug where a tail-insert apply
  // (structural change, only new row dequeued) combined with the caller
  // skipping `reconfigureVisibleCells` would leave already-visible cells
  // showing stale closure state. The fix: apply reports `.incremental`
  // and the caller still reconfigures. Both platforms are covered to
  // prevent the bug from regressing on either backend.
  @Test func tailInsertReconfiguresExistingVisibleCells() {
    let coord = VirtualListPlatformCoordinator()
    #if canImport(UIKit)
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 10)], animated: false)
      cv.layoutIfNeeded()
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      // AppKit's `tableView(_:viewFor:row:)` only runs when the table view
      // is window-attached; without a window `cellBuildCount` stays zero
      // and there's nothing for `reconfigureVisibleCells` to touch.
      let cv = makePlatformCollectionView(height: 220)
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 320, height: 220),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
      )
      let scroll = NSScrollView(frame: window.contentLayoutRect)
      scroll.documentView = cv
      window.contentView = scroll
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 10)], animated: false)
      cv.layout()
    #endif

    let baseline = coord.cellBuildCount
    #expect(baseline > 0)

    // Grow count by 1. The outcome should be `.incremental` (tail insert),
    // meaning the caller still needs to reconfigure the existing visible
    // cells — which we simulate explicitly here.
    let outcome = coord.apply(
      sections: [syntheticSection(count: 11)],
      animated: false
    )
    #expect(outcome == .incremental)

    coord.reconfigureVisibleCells()
    // reconfigureVisibleCells must have bumped cellBuildCount for every
    // existing visible cell; otherwise a mutation of `item[0]` alongside
    // an append would leave cell 0 showing stale content.
    #expect(coord.cellBuildCount > baseline)
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
      withExtendedLifetime(window) {}
    #endif
  }

  // MARK: Cell-build count (UIKit only — AppKit's dequeue path is driven by
  // NSTableView's own reloadData, which only calls viewFor:row: with a live
  // NSWindow. Not reproducible without real UI in a unit test.)

  #if canImport(UIKit)
    @Test func cellBuildCountStaysZeroWithoutLayout() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 0)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 1_000_000)], animated: false)
      #expect(coord.cellBuildCount == 0)
    }

    @Test func cellBuildCountReflectsVisibleWindow() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(
        sections: [syntheticSection(count: 1_000_000)],
        animated: false
      )
      cv.layoutIfNeeded()
      #expect(coord.cellBuildCount > 0)
      #expect(coord.cellBuildCount < 50)
    }
  #endif
}
