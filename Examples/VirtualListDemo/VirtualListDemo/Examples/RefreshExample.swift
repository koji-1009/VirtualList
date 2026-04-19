#if canImport(UIKit)
  import SwiftUI
  import VirtualList

  /// Pull-to-refresh. The async action runs on the main actor; the indicator is
  /// dismissed when it returns.
  public struct RefreshExample: View {
    @State private var rows: Int = 20

    public init() {}

    public var body: some View {
      VirtualList(itemCount: rows, id: { $0 }) { index in
        Text("Row \(index)")
      }
      .virtualListRefreshable {
        try? await Task.sleep(for: .seconds(1))
        await MainActor.run { rows += 10 }
      }
      .ignoresSafeArea(edges: [.top, .bottom])
    }
  }

  #Preview("Refresh") {
    RefreshExample()
  }
#endif
