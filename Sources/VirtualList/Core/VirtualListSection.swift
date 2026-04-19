import SwiftUI

/// Type-erased description of a single section displayed by a `VirtualList`.
///
/// Sections expose an item *count* plus index-keyed closures for identity and view
/// construction. Nothing in the section eagerly materializes per-item state, which is
/// what lets `VirtualList` render millions of rows without walking the full collection.
public struct VirtualListSection {
  /// The stable identity of this section. Used as the diffable section identifier
  /// and as a namespace so identical item IDs can live in different sections.
  public let id: AnyHashable

  /// The number of items in this section.
  public let itemCount: Int

  /// Maps an in-section index to its stable identifier.
  ///
  /// Called from the main actor whenever `VirtualList` needs to assemble a
  /// diffable snapshot. For a 1M-row list this closure is invoked 1M times *per
  /// snapshot apply*, so keep it cheap.
  public let itemID: @MainActor (Int) -> AnyHashable

  /// Maps an in-section index to a SwiftUI view. Invoked lazily, only for
  /// items that become visible.
  public let itemView: @MainActor (Int) -> AnyView

  /// Optional section header view builder.
  public let header: (@MainActor () -> AnyView)?

  /// Optional section footer view builder.
  public let footer: (@MainActor () -> AnyView)?

  public init(
    id: some Hashable,
    itemCount: Int,
    itemID: @escaping @MainActor (Int) -> some Hashable,
    @ViewBuilder itemView: @escaping @MainActor (Int) -> some View,
    header: (@MainActor () -> AnyView)? = nil,
    footer: (@MainActor () -> AnyView)? = nil
  ) {
    self.id = AnyHashable(id)
    self.itemCount = itemCount
    self.itemID = { AnyHashable(itemID($0)) }
    self.itemView = { AnyView(itemView($0)) }
    self.header = header
    self.footer = footer
  }

  init(
    id: AnyHashable,
    itemCount: Int,
    itemID: @escaping @MainActor (Int) -> AnyHashable,
    itemView: @escaping @MainActor (Int) -> AnyView,
    header: (@MainActor () -> AnyView)?,
    footer: (@MainActor () -> AnyView)?
  ) {
    self.id = id
    self.itemCount = itemCount
    self.itemID = itemID
    self.itemView = itemView
    self.header = header
    self.footer = footer
  }
}
