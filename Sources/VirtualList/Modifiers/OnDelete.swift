import SwiftUI

extension VirtualList {
  /// List-level delete handler. Mirrors `SwiftUI.ForEach.onDelete(perform:)`.
  ///
  /// On iOS the default trailing-swipe "Delete" action fires it (overridden
  /// by a more-specific `.swipeActions` if set). On macOS the ⌫ key on the
  /// selection fires it.
  public func onDelete(
    perform action: @escaping @MainActor (IndexSet) -> Void
  ) -> VirtualList {
    var copy = self
    copy.configuration.onDelete = action
    return copy
  }
}
