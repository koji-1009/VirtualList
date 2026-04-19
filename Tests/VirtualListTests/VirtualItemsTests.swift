import Foundation
import SwiftUI
import Testing

@testable import VirtualList

@Suite("VirtualItems")
@MainActor
struct VirtualItemsTests {
  @Test func indexBasedInitStoresCountAndID() {
    let items = VirtualItems(
      count: 5,
      id: { "item-\($0)" },
      content: { _ in Text("x") }
    )
    #expect(items.itemCount == 5)
    #expect(items.itemID(0) == AnyHashable("item-0"))
    #expect(items.itemID(4) == AnyHashable("item-4"))
  }

  @Test func collectionInitWithKeyPath() {
    struct Row { let id: String }
    let data = [Row(id: "a"), Row(id: "b"), Row(id: "c")]
    let items = VirtualItems(data, id: \.id) { _ in Text("x") }
    #expect(items.itemCount == 3)
    #expect(items.itemID(0) == AnyHashable("a"))
    #expect(items.itemID(2) == AnyHashable("c"))
  }

  @Test func collectionInitWithIdentifiable() {
    struct Row: Identifiable { let id: Int }
    let data = (0..<10).map { Row(id: $0) }
    let items = VirtualItems(data) { _ in Text("x") }
    #expect(items.itemCount == 10)
    #expect(items.itemID(0) == AnyHashable(0))
    #expect(items.itemID(9) == AnyHashable(9))
  }

  @Test func buildAsSectionCarriesHeaderAndFooter() {
    let items = VirtualItems(count: 2, id: { $0 }, content: { _ in Text("x") })
    let section = items.buildAsSection(
      id: AnyHashable("group"),
      header: { AnyView(Text("H")) },
      footer: { AnyView(Text("F")) }
    )
    #expect(section.id == AnyHashable("group"))
    #expect(section.itemCount == 2)
    #expect(section.header != nil)
    #expect(section.footer != nil)
  }
}
