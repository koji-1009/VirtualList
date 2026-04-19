import SwiftUI

#if canImport(UIKit)
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
#else
  // Pull-to-refresh has no AppKit equivalent — `NSScrollView` does not
  // expose a refresh gesture, and the idiomatic macOS refresh affordance
  // is a toolbar / menu button driven by the app, not the list. Rather
  // than let the call silently no-op on macOS, make it fail at compile
  // time with an explanatory message so the drop-in contract never
  // misleads.
  @available(macOS, unavailable, message: "Pull-to-refresh is iOS-only; AppKit has no equivalent gesture. Drive refresh from a toolbar / menu button on macOS.")
  extension VirtualList {
    public func virtualListRefreshable(
      _ action: @escaping @Sendable () async -> Void
    ) -> VirtualList {
      self
    }
  }
#endif
