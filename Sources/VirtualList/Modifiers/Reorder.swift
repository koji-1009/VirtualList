import SwiftUI

extension VirtualList {
  /// Registers a reorder handler. The closure receives the source and
  /// destination `IndexPath` once the user drops a row; the handler owns
  /// the backing-data mutation and the new ordering propagates back
  /// through the next render.
  ///
  /// Setting this modifier makes every row reorder-enabled:
  /// - on iOS, each cell gains a trailing `UICellAccessory.reorder()`
  ///   drag handle, and the collection view's long-press gesture also
  ///   initiates a reorder
  /// - on macOS the handler is wired into the table's drag-reorder path
  ///   (see `.virtualListReorder` coverage in the macOS coordinator)
  ///
  /// Omit this modifier to disable reorder entirely — no drag handle is
  /// rendered and the long-press gesture's reorder callback short-circuits.
  public func virtualListReorder(
    _ onMove: @escaping @MainActor (IndexPath, IndexPath) -> Void
  ) -> VirtualList {
    var copy = self
    copy.configuration.onMove = onMove
    return copy
  }
}
