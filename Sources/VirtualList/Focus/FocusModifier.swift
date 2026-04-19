import SwiftUI

extension View {
  /// Binds this view's focus to a `VirtualListFocusCoordinator` entry.
  ///
  /// Apply to the focusable view (`TextField`, `Button`, ...) inside a row. When the
  /// coordinator's `currentID` equals `id`, this view gains focus; when the user
  /// tabs to this view, the coordinator's `currentID` is updated.
  public func virtualListFocused<ID: Hashable>(
    _ coordinator: VirtualListFocusCoordinator<ID>,
    id: ID
  ) -> some View {
    modifier(VirtualListFocusedModifier(coordinator: coordinator, id: id))
  }
}

private struct VirtualListFocusedModifier<ID: Hashable>: ViewModifier {
  @ObservedObject var coordinator: VirtualListFocusCoordinator<ID>
  let id: ID
  @FocusState private var isFocused: Bool

  func body(content: Content) -> some View {
    content
      .focused($isFocused)
      .onAppear {
        if coordinator.currentID == id { isFocused = true }
      }
      .onChange(of: coordinator.currentID) { _, newValue in
        let shouldBeFocused = (newValue == id)
        if isFocused != shouldBeFocused {
          isFocused = shouldBeFocused
        }
      }
      .onChange(of: isFocused) { _, newValue in
        if newValue {
          if coordinator.currentID != id {
            coordinator.currentID = id
          }
        } else if coordinator.currentID == id {
          coordinator.currentID = nil
        }
      }
  }
}
