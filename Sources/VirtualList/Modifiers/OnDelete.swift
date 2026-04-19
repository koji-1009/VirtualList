import SwiftUI

extension VirtualList {
  /// List-level delete handler. Mirrors
  /// `SwiftUI.ForEach.onDelete(perform:)`: the closure fires with an
  /// `IndexSet` containing the affected row's position within its
  /// section.
  ///
  /// Surface differs by platform because the idiomatic delete
  /// affordance does:
  ///
  /// - **iOS / Catalyst**: a default destructive trailing-swipe
  ///   "Delete" action is rendered for each row. Priority order for
  ///   the trailing-swipe provider is: per-row `.swipeActions { ... }`
  ///   → list-level `.virtualListSwipeActions(edge: .trailing, ...)`
  ///   → this `.onDelete` default. If a caller wires both
  ///   `.onDelete` and a custom trailing swipe provider, the custom
  ///   provider wins — matching SwiftUI's precedence.
  /// - **macOS**: the ⌫ (Delete) key on the focused row fires the
  ///   handler. Multi-selection deletes surface every selected
  ///   row's index in the `IndexSet`.
  public func onDelete(
    perform action: @escaping @MainActor (IndexSet) -> Void
  ) -> VirtualList {
    var copy = self
    copy.configuration.onDelete = action
    return copy
  }
}
