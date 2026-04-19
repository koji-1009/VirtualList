import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif
#if canImport(AppKit)
  import AppKit
#endif

/// Bridge that lets a `VirtualListFocusCoordinator` ask the list to scroll
/// the focused row into view. `focus(id:)` goes through a scroll handler the
/// binder installs on the coordinator; setting `coordinator.currentID`
/// directly is reserved for internal modifier updates and does *not*
/// trigger a scroll.
final class VirtualListFocusBinder<ID: Hashable>: VirtualListFocusBinderProtocol {
  private let focusCoordinator: VirtualListFocusCoordinator<ID>

  init(focusCoordinator: VirtualListFocusCoordinator<ID>) {
    self.focusCoordinator = focusCoordinator
  }

  @MainActor
  func attachScrollHandler(_ handler: @escaping @MainActor (AnyHashable) -> Void) {
    focusCoordinator.scrollHandler = handler
  }

  @MainActor
  func detach() {
    focusCoordinator.scrollHandler = nil
  }
}

extension VirtualList {
  /// Wires a `VirtualListFocusCoordinator` to the list so that programmatic
  /// `focus(id:)` calls scroll the target row into view. Without this modifier,
  /// `.virtualListFocused(_:id:)` still keeps focus in sync for *visible* rows,
  /// but programmatic focus on an off-screen row has no visible effect until the
  /// user scrolls there.
  public func virtualListFocusCoordinator(
    _ coordinator: VirtualListFocusCoordinator<some Hashable>
  ) -> VirtualList {
    var copy = self
    copy.configuration.focusBinder = VirtualListFocusBinder(focusCoordinator: coordinator)
    return copy
  }
}

// MARK: - Platform-specific scroll handlers

#if canImport(UIKit)
  extension VirtualListCoordinator {
    /// Scrolls to the row whose identifier matches `id`, if any. Used by the
    /// focus binder; safe to call on a torn-down coordinator. The class is
    /// already `@MainActor`, so the extension inherits the isolation.
    func scroll(toFocusedID id: AnyHashable) {
      guard let ip = indexPath(forItemID: id),
        let collectionView,
        collectionView.window != nil
      else { return }
      collectionView.scrollToItem(at: ip, at: .centeredVertically, animated: true)
    }
  }
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  extension VirtualListMacCoordinator {
    /// AppKit counterpart of the UIKit `scroll(toFocusedID:)`. Resolves the
    /// flat row index from the item id via the shared lazy reverse map, then
    /// asks `NSTableView` to scroll it into view. The window guard prevents
    /// scrolling against an unattached table, which would log a layout
    /// warning without any visible effect.
    func scroll(toFocusedID id: AnyHashable) {
      guard let row = row(forItemID: id),
        let tableView,
        tableView.window != nil
      else { return }
      tableView.scrollRowToVisible(row)
    }
  }
#endif
