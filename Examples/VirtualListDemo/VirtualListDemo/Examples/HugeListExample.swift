import SwiftUI
import VirtualList

/// One million synthetic rows, demonstrating the index-based builder.
public struct HugeListExample: View {
  public init() {}

  public var body: some View {
    VirtualList(itemCount: 1_000_000, id: { $0 }) { index in
      HStack {
        Text("#\(index)")
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(.secondary)
        Text(Self.title(for: index))
        Spacer()
      }
    }
    .virtualListStyle(.plain)
    .virtualListUpdatePolicy(.indexed)
    .ignoresSafeArea(edges: [.top, .bottom])
  }

  private static func title(for index: Int) -> String {
    let suffix = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"][index % 6]
    return "Row \(index) – \(suffix)"
  }
}

#Preview("Huge list") {
  HugeListExample()
}
