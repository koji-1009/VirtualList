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

/// Per-cell configuration slot. Row-level modifiers
/// (`.swipeActions`, `.listRowBackground`, `.listRowInsets`,
/// `.listRowSeparator`, `.badge`) write into fields of this class via
/// their ViewModifier, and the platform coordinator reads the fields
/// back to apply them to cell state.
///
/// Features split into two patterns by their integration:
///
/// - **Direct-read fields** (`leadingSwipeActions`,
///   `trailingSwipeActions`) are consulted on demand by their
///   platform-specific handlers (e.g. the iOS swipe provider) — no
///   callback needed, the field is just read the next time the user
///   interacts.
///
/// - **Callback slots** (`background`, `insets`, `separator`, `badge`)
///   need cell state to be rebuilt when the modifier fires, because
///   the value they control is baked into the cell at render time.
///   Each slot stores `(value, onChange)`; the modifier writes `value`
///   and fires `onChange`, letting the coordinator update the cell
///   lazily.
public final class VirtualListRowBox {
  /// Paired state + change notification used by every callback-driven
  /// per-row feature. Writing `value` fires `onChange` — that's the
  /// core shape the generic `VirtualListRowSlotModifier` relies on.
  public struct Slot<Value> {
    public internal(set) var value: Value?
    var onChange: ((Value?) -> Void)?

    mutating func commit(_ newValue: Value?) {
      value = newValue
      onChange?(newValue)
    }
  }

  // Background view rendered behind the row. iOS wires it through
  // `UIBackgroundConfiguration.customView`; macOS wires it through
  // `NSTableRowView`'s background.
  var background = Slot<AnyView>()

  // Content insets. iOS applies via `UIHostingConfiguration.margins`;
  // macOS applies via `NSTableCellView` padding constraints.
  var insets = Slot<EdgeInsets>()

  // Per-row separator visibility. iOS reads via the layout's
  // `itemSeparatorHandler`; macOS draws separators itself in a custom
  // row view.
  var separator = Slot<VirtualListRowSeparatorVisibility>()

  // Trailing badge content. iOS hosts via `UICellAccessory.customView`
  // backed by `UIHostingController`; macOS hosts via `NSHostingView`
  // pinned to the trailing edge of the cell.
  var badge = Slot<AnyView>()

  #if canImport(UIKit)
    // Swipe actions — iOS-only (AppKit has no swipe gesture). Read on
    // demand by the layout's swipe provider, no callback needed.
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

/// Lightweight value the coordinator injects into every cell's hosted
/// view tree so row-level modifiers can locate (or lazily create) their
/// `VirtualListRowBox` on demand.
///
/// Crucially, this provider does **not** own a box. Allocation is
/// deferred to the point where a modifier's `.onAppear` actually fires
/// — rows without any row-level modifier never materialise a box,
/// never allocate the `onChange` closures that wire the coordinator
/// callbacks, and never touch the `perRowBoxes` dictionary. That keeps
/// the no-modifier path close to the cost it had before row-level
/// infrastructure existed.
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
  /// Row-level background view. Mirrors
  /// `SwiftUI.View.listRowBackground(_:)`. Passing `nil` explicitly
  /// clears any previously-set background.
  ///
  /// - iOS / Catalyst: renders through
  ///   `UIBackgroundConfiguration.customView`, so the declared
  ///   background extends edge-to-edge past the hosting
  ///   configuration's content margins.
  /// - macOS: renders through `NSTableRowView`'s background fill,
  ///   matching the cell's full width.
  ///
  /// Rows that never declare a background pay no extra cost: no
  /// hosting controller is allocated for the row.
  public func listRowBackground<V: View>(_ view: V?) -> some View {
    modifier(
      VirtualListRowSlotModifier(
        value: view.map { AnyView($0) },
        slot: \VirtualListRowBox.background
      )
    )
  }

  /// Row-level content insets. Mirrors
  /// `SwiftUI.View.listRowInsets(_:)`. Passing `nil` restores the
  /// list's default row padding.
  ///
  /// - iOS / Catalyst: `UIHostingConfiguration.margins(_:_:)` on the
  ///   underlying cell.
  /// - macOS: padding constraints on the hosted SwiftUI view inside
  ///   the table cell.
  public func listRowInsets(_ insets: EdgeInsets?) -> some View {
    modifier(
      VirtualListRowSlotModifier(
        value: insets,
        slot: \VirtualListRowBox.insets
      )
    )
  }

  /// Row-level separator visibility. Mirrors
  /// `SwiftUI.View.listRowSeparator(_:edges:)`.
  ///
  /// - iOS / Catalyst: applied via
  ///   `UICollectionLayoutListConfiguration.itemSeparatorHandler`.
  /// - macOS: the custom row view hides the grid line for this row
  ///   when `.hidden` is set.
  ///
  /// Edges not listed in `edges` fall back to `.automatic`, so
  /// `.listRowSeparator(.hidden, edges: .bottom)` hides only the
  /// bottom separator and leaves the top edge at the list's global
  /// default.
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
