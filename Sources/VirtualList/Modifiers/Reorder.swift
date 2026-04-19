import SwiftUI

extension VirtualList {
  /// Enables interactive drag-and-drop reordering. The provided closure is invoked with
  /// the originating and destination `IndexPath`s once the user drops a row. Your
  /// handler is responsible for updating the backing data source; on the next render
  /// the new ordering propagates through the diffable data source.
  public func virtualListReorder(
    _ onMove: @escaping @MainActor (IndexPath, IndexPath) -> Void
  ) -> VirtualList {
    var copy = self
    copy.configuration.onMove = onMove
    return copy
  }
}
