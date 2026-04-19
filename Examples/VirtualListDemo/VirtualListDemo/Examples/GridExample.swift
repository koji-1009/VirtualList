import SwiftUI
import VirtualList

/// Adaptive grid layout, equivalent in spirit to `LazyVGrid(columns:)`.
public struct GridExample: View {
  public init() {}

  public var body: some View {
    VirtualList(itemCount: 200, id: { $0 }) { index in
      RoundedRectangle(cornerRadius: 12)
        .fill(
          LinearGradient(
            colors: [.blue.opacity(0.4), .purple.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .overlay(Text("\(index)").foregroundStyle(.white).bold())
        .aspectRatio(1, contentMode: .fit)
    }
    .virtualListColumns(
      .init([.adaptive(minimum: 90, maximum: 140)], spacing: 8, rowSpacing: 8)
    )
    .ignoresSafeArea(edges: [.top, .bottom])
  }
}

#Preview("Grid") {
  GridExample()
}
