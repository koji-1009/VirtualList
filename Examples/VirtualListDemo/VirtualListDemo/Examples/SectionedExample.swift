import SwiftUI
import VirtualList

/// Multi-section layout with headers and footers via the result-builder API.
public struct SectionedExample: View {
  public init() {}

  public var body: some View {
    VirtualList {
      VirtualSection(
        id: "favourites",
        header: { Label("Favourites", systemImage: "star.fill") },
        footer: { Text("Pin the ones you reach for most.") }
      ) {
        VirtualItems(count: 5, id: { "fav-\($0)" }) { i in
          Text("Favourite \(i)")
        }
      }
      VirtualSection(
        id: "everything",
        header: { Label("Everything else", systemImage: "tray.full") }
      ) {
        VirtualItems(count: 50, id: { "all-\($0)" }) { i in
          Text("Item \(i)")
        }
      }
    }
    .virtualListStyle(.insetGrouped)
    .ignoresSafeArea(edges: [.top, .bottom])
  }
}

#Preview("Sections") {
  SectionedExample()
}
