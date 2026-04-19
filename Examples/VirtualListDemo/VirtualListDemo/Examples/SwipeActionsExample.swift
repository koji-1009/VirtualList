#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import VirtualList

  /// Leading and trailing swipe actions.
  public struct SwipeActionsExample: View {
    @State private var items: [String] = (0..<30).map { "Row \($0)" }

    public init() {}

    public var body: some View {
      VirtualList(items, id: \.self) { item in
        Text(item)
      }
      .virtualListSwipeActions(edge: .trailing) { indexPath in
        [
          VirtualListSwipeAction(
            title: "Delete",
            style: .destructive,
            image: UIImage(systemName: "trash")
          ) { _ in
            items.remove(at: indexPath.item)
          }
        ]
      }
      .virtualListSwipeActions(edge: .leading) { indexPath in
        [
          VirtualListSwipeAction(
            title: "Pin",
            backgroundColor: .systemOrange,
            image: UIImage(systemName: "pin.fill")
          ) { _ in
            let pinned = items.remove(at: indexPath.item)
            items.insert(pinned, at: 0)
          }
        ]
      }
      .ignoresSafeArea(edges: [.top, .bottom])
    }
  }

  #Preview("Swipe") {
    SwipeActionsExample()
  }
#endif
