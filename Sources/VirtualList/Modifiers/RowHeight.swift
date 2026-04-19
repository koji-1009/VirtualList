import SwiftUI

extension VirtualList {
  /// Pins every row to a fixed height, bypassing self-sizing. Useful when rows
  /// are known to be uniform and you want to avoid the per-row measurement cost.
  public func virtualListRowHeight(_ height: CGFloat) -> VirtualList {
    var copy = self
    copy.configuration.fixedRowHeight = height
    return copy
  }
}
