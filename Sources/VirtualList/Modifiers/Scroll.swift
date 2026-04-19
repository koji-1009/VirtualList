import SwiftUI

extension VirtualList {
  /// Controls whether the list's underlying scroll surface draws the
  /// platform's default list background. Mirrors
  /// `SwiftUI.View.scrollContentBackground(_:)`.
  ///
  /// - `.hidden` (explicit): scroll surface stays clear so a
  ///   surrounding SwiftUI `.background(...)` shows through. This is
  ///   also `VirtualList`'s default when the modifier is not set,
  ///   preserving the historical behaviour.
  /// - `.visible`: scroll surface paints the platform's default
  ///   window background (`systemBackground` on iOS,
  ///   `windowBackgroundColor` on macOS) so the list feels opaque
  ///   over mixed backgrounds.
  /// - `.automatic`: same as `.hidden` — `VirtualList` has no
  ///   style-derived default background to install.
  public func scrollContentBackground(_ visibility: Visibility) -> VirtualList {
    var copy = self
    copy.configuration.scrollContentBackground = visibility
    return copy
  }
}

#if canImport(UIKit)
  import UIKit

  extension VirtualList {
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

#else

  // macOS has no soft keyboard, so keyboard-dismiss behaviour is
  // meaningless on that platform. Mark the surface as
  // `@available(macOS, unavailable)` so a `s/List/VirtualList/g`
  // migration fails at compile time with an explanatory message.
  @available(macOS, unavailable, message: "Keyboard-dismiss control is iOS-only; macOS has no on-screen keyboard that scroll gestures could dismiss.")
  extension VirtualList {
    public func scrollDismissesKeyboard(
      _ mode: ScrollDismissesKeyboardMode
    ) -> VirtualList {
      self
    }
  }

#endif
