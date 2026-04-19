import SwiftUI

extension VirtualList {
  /// Switches the layout from a vertical list to a grid with the supplied columns.
  /// Equivalent in spirit to `LazyVGrid(columns:)`.
  public func virtualListColumns(_ columns: VirtualListGridColumns) -> VirtualList {
    var copy = self
    copy.configuration.gridColumns = columns
    return copy
  }
}
