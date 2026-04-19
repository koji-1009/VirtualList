import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// A row type that a `VirtualList` can recognise as participating in the
/// list's per-row modifier API.
///
/// Conforming types gain access to namespaced `.listRowBackground`,
/// `.listRowInsets`, `.swipeActions` etc. via protocol extensions defined
/// on `VirtualListRow`. Swift's method lookup prefers the more specific
/// protocol's extension over `SwiftUI.View`'s, so these calls dispatch to
/// the list-aware implementation rather than to the `View` versions
/// (which would be silent no-ops inside `VirtualList` because SwiftUI's
/// private preference keys aren't readable from outside the framework).
///
/// The simplest adoption path is to wrap inline content in
/// `VirtualListRowContainer`; callers who author their own row types can
/// conform those directly to `VirtualListRow`.
public protocol VirtualListRow: View {}

/// Concrete wrapper that adopts `VirtualListRow` so arbitrary inline
/// `SwiftUI.View`s can participate in the row API without the caller
/// introducing a bespoke row struct.
///
/// ```swift
/// VirtualList(items) { item in
///   VirtualListRowContainer {
///     Text(item.name)
///   }
///   .listRowBackground(Color.blue)
///   .swipeActions {
///     VirtualListSwipeAction(title: "Delete", style: .destructive) { ... }
///   }
/// }
/// ```
public struct VirtualListRowContainer<Content: View>: VirtualListRow {
  let content: Content

  public init(@ViewBuilder _ content: () -> Content) {
    self.content = content()
  }

  public var body: some View { content }
}

// MARK: - Per-row state plumbing (cross-platform)

/// Per-row state bucket populated by row-level modifiers and read by
/// the platform coordinator on cell configuration. Callback-backed
/// fields (`Slot<Value>`) fire an `onChange` on commit so the
/// coordinator can rebuild cell state lazily; direct-read fields are
/// consulted on demand by their respective handlers.
public final class VirtualListRowBox {
  public struct Slot<Value> {
    public internal(set) var value: Value?
    var onChange: ((Value?) -> Void)?

    mutating func commit(_ newValue: Value?) {
      value = newValue
      onChange?(newValue)
    }
  }

  var background = Slot<AnyView>()
  var insets = Slot<EdgeInsets>()
  var separator = Slot<VirtualListRowSeparatorVisibility>()
  var badge = Slot<AnyView>()

  #if canImport(UIKit)
    // AppKit has no swipe gesture for list rows, so swipe-action state
    // is iOS-only.
    var leadingSwipeActions: [VirtualListSwipeAction] = []
    var trailingSwipeActions: [VirtualListSwipeAction] = []
  #endif
}

/// Per-row separator visibility override, carrying independent values
/// for the row's top and bottom edges so `.listRowSeparator(_:edges:)`
/// can honour the `edges` parameter when a caller asks for one edge
/// only.
///
/// `.automatic` means "defer to the list's global separator state" —
/// the handler leaves that edge untouched, preserving the platform
/// default.
public struct VirtualListRowSeparatorVisibility: Equatable, Sendable {
  public var top: Visibility
  public var bottom: Visibility

  public init(top: Visibility, bottom: Visibility) {
    self.top = top
    self.bottom = bottom
  }
}

/// Environment-injected resolver that lazily allocates the per-row
/// `VirtualListRowBox` on first modifier fire. Rows with no row-level
/// modifier never allocate a box and never touch the coordinator's
/// `perRowBoxes` dictionary.
public struct VirtualListRowBoxProvider {
  weak var coordinator: (any VirtualListRowBoxHost)?
  let indexPath: IndexPath

  @MainActor
  func resolveBox() -> VirtualListRowBox? {
    coordinator?.ensureRowBox(at: indexPath)
  }
}

/// Abstract slice of the coordinator the row-modifier infrastructure
/// needs: "give me (or create) the box for this IndexPath". The
/// concrete implementations live on `VirtualListCoordinator` (iOS) and
/// `VirtualListMacCoordinator` (macOS).
protocol VirtualListRowBoxHost: AnyObject {
  @MainActor func ensureRowBox(at indexPath: IndexPath) -> VirtualListRowBox
}

private struct VirtualListRowBoxProviderKey: EnvironmentKey {
  static let defaultValue: VirtualListRowBoxProvider? = nil
}

extension EnvironmentValues {
  var virtualListRowBoxProvider: VirtualListRowBoxProvider? {
    get { self[VirtualListRowBoxProviderKey.self] }
    set { self[VirtualListRowBoxProviderKey.self] = newValue }
  }
}

/// Generic writer that every `Slot`-backed per-row modifier shares.
/// Takes a key path to the slot it should commit into, so each
/// public-facing modifier (`.listRowBackground`, `.listRowInsets`, …)
/// is a one-liner that hands the value + slot pointer to this struct.
struct VirtualListRowSlotModifier<Value>: ViewModifier {
  let value: Value?
  let slot: ReferenceWritableKeyPath<VirtualListRowBox, VirtualListRowBox.Slot<Value>>
  @Environment(\.virtualListRowBoxProvider) var provider

  func body(content: Content) -> some View {
    content.onAppear {
      guard let box = provider?.resolveBox() else { return }
      box[keyPath: slot].commit(value)
    }
  }
}

// MARK: - Cross-platform row modifiers

extension VirtualListRow {
  /// Row-level background view. Mirrors `SwiftUI.View.listRowBackground(_:)`.
  /// `nil` clears any previously-set background.
  public func listRowBackground<V: View>(_ view: V?) -> some View {
    modifier(
      VirtualListRowSlotModifier(
        value: view.map { AnyView($0) },
        slot: \VirtualListRowBox.background
      )
    )
  }

  /// Row-level content insets. Mirrors `SwiftUI.View.listRowInsets(_:)`.
  /// `nil` restores the list's default row padding.
  public func listRowInsets(_ insets: EdgeInsets?) -> some View {
    modifier(
      VirtualListRowSlotModifier(
        value: insets,
        slot: \VirtualListRowBox.insets
      )
    )
  }

  /// Row-level separator visibility. Mirrors
  /// `SwiftUI.View.listRowSeparator(_:edges:)`. Edges not listed in `edges`
  /// fall back to `.automatic`, so `.listRowSeparator(.hidden, edges: .bottom)`
  /// hides only the bottom separator.
  public func listRowSeparator(
    _ visibility: Visibility,
    edges: VerticalEdge.Set = .all
  ) -> some View {
    let config = VirtualListRowSeparatorVisibility(
      top: edges.contains(.top) ? visibility : .automatic,
      bottom: edges.contains(.bottom) ? visibility : .automatic
    )
    return modifier(
      VirtualListRowSlotModifier(
        value: config,
        slot: \VirtualListRowBox.separator
      )
    )
  }

  /// Integer badge. Mirrors `SwiftUI.View.badge(_:)` for `Int`:
  /// `count <= 0` hides the badge, matching SwiftUI's "zero is
  /// invisible" rule for counters.
  public func badge(_ count: Int) -> some View {
    let view: AnyView? = count <= 0 ? nil : AnyView(Text(count, format: .number))
    return modifier(
      VirtualListRowSlotModifier(value: view, slot: \VirtualListRowBox.badge)
    )
  }

  /// `Text`-driven badge. `nil` clears the badge. Mirrors
  /// `SwiftUI.View.badge(_:)` for `Text?`.
  public func badge(_ text: Text?) -> some View {
    let view: AnyView? = text.map { AnyView($0) }
    return modifier(
      VirtualListRowSlotModifier(value: view, slot: \VirtualListRowBox.badge)
    )
  }

  /// Localized-key badge. `nil` clears the badge. Mirrors
  /// `SwiftUI.View.badge(_:)` for `LocalizedStringKey?`.
  public func badge(_ key: LocalizedStringKey?) -> some View {
    let view: AnyView? = key.map { AnyView(Text($0)) }
    return modifier(
      VirtualListRowSlotModifier(value: view, slot: \VirtualListRowBox.badge)
    )
  }

  /// `StringProtocol`-driven badge. `nil` clears the badge. Mirrors
  /// `SwiftUI.View.badge(_:)` for `StringProtocol`.
  public func badge<S: StringProtocol>(_ text: S?) -> some View {
    let view: AnyView? = text.map { AnyView(Text(String($0))) }
    return modifier(
      VirtualListRowSlotModifier(value: view, slot: \VirtualListRowBox.badge)
    )
  }

  /// Row-level tint. Mirrors `SwiftUI.View.listItemTint(_:)` for the
  /// `Color?` overload. Inside `VirtualList`, a row's content is hosted
  /// through `UIHostingConfiguration` / `NSHostingView`, so
  /// `SwiftUI.List`'s private `.listItemTint` environment key doesn't
  /// reach it — calling the `View` version would compile silently and
  /// do nothing. Forwarding to `.tint(_:)` instead threads the value
  /// through the SwiftUI content tree so inline symbols, badges, and
  /// any `.tint`-consuming child pick it up.
  public func listItemTint(_ tint: Color?) -> some View {
    _VirtualListRowAsView(row: self).tint(tint)
  }

  /// Row-level context menu. Mirrors
  /// `SwiftUI.View.contextMenu(menuItems:)`. The redeclaration at the
  /// `VirtualListRow` level guards against a future protocol extension
  /// accidentally shadowing `SwiftUI.View.contextMenu` — the forward
  /// below is explicit about hitting `View`'s implementation rather
  /// than looping through this extension.
  public func contextMenu<MenuItems: View>(
    @ViewBuilder menuItems: () -> MenuItems
  ) -> some View {
    let items = menuItems()
    return _VirtualListRowAsView(row: self).contextMenu { items }
  }
}

/// Explicit `View` wrapper around a `VirtualListRow`. Forwarding
/// extensions (`.listItemTint`, `.contextMenu`) use this to escape the
/// protocol's method-lookup preference and dispatch to
/// `SwiftUI.View`'s implementation — without the wrapper, calling
/// `self.tint(...)` from inside a `VirtualListRow` extension would be
/// ambiguous if the protocol ever grew a `.tint` method.
private struct _VirtualListRowAsView<Row: VirtualListRow>: View {
  let row: Row
  var body: some View { row }
}

// MARK: - iOS-only: per-row swipe actions

#if canImport(UIKit)
  extension Visibility {
    /// Maps SwiftUI's `Visibility` to UIKit's
    /// `UIListSeparatorConfiguration.Visibility`. The two enums have
    /// matching cases; `.automatic` means "use the list's default" in
    /// both.
    var uiListSeparatorVisibility: UIListSeparatorConfiguration.Visibility {
      switch self {
      case .automatic: .automatic
      case .hidden: .hidden
      case .visible: .visible
      @unknown default: .automatic
      }
    }
  }

  /// Collects `VirtualListSwipeAction` instances written inline under a
  /// `.swipeActions { ... }` closure on a `VirtualListRow`.
  @resultBuilder
  public enum VirtualListSwipeActionsBuilder {
    public static func buildBlock(
      _ components: VirtualListSwipeAction...
    ) -> [VirtualListSwipeAction] {
      components
    }

    public static func buildArray(
      _ components: [[VirtualListSwipeAction]]
    ) -> [VirtualListSwipeAction] {
      components.flatMap { $0 }
    }

    public static func buildOptional(
      _ component: [VirtualListSwipeAction]?
    ) -> [VirtualListSwipeAction] {
      component ?? []
    }

    public static func buildEither(
      first component: [VirtualListSwipeAction]
    ) -> [VirtualListSwipeAction] {
      component
    }

    public static func buildEither(
      second component: [VirtualListSwipeAction]
    ) -> [VirtualListSwipeAction] {
      component
    }
  }

  /// Which edge a row-level `.swipeActions` call applies to. Mirrors
  /// `SwiftUI.HorizontalEdge` so call sites look identical.
  public enum VirtualListRowSwipeEdge: Sendable {
    case leading
    case trailing
  }

  /// Writes the caller's swipe-action list into the per-row box's
  /// direct-read field for its edge. The swipe provider reads these
  /// arrays on user interaction — no callback is needed.
  struct VirtualListRowSwipeActionsModifier: ViewModifier {
    let edge: VirtualListRowSwipeEdge
    let actions: [VirtualListSwipeAction]
    @Environment(\.virtualListRowBoxProvider) var provider

    func body(content: Content) -> some View {
      content.onAppear {
        guard let box = provider?.resolveBox() else { return }
        switch edge {
        case .leading: box.leadingSwipeActions = actions
        case .trailing: box.trailingSwipeActions = actions
        }
      }
    }
  }

  extension VirtualListRow {
    /// Row-level swipe actions (iOS only — AppKit has no swipe gesture
    /// for list rows). Dispatches to the list-aware implementation
    /// because Swift picks the `VirtualListRow` protocol extension
    /// over `SwiftUI.View.swipeActions(edge:allowsFullSwipe:content:)`.
    public func swipeActions(
      edge: VirtualListRowSwipeEdge = .trailing,
      @VirtualListSwipeActionsBuilder actions: () -> [VirtualListSwipeAction]
    ) -> some View {
      modifier(VirtualListRowSwipeActionsModifier(edge: edge, actions: actions()))
    }
  }
#endif
