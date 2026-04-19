import SwiftUI

#if canImport(UIKit)
  import UIKit

  /// Declarative description of a single swipe action. Converted to a
  /// `UIContextualAction` when the row is swiped.
  public struct VirtualListSwipeAction {
    public enum Style: Sendable {
      case normal
      case destructive
    }

    public let title: String
    public let style: Style
    public let backgroundColor: UIColor?
    public let image: UIImage?
    public let handler: @MainActor (IndexPath, @escaping (Bool) -> Void) -> Void

    /// Full-control init: you own the completion callback and can defer it for
    /// async work (e.g. a confirmation alert). Call `completion(true)` when the
    /// action succeeded, `completion(false)` to bounce the swipe back.
    public init(
      title: String,
      style: Style = .normal,
      backgroundColor: UIColor? = nil,
      image: UIImage? = nil,
      handler: @escaping @MainActor (IndexPath, @escaping (Bool) -> Void) -> Void
    ) {
      self.title = title
      self.style = style
      self.backgroundColor = backgroundColor
      self.image = image
      self.handler = handler
    }

    /// Convenience for synchronous actions that always succeed.
    public init(
      title: String,
      style: Style = .normal,
      backgroundColor: UIColor? = nil,
      image: UIImage? = nil,
      perform: @escaping @MainActor (IndexPath) -> Void
    ) {
      self.init(
        title: title,
        style: style,
        backgroundColor: backgroundColor,
        image: image
      ) { ip, completion in
        perform(ip)
        completion(true)
      }
    }
  }

  /// Which edge the swipe reveals actions on.
  public enum VirtualListSwipeEdge: Sendable {
    case leading
    case trailing
  }

  extension VirtualList {
    /// Attaches swipe actions to every row. The provider receives the row's
    /// `IndexPath` and returns zero or more actions to show.
    public func virtualListSwipeActions(
      edge: VirtualListSwipeEdge,
      actions: @escaping @MainActor (IndexPath) -> [VirtualListSwipeAction]
    ) -> VirtualList {
      var copy = self
      let provider = VirtualListSwipeActionsProvider { indexPath in
        let actions = actions(indexPath)
        if actions.isEmpty { return nil }
        let contextual: [UIContextualAction] = actions.map { action in
          let ca = UIContextualAction(
            style: action.style == .destructive ? .destructive : .normal,
            title: action.title
          ) { _, _, completion in
            action.handler(indexPath, completion)
          }
          ca.backgroundColor = action.backgroundColor
          ca.image = action.image
          return ca
        }
        return UISwipeActionsConfiguration(actions: contextual)
      }
      switch edge {
      case .leading: copy.configuration.swipeActionsLeading = provider
      case .trailing: copy.configuration.swipeActionsTrailing = provider
      }
      return copy
    }

  }

  /// Resolves UIKit's system-provided "Delete" localised title so the
  /// default `.onDelete` swipe button matches `SwiftUI.List` /
  /// `UITableView` text across languages. The `Bundle(for:)` lookup
  /// against a `UIKit` class walks the framework's localisation
  /// tables; falling back to the literal "Delete" keeps behaviour
  /// graceful if the key moves in a future OS.
  func virtualListSystemDeleteTitle() -> String {
    Bundle(for: UITableView.self).localizedString(
      forKey: "Delete",
      value: "Delete",
      table: nil
    )
  }

#else

  // AppKit has no swipe gesture for list rows. `NSTableView` surfaces
  // row-level actions through contextual menus or drag-and-drop, neither
  // of which maps onto the `.virtualListSwipeActions` shape. Rather than
  // let the call silently no-op on macOS, mark the surface as
  // `@available(macOS, unavailable)` so a `s/List/VirtualList/g`
  // migration fails at compile time with an explanatory message.
  @available(
    macOS, unavailable,
    message:
      "Swipe actions are iOS-only; AppKit has no swipe gesture for list rows. Use a context menu (`.contextMenu { ... }`) on macOS instead."
  )
  public struct VirtualListSwipeAction {
    public enum Style: Sendable {
      case normal
      case destructive
    }
    public init(
      title: String,
      style: Style = .normal,
      perform: @escaping @MainActor (IndexPath) -> Void
    ) {}
  }

  @available(macOS, unavailable, message: "Swipe actions are iOS-only.")
  public enum VirtualListSwipeEdge: Sendable {
    case leading
    case trailing
  }

  @available(
    macOS, unavailable,
    message: "Swipe actions are iOS-only; AppKit has no swipe gesture for list rows."
  )
  extension VirtualList {
    public func virtualListSwipeActions(
      edge: VirtualListSwipeEdge,
      actions: @escaping @MainActor (IndexPath) -> [VirtualListSwipeAction]
    ) -> VirtualList {
      self
    }
  }

#endif
