import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// Internal configuration assembled from `virtualList*` view modifiers.
///
/// `VirtualList` is a value type, so modifiers mutate a copy of the configuration
/// that is re-read on every render pass.
///
/// Platform-specific modifiers (swipe actions, pull-to-refresh) live inside the
/// UIKit-gated section below. On AppKit those modifiers do not exist as public
/// surface (macOS has no idiomatic pull-to-refresh or swipe gestures for lists),
/// so a cross-platform call site that avoids them works on both platforms.
struct VirtualListConfiguration {
  var style: VirtualListStyle = .plain
  var updatePolicy: VirtualListUpdatePolicy = .diffed
  var fixedRowHeight: CGFloat?
  var rowSeparators: Bool?
  var environmentOverrides: [VirtualListEnvironmentOverride] = []

  var selectionBox: (any VirtualListSelectionBoxProtocol)?
  var onMove: (@MainActor (IndexPath, IndexPath) -> Void)?
  var gridColumns: VirtualListGridColumns?
  var focusBinder: (any VirtualListFocusBinderProtocol)?

  /// List-level delete handler registered through
  /// `.onDelete(perform:)`. Matches SwiftUI's `ForEach.onDelete`
  /// semantics: the coordinator invokes this closure with the
  /// affected row's `IndexSet`. On iOS it materialises a default
  /// destructive trailing-swipe action; on macOS it fires when the
  /// user presses the Delete key on the selected row(s).
  var onDelete: (@MainActor (IndexSet) -> Void)?

  /// Scroll-content-background visibility, set through
  /// `.scrollContentBackground(_:)`. `.hidden` keeps the
  /// collection view's / scroll view's background clear so a
  /// surrounding SwiftUI `.background(...)` shows through;
  /// `.visible` installs the platform's default list background.
  /// `nil` means "modifier wasn't used — preserve the current
  /// behaviour" (clear).
  var scrollContentBackground: Visibility?

  #if canImport(UIKit)
    var swipeActionsLeading: VirtualListSwipeActionsProvider?
    var swipeActionsTrailing: VirtualListSwipeActionsProvider?
    var refreshAction: (@Sendable () async -> Void)?

    /// Keyboard-dismiss behaviour set through
    /// `.scrollDismissesKeyboard(_:)`. Maps to
    /// `UIScrollView.keyboardDismissMode` on the underlying collection
    /// view. `nil` leaves the collection view's default (`.none`)
    /// untouched.
    var scrollDismissesKeyboard: ScrollDismissesKeyboardMode?
  #endif
}

/// Non-generic protocol that lets us hold a generic `VirtualListSelectionBox`
/// inside the non-generic `VirtualListConfiguration`. Independent of UIKit /
/// AppKit — the selection binding itself is pure SwiftUI.
protocol VirtualListSelectionBoxProtocol {
  var allowsSelection: Bool { get }
  var allowsMultipleSelection: Bool { get }
  @MainActor func read() -> Set<AnyHashable>
  @MainActor func write(_ selection: Set<AnyHashable>)
}

/// Cross-platform focus binder: the binder installs a scroll handler that the
/// active coordinator (UIKit or AppKit) fills in with its own scroll-to
/// implementation. This keeps the binder independent of the platform
/// coordinator type.
protocol VirtualListFocusBinderProtocol: AnyObject {
  @MainActor func attachScrollHandler(_ handler: @escaping @MainActor (AnyHashable) -> Void)
  @MainActor func detach()
}

#if canImport(UIKit)
  extension VirtualListStyle {
    var appearance: UICollectionLayoutListConfiguration.Appearance {
      switch self {
      case .plain: .plain
      case .grouped: .grouped
      case .insetGrouped: .insetGrouped
      case .sidebar: .sidebar
      case .sidebarPlain: .sidebarPlain
      }
    }
  }

  /// Closure-based swipe-actions provider. UIKit-only — AppKit has no
  /// equivalent swipe gesture for list rows.
  struct VirtualListSwipeActionsProvider {
    let build: @MainActor (IndexPath) -> UISwipeActionsConfiguration?
  }
#endif
