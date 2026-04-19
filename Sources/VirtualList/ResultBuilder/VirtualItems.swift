import SwiftUI

/// A lazy description of the items that live inside a section.
///
/// `VirtualItems` is a small value type that stores the item count and the two closures
/// `VirtualList` needs to build each row: `id(_:)` and the SwiftUI view builder.
public struct VirtualItems {
  let itemCount: Int
  let itemID: @MainActor (Int) -> AnyHashable
  let itemView: @MainActor (Int) -> AnyView

  /// Index-keyed constructor matching the top-level `VirtualList` builder init.
  public init(
    count: Int,
    id: @escaping @MainActor (Int) -> some Hashable,
    @ViewBuilder content: @escaping @MainActor (Int) -> some View
  ) {
    itemCount = count
    itemID = { AnyHashable(id($0)) }
    itemView = { AnyView(content($0)) }
  }

  /// Collection-based convenience that mirrors `ForEach(_:id:content:)`.
  public init<Data: RandomAccessCollection>(
    _ data: Data,
    id: KeyPath<Data.Element, some Hashable>,
    @ViewBuilder content: @escaping @MainActor (Data.Element) -> some View
  ) where Data.Index == Int {
    let captured = data
    itemCount = captured.count
    itemID = { AnyHashable(captured[captured.startIndex + $0][keyPath: id]) }
    itemView = { AnyView(content(captured[captured.startIndex + $0])) }
  }

  /// Collection-based convenience for `Identifiable` elements.
  public init<Data: RandomAccessCollection>(
    _ data: Data,
    @ViewBuilder content: @escaping @MainActor (Data.Element) -> some View
  ) where Data.Element: Identifiable, Data.Index == Int {
    let captured = data
    itemCount = captured.count
    itemID = { AnyHashable(captured[captured.startIndex + $0].id) }
    itemView = { AnyView(content(captured[captured.startIndex + $0])) }
  }

  func buildAsSection(
    id: AnyHashable,
    header: (@MainActor () -> AnyView)? = nil,
    footer: (@MainActor () -> AnyView)? = nil
  ) -> VirtualListSection {
    VirtualListSection(
      id: id,
      itemCount: itemCount,
      itemID: itemID,
      itemView: itemView,
      header: header,
      footer: footer
    )
  }
}
