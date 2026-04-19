#if canImport(UIKit)
  import SwiftUI

  extension VirtualList {
    /// Adds pull-to-refresh. Equivalent to SwiftUI's `.refreshable`. The action runs on
    /// the main actor; when it finishes the refresh indicator is dismissed.
    public func virtualListRefreshable(
      _ action: @escaping @Sendable () async -> Void
    ) -> VirtualList {
      var copy = self
      copy.configuration.refreshAction = action
      return copy
    }
  }
#endif
