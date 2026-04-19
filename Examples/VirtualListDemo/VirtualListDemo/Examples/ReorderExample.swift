import SwiftUI
import VirtualList

/// Long-press a row to drag; drop to reorder. The `onMove` closure owns the
/// source-of-truth mutation.
public struct ReorderExample: View {
  @State private var items: [String] = (0..<20).map { "Item \($0)" }

  public init() {}

  public var body: some View {
    VirtualList(items, id: \.self) { item in
      Label(item, systemImage: "line.3.horizontal")
    }
    .virtualListReorder { from, to in
      let moved = items.remove(at: from.item)
      items.insert(moved, at: to.item)
    }
    .ignoresSafeArea(edges: [.top, .bottom])
  }
}

#Preview("Reorder") {
  ReorderExample()
}
