import SwiftUI

extension VirtualList {
  /// Index-based constructor. `itemCount` describes the size of the logical collection,
  /// `id` produces a stable identifier for an index, and `content` builds a view for an
  /// index. `content` is invoked lazily — only for rows that are currently visible.
  ///
  /// Use this form when you have a very large dataset and do not want to allocate or
  /// walk all items up front (the `List(0..<N, id:)` pattern scales linearly with `N`,
  /// while this form scales with the visible range).
  public init(
    itemCount: Int,
    id: @escaping @MainActor (Int) -> some Hashable,
    @ViewBuilder content: @escaping @MainActor (Int) -> some View
  ) {
    let section = VirtualListSection(
      id: AnyHashable(DefaultSectionID.default),
      itemCount: itemCount,
      itemID: { AnyHashable(id($0)) },
      itemView: { AnyView(content($0)) },
      header: nil,
      footer: nil
    )
    self.init(sections: [section], configuration: VirtualListConfiguration())
  }

  /// Collection-based constructor with an explicit id key path. Mirrors
  /// `List(_:id:content:)` so existing call sites can swap in `VirtualList`.
  public init<Data: RandomAccessCollection>(
    _ data: Data,
    id: KeyPath<Data.Element, some Hashable>,
    @ViewBuilder content: @escaping @MainActor (Data.Element) -> some View
  ) where Data.Index == Int {
    let captured = data
    let section = VirtualListSection(
      id: AnyHashable(DefaultSectionID.default),
      itemCount: captured.count,
      itemID: { AnyHashable(captured[captured.startIndex + $0][keyPath: id]) },
      itemView: { AnyView(content(captured[captured.startIndex + $0])) },
      header: nil,
      footer: nil
    )
    self.init(sections: [section], configuration: VirtualListConfiguration())
  }

  /// Collection-based constructor for `Identifiable` elements. Mirrors
  /// `List(_:content:)`.
  public init<Data: RandomAccessCollection>(
    _ data: Data,
    @ViewBuilder content: @escaping @MainActor (Data.Element) -> some View
  ) where Data.Element: Identifiable, Data.Index == Int {
    let captured = data
    let section = VirtualListSection(
      id: AnyHashable(DefaultSectionID.default),
      itemCount: captured.count,
      itemID: { AnyHashable(captured[captured.startIndex + $0].id) },
      itemView: { AnyView(content(captured[captured.startIndex + $0])) },
      header: nil,
      footer: nil
    )
    self.init(sections: [section], configuration: VirtualListConfiguration())
  }

  /// Result-builder constructor for multi-section lists. Used together with
  /// `VirtualSection` and `VirtualItems`.
  public init(@VirtualListBuilder content: () -> [VirtualListSection]) {
    self.init(sections: content(), configuration: VirtualListConfiguration())
  }
}

// MARK: - `VirtualListRow`-returning initializers
//
// Overloads that take a `rowContent` returning a concrete `VirtualListRow`.
// Swift's overload resolution picks these when the closure's return type
// conforms; otherwise callers fall through to the plain `some View`
// initializers above. Returning a `VirtualListRow` is how a caller opts
// into the per-row modifier dispatch.

extension VirtualList {
  public init<Data: RandomAccessCollection, Row: VirtualListRow>(
    _ data: Data,
    id: KeyPath<Data.Element, some Hashable>,
    rowContent: @escaping @MainActor (Data.Element) -> Row
  ) where Data.Index == Int {
    self.init(data, id: id, content: rowContent)
  }

  public init<Data: RandomAccessCollection, Row: VirtualListRow>(
    _ data: Data,
    rowContent: @escaping @MainActor (Data.Element) -> Row
  ) where Data.Element: Identifiable, Data.Index == Int {
    self.init(data, content: rowContent)
  }

  public init<Row: VirtualListRow>(
    itemCount: Int,
    id: @escaping @MainActor (Int) -> some Hashable,
    rowContent: @escaping @MainActor (Int) -> Row
  ) {
    self.init(itemCount: itemCount, id: id, content: rowContent)
  }
}

// MARK: - Selection-carrying initializers
//
// Mirror `SwiftUI.List(_:id:selection:rowContent:)` so a `List → VirtualList`
// migration doesn't have to split the selection binding into a separate
// `.virtualListSelection(_:)` modifier.

extension VirtualList {
  /// Collection-based with an explicit id key path and a single-selection
  /// binding. Mirrors `SwiftUI.List(_:id:selection:rowContent:)`.
  public init<Data: RandomAccessCollection, ID: Hashable>(
    _ data: Data,
    id: KeyPath<Data.Element, ID>,
    selection: Binding<ID?>,
    @ViewBuilder rowContent: @escaping @MainActor (Data.Element) -> some View
  ) where Data.Index == Int {
    self.init(data, id: id, content: rowContent)
    configuration.selectionBox = VirtualListSelectionBox(single: selection)
  }

  /// Collection-based with an explicit id key path and a multi-selection
  /// binding. Mirrors `SwiftUI.List(_:id:selection:rowContent:)`.
  public init<Data: RandomAccessCollection, ID: Hashable>(
    _ data: Data,
    id: KeyPath<Data.Element, ID>,
    selection: Binding<Set<ID>>,
    @ViewBuilder rowContent: @escaping @MainActor (Data.Element) -> some View
  ) where Data.Index == Int {
    self.init(data, id: id, content: rowContent)
    configuration.selectionBox = VirtualListSelectionBox(multiple: selection)
  }

  /// Collection-based with `Identifiable` elements and a single-selection
  /// binding. Mirrors `SwiftUI.List(_:selection:rowContent:)`.
  public init<Data: RandomAccessCollection>(
    _ data: Data,
    selection: Binding<Data.Element.ID?>,
    @ViewBuilder rowContent: @escaping @MainActor (Data.Element) -> some View
  ) where Data.Element: Identifiable, Data.Index == Int {
    self.init(data, content: rowContent)
    configuration.selectionBox = VirtualListSelectionBox(single: selection)
  }

  /// Collection-based with `Identifiable` elements and a multi-selection
  /// binding. Mirrors `SwiftUI.List(_:selection:rowContent:)`.
  public init<Data: RandomAccessCollection>(
    _ data: Data,
    selection: Binding<Set<Data.Element.ID>>,
    @ViewBuilder rowContent: @escaping @MainActor (Data.Element) -> some View
  ) where Data.Element: Identifiable, Data.Index == Int {
    self.init(data, content: rowContent)
    configuration.selectionBox = VirtualListSelectionBox(multiple: selection)
  }
}
