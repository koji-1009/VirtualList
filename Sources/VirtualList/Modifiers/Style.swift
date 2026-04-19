import SwiftUI

extension VirtualList {
  /// Sets the overall list appearance. Mirrors `SwiftUI.View.listStyle(_:)`.
  public func virtualListStyle(_ style: VirtualListStyle) -> VirtualList {
    var copy = self
    copy.configuration.style = style
    return copy
  }

  /// Toggles row separators. Pass `nil` to defer to the style default.
  public func virtualListRowSeparators(_ visible: Bool?) -> VirtualList {
    var copy = self
    copy.configuration.rowSeparators = visible
    return copy
  }
}
