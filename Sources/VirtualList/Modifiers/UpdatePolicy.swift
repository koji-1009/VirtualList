import SwiftUI

extension VirtualList {
  /// Selects which kind of data source backs the list.
  ///
  /// - `.diffed` (default): diffable data source with animated inserts / deletes,
  ///   at the cost of an O(N) snapshot build per structural change.
  /// - `.indexed`: classic data source answering `numberOfItemsInSection` from
  ///   the stored count. O(1) applies, no per-row identifiers allocated, but
  ///   reloads are unanimated.
  public func virtualListUpdatePolicy(_ policy: VirtualListUpdatePolicy) -> VirtualList {
    var copy = self
    copy.configuration.updatePolicy = policy
    return copy
  }
}
