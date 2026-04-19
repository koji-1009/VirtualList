#if canImport(UIKit)
  import SwiftUI
  import UIKit

  extension VirtualList {
    /// Controls whether the collection view draws the platform's
    /// default list background. Mirrors
    /// `SwiftUI.View.scrollContentBackground(_:)`.
    ///
    /// - `.hidden` (explicit): collection view background stays clear
    ///   so a surrounding SwiftUI `.background(...)` shows through.
    ///   This is also `VirtualList`'s default when the modifier is
    ///   not set, preserving the historical behaviour.
    /// - `.visible`: collection view paints `.systemBackground` so
    ///   the list feels opaque over mixed backgrounds.
    /// - `.automatic`: same as `.hidden` — `VirtualList` has no
    ///   style-derived default background to install.
    public func scrollContentBackground(_ visibility: Visibility) -> VirtualList {
      var copy = self
      copy.configuration.scrollContentBackground = visibility
      return copy
    }

    /// Controls how scrolling interacts with an active keyboard.
    /// Mirrors `SwiftUI.View.scrollDismissesKeyboard(_:)`.
    ///
    /// Maps to `UIScrollView.keyboardDismissMode` on the underlying
    /// collection view:
    ///
    /// - `.automatic` → `.interactive` (a drag-to-dismiss affordance
    ///   that most list-with-keyboard flows want)
    /// - `.immediately` → `.onDrag`
    /// - `.interactively` → `.interactive`
    /// - `.never` → `.none`
    public func scrollDismissesKeyboard(
      _ mode: ScrollDismissesKeyboardMode
    ) -> VirtualList {
      var copy = self
      copy.configuration.scrollDismissesKeyboard = mode
      return copy
    }
  }

  /// Resolves a `ScrollDismissesKeyboardMode` to the underlying
  /// `UIScrollView.KeyboardDismissMode`. Pulled out of the modifier
  /// so the apply path in `updateUIView` can call it too.
  func virtualListKeyboardDismissMode(
    for mode: ScrollDismissesKeyboardMode
  ) -> UIScrollView.KeyboardDismissMode {
    switch mode {
    case .immediately: .onDrag
    case .interactively: .interactive
    case .never: .none
    default: .interactive  // covers `.automatic` and forwards-compat cases
    }
  }
#endif
