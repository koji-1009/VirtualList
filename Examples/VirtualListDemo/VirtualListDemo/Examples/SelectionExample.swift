import SwiftUI
import VirtualList

/// Single- and multi-selection bindings.
public struct SelectionExample: View {
  @State private var singleSelection: Int? = nil
  @State private var multiSelection: Set<Int> = []
  @State private var multiMode = false

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      Toggle("Multi-select", isOn: $multiMode)
        .padding()
      Divider()
      list
    }
    .ignoresSafeArea(edges: .bottom)
  }

  @ViewBuilder
  private var list: some View {
    if multiMode {
      VirtualList(itemCount: 50, id: { $0 }) { index in
        row(index: index, isSelected: multiSelection.contains(index))
      }
      .virtualListSelection($multiSelection)
    } else {
      VirtualList(itemCount: 50, id: { $0 }) { index in
        row(index: index, isSelected: singleSelection == index)
      }
      .virtualListSelection($singleSelection)
    }
  }

  private func row(index: Int, isSelected: Bool) -> some View {
    HStack {
      Text("Row \(index)")
      Spacer()
      if isSelected {
        Image(systemName: "checkmark")
          .foregroundStyle(Color.accentColor)
      }
    }
  }
}

#Preview("Selection") {
  SelectionExample()
}
