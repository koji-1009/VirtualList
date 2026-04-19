import SwiftUI

/// Declarative description of a section inside a `VirtualList` result-builder block.
///
/// Accepts a header, an optional footer, and one or more `VirtualItems` groups.
/// Multiple groups inside a single section flatten into one flat row list when
/// the enclosing list is materialised; each group keeps its own `id` / `content`
/// closures, so different identifier schemes can coexist inside the same section
/// (e.g. a "pinned" group and a "rest" group).
public struct VirtualSection {
  let id: AnyHashable
  let header: (@MainActor () -> AnyView)?
  let footer: (@MainActor () -> AnyView)?
  let itemGroups: [VirtualItems]

  public init(
    id: some Hashable,
    @ViewBuilder header: @escaping @MainActor () -> some View,
    @ViewBuilder footer: @escaping @MainActor () -> some View,
    @VirtualItemsBuilder items: () -> [VirtualItems]
  ) {
    self.id = AnyHashable(id)
    self.header = { AnyView(header()) }
    self.footer = { AnyView(footer()) }
    itemGroups = items()
  }

  public init(
    id: some Hashable,
    @ViewBuilder header: @escaping @MainActor () -> some View,
    @VirtualItemsBuilder items: () -> [VirtualItems]
  ) {
    self.id = AnyHashable(id)
    self.header = { AnyView(header()) }
    footer = nil
    itemGroups = items()
  }

  public init(
    id: some Hashable,
    @VirtualItemsBuilder items: () -> [VirtualItems]
  ) {
    self.id = AnyHashable(id)
    header = nil
    footer = nil
    itemGroups = items()
  }

  func build() -> VirtualListSection {
    let groups = itemGroups
    // Precompute the offset of each group's first item so the flattened
    // index→(group, local index) mapping is O(log groups) via binary search,
    // not O(groups) per row access. Typical sections have 1–3 groups; the
    // binary search still wins when a section is packed with more.
    var offsets: [Int] = []
    offsets.reserveCapacity(groups.count)
    var total = 0
    for group in groups {
      offsets.append(total)
      total += group.itemCount
    }

    let itemID: @MainActor (Int) -> AnyHashable = { absIdx in
      let (groupIdx, localIdx) = Self.resolve(
        absoluteIndex: absIdx,
        offsets: offsets,
        totalCount: total
      )
      return groups[groupIdx].itemID(localIdx)
    }
    let itemView: @MainActor (Int) -> AnyView = { absIdx in
      let (groupIdx, localIdx) = Self.resolve(
        absoluteIndex: absIdx,
        offsets: offsets,
        totalCount: total
      )
      return groups[groupIdx].itemView(localIdx)
    }
    return VirtualListSection(
      id: id,
      itemCount: total,
      itemID: itemID,
      itemView: itemView,
      header: header,
      footer: footer
    )
  }

  private static func resolve(
    absoluteIndex abs: Int,
    offsets: [Int],
    totalCount: Int
  ) -> (group: Int, local: Int) {
    precondition(abs >= 0 && abs < totalCount, "VirtualSection index out of range")
    // Largest offset ≤ abs. Standard upper-bound variant of binary search.
    var lo = 0
    var hi = offsets.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if offsets[mid] <= abs {
        lo = mid
      } else {
        hi = mid - 1
      }
    }
    return (group: lo, local: abs - offsets[lo])
  }
}

/// Accumulates one or more `VirtualItems` groups into a single section. Passing a
/// single `VirtualItems` block keeps the existing shape; passing several flattens
/// them in order.
@resultBuilder
public enum VirtualItemsBuilder {
  public static func buildBlock(_ components: VirtualItems...) -> [VirtualItems] {
    components
  }

  /// Allows an `if`-produced `VirtualItems` to appear inside the builder block.
  public static func buildOptional(_ component: [VirtualItems]?) -> [VirtualItems] {
    component ?? []
  }

  public static func buildEither(first component: [VirtualItems]) -> [VirtualItems] {
    component
  }

  public static func buildEither(second component: [VirtualItems]) -> [VirtualItems] {
    component
  }
}
