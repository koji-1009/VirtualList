import Combine
import SwiftUI

/// Keyboard focus coordinator for rows inside a `VirtualList`.
///
/// SwiftUI's built-in `@FocusState` does not survive cell reuse: when a hosted cell
/// gets recycled to render a different row, the SwiftUI-side focus identity is lost
/// and focus can snap to the wrong row. `VirtualListFocusCoordinator` works around that
/// by storing the focused *item id* (a value type) outside the cell, so reused cells
/// rehydrate focus state from the coordinator instead of from stale `@FocusState`.
///
/// Attach it via `.virtualListFocused(_:id:)` on a focusable view inside a row, then
/// drive focus programmatically with `focus(id:)`.
///
/// If you also want programmatic focus to scroll the target row into view, attach the
/// coordinator to the list with `.virtualListFocusCoordinator(_:)`. Without that
/// modifier, `focus(id:)` only has a visible effect for rows that are already on
/// screen.
@MainActor
public final class VirtualListFocusCoordinator<ID: Hashable>: ObservableObject {
  @Published public var currentID: ID?

  /// Called by `focus(id:)` when a new non-nil id is requested. Installed by
  /// `.virtualListFocusCoordinator(_:)` so `VirtualList` can scroll the target
  /// row into view. Cross-platform: the handler is opaque to the coordinator.
  var scrollHandler: (@MainActor (AnyHashable) -> Void)?

  public init(initial: ID? = nil) {
    currentID = initial
  }

  /// Move focus to the row identified by `id`. If a scroll handler has been
  /// attached, the row is also scrolled into view.
  public func focus(id: ID?) {
    currentID = id
    if let id {
      scrollHandler?(AnyHashable(id))
    }
  }

  /// Remove focus.
  public func clear() {
    currentID = nil
  }
}
