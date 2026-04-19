import SwiftUI
import VirtualList

/// Keyboard focus coordinated across reused cells.
///
/// `@FocusState` alone loses its binding when a hosted cell is recycled, so focus
/// flows through a `VirtualListFocusCoordinator<Int>`. Each cell's modifier
/// observes the coordinator and pushes its local `@FocusState` in sync.
public struct FocusExample: View {
  @StateObject private var focus = VirtualListFocusCoordinator<Int>()
  @State private var texts: [Int: String] = [:]

  public init() {}

  public var body: some View {
    VirtualList(itemCount: 200, id: { $0 }) { index in
      HStack {
        Text("\(index)")
          .frame(width: 32, alignment: .leading)
          .foregroundStyle(.secondary)
        TextField("Row \(index)", text: binding(for: index))
          .virtualListFocused(focus, id: index)
          .textFieldStyle(.roundedBorder)
      }
    }
    .virtualListFocusCoordinator(focus)
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Button("Focus 0") { focus.focus(id: 0) }
        Button("Focus 100") { focus.focus(id: 100) }
        Button("Clear") { focus.clear() }
      }
    }
    .ignoresSafeArea(edges: [.top, .bottom])
  }

  private func binding(for id: Int) -> Binding<String> {
    Binding(
      get: { texts[id] ?? "" },
      set: { texts[id] = $0 }
    )
  }
}

#Preview("Focus") {
  FocusExample()
}
