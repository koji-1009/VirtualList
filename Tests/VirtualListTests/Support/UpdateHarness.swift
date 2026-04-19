import SwiftUI

@testable import VirtualList

/// Shared harness types for tests / benchmarks that drive the same view tree
/// through successive structural updates. Flipping `count` by ±1 each tick is
/// the cheapest structural change that still exercises the full
/// `apply → insertItems/insertRows → reconfigure` pipeline.
@MainActor
final class UpdateHarnessStore: ObservableObject {
  @Published var count: Int
  init(count: Int) { self.count = count }
}

struct UpdateHarnessListView: View {
  @ObservedObject var store: UpdateHarnessStore
  var body: some View {
    List(0..<store.count, id: \.self) { index in
      Text("Row \(index)")
    }
  }
}

struct UpdateHarnessVirtualListView: View {
  @ObservedObject var store: UpdateHarnessStore
  var body: some View {
    VirtualList(itemCount: store.count, id: { $0 }) { index in
      Text("Row \(index)")
    }
    .virtualListUpdatePolicy(.indexed)
  }
}
