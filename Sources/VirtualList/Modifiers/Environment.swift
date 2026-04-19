import SwiftUI

/// Opaque wrapper that captures a single environment value and re-applies it
/// on a hosted SwiftUI view.
///
/// Each modifier (`.virtualListEnvironment(_:_:)` or
/// `.virtualListEnvironmentObject(_:)`) pushes one of these onto the
/// configuration's override list; the coordinators replay the list on every
/// cell configuration via `decorate(view:)`.
public struct VirtualListEnvironmentOverride {
  let apply: @MainActor (AnyView) -> AnyView

  init<Value>(keyPath: WritableKeyPath<EnvironmentValues, Value>, value: Value) {
    apply = { view in
      AnyView(view.environment(keyPath, value))
    }
  }

  init(object: some ObservableObject) {
    apply = { view in
      AnyView(view.environmentObject(object))
    }
  }
}

extension VirtualList {
  /// Forwards a custom environment value into every hosted cell.
  ///
  /// Trait-backed environment values (colorScheme, locale, …) propagate into
  /// cells automatically via `UITraitCollection` (iOS) or
  /// `NSAppearance` / view hierarchy (macOS). Values that SwiftUI cannot
  /// deliver through traits — parent `.font`, `.disabled`, custom
  /// `EnvironmentKey`s — need this explicit forward.
  public func virtualListEnvironment<Value>(
    _ keyPath: WritableKeyPath<EnvironmentValues, Value>,
    _ value: Value
  ) -> VirtualList {
    var copy = self
    copy.configuration.environmentOverrides.append(
      VirtualListEnvironmentOverride(keyPath: keyPath, value: value)
    )
    return copy
  }

  /// Forwards a SwiftUI environment object into every hosted cell.
  public func virtualListEnvironmentObject(
    _ object: some ObservableObject
  ) -> VirtualList {
    var copy = self
    copy.configuration.environmentOverrides.append(
      VirtualListEnvironmentOverride(object: object)
    )
    return copy
  }
}
