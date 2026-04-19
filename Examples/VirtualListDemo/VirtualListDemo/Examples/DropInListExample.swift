import SwiftUI
import VirtualList

/// Shows the `List`-compatible shape of `VirtualList`: swap `List` for `VirtualList`
/// and nothing else needs to change.
public struct DropInListExample: View {
  public struct User: Identifiable {
    public let id: Int
    public let name: String
    public let email: String
  }

  public let users: [User]

  public init(users: [User] = DropInListExample.sampleUsers) {
    self.users = users
  }

  public var body: some View {
    VirtualList(users) { user in
      HStack {
        Circle()
          .fill(.blue.gradient)
          .frame(width: 32, height: 32)
        VStack(alignment: .leading) {
          Text(user.name).font(.headline)
          Text(user.email).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .virtualListStyle(.insetGrouped)
    .ignoresSafeArea(edges: [.top, .bottom])
  }

  public static let sampleUsers: [User] = (0..<200).map { i in
    User(id: i, name: "User \(i)", email: "user\(i)@example.com")
  }
}

#Preview("Drop-in") {
  DropInListExample()
}
