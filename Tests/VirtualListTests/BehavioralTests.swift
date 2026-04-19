import SwiftUI
import XCTest

@testable import VirtualList

#if canImport(UIKit)
  import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#endif

/// Behavioural tests for interactive features that the modifier-level tests
/// only cover at the "config got stored" layer. These drive the coordinator's
/// delegate callbacks directly — without routing through actual user gestures —
/// and assert that the caller-facing contract fires.
///
/// Selection and focus behaviour is cross-platform: the same binding semantics
/// hold on UIKit and AppKit coordinators. UIKit-specific behaviour (refresh
/// control) is gated to iOS only.
@MainActor
final class VirtualListBehavioralTests: XCTestCase {
  // MARK: Selection — cross-platform

  func test_singleSelection_updatesBindingOnTap() {
    var selected: Int? = nil
    let binding = Binding<Int?>(get: { selected }, set: { selected = $0 })

    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)
    coord.configuration.selectionBox = VirtualListSelectionBox(single: binding)
    coord.apply(sections: [syntheticSection(count: 5)], animated: false)

    simulateSelect(coord: coord, cv: cv, indexPaths: [IndexPath(item: 2, section: 0)])
    XCTAssertEqual(selected, 2)

    simulateSelect(coord: coord, cv: cv, indexPaths: [IndexPath(item: 4, section: 0)])
    XCTAssertEqual(selected, 4, "single selection should replace, not accumulate")
  }

  func test_multiSelection_accumulatesOnTapClearsOnDeselect() {
    var selected: Set<Int> = []
    let binding = Binding<Set<Int>>(get: { selected }, set: { selected = $0 })

    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView()
    coord.install(on: cv)
    coord.configuration.selectionBox = VirtualListSelectionBox(multiple: binding)
    coord.apply(sections: [syntheticSection(count: 5)], animated: false)

    simulateSelect(coord: coord, cv: cv, indexPaths: [IndexPath(item: 1, section: 0)])
    simulateSelect(coord: coord, cv: cv, indexPaths: [IndexPath(item: 3, section: 0)])
    XCTAssertEqual(selected, [1, 3])

    simulateDeselect(coord: coord, cv: cv, indexPaths: [IndexPath(item: 1, section: 0)])
    XCTAssertEqual(selected, [3])
  }

  // MARK: Focus binder — cross-platform

  func test_focusCoordinator_focusTriggersScrollRequest() {
    let focus = VirtualListFocusCoordinator<Int>()

    // Probe for the scroll handler invocation, installed by the binder.
    var scrolledTo: AnyHashable?
    focus.scrollHandler = { scrolledTo = $0 }

    focus.focus(id: 42)
    XCTAssertEqual(scrolledTo, AnyHashable(42))

    focus.focus(id: nil)
    // Clearing focus must not re-invoke the scroll handler.
    XCTAssertEqual(scrolledTo, AnyHashable(42))
  }

  func test_focusBinder_resolvesIndexPathOnFocus() {
    let focus = VirtualListFocusCoordinator<Int>()
    let binder = VirtualListFocusBinder(focusCoordinator: focus)

    let coord = VirtualListPlatformCoordinator()
    let cv = makePlatformCollectionView(height: 200)
    coord.install(on: cv)
    coord.apply(
      sections: [syntheticSection(count: 500)],
      animated: false
    )

    // Install a scroll handler that records the id it was called with —
    // without actually routing through `scrollToItems` (which needs a
    // window on AppKit).
    var capturedID: AnyHashable?
    binder.attachScrollHandler { capturedID = $0 }

    focus.focus(id: 200)
    XCTAssertEqual(capturedID, AnyHashable(200))

    let ip = coord.indexPath(forItemID: AnyHashable(200))
    XCTAssertEqual(ip, IndexPath(item: 200, section: 0))

    binder.detach()
  }

  // MARK: Refresh — UIKit only

  #if canImport(UIKit)
    func test_refresh_controlInstalledAndTornDown() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView()
      coord.install(on: cv)
      coord.configuration.refreshAction = { /* noop */  }
      coord.resolveRefreshControl()

      let refresh = cv.refreshControl
      XCTAssertNotNil(refresh)
      XCTAssertTrue(
        refresh?.allTargets.contains(coord) ?? false,
        "coordinator should be registered as a .valueChanged target"
      )

      coord.configuration.refreshAction = nil
      coord.resolveRefreshControl()
      XCTAssertNil(cv.refreshControl, "refreshControl should be torn down when action is cleared")
    }
  #endif

  // MARK: Platform bridges

  /// Feed a "user selected these rows" event into the coordinator's delegate
  /// callback using whatever shape the platform exposes.
  private func simulateSelect(
    coord: VirtualListPlatformCoordinator,
    cv: VirtualListPlatformCollectionView,
    indexPaths: [IndexPath]
  ) {
    #if canImport(UIKit)
      for ip in indexPaths {
        coord.collectionView(cv, didSelectItemAt: ip)
      }
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      // NSTableView tracks selection via row IndexSet; the test sections are
      // flat (no header) so section.item maps straight to row.
      let isMultiple = coord.configuration.selectionBox?.allowsMultipleSelection ?? false
      cv.allowsMultipleSelection = isMultiple
      let target = IndexSet(indexPaths.map { $0.item })
      let combined: IndexSet = isMultiple ? cv.selectedRowIndexes.union(target) : target
      cv.selectRowIndexes(combined, byExtendingSelection: false)
      let notification = Notification(
        name: NSTableView.selectionDidChangeNotification,
        object: cv
      )
      coord.tableViewSelectionDidChange(notification)
    #endif
  }

  private func simulateDeselect(
    coord: VirtualListPlatformCoordinator,
    cv: VirtualListPlatformCollectionView,
    indexPaths: [IndexPath]
  ) {
    #if canImport(UIKit)
      for ip in indexPaths {
        coord.collectionView(cv, didDeselectItemAt: ip)
      }
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      var next = cv.selectedRowIndexes
      for ip in indexPaths { next.remove(ip.item) }
      cv.selectRowIndexes(next, byExtendingSelection: false)
      let notification = Notification(
        name: NSTableView.selectionDidChangeNotification,
        object: cv
      )
      coord.tableViewSelectionDidChange(notification)
    #endif
  }
}
