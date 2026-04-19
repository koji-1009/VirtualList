import Foundation
import SwiftUI
import Testing

@testable import VirtualList

@Suite("VirtualListBuilder")
@MainActor
struct VirtualListBuilderTests {
  @Test func singleVirtualSectionProducesOneSection() {
    @VirtualListBuilder
    func body() -> [VirtualListSection] {
      VirtualSection(id: "A") {
        VirtualItems(count: 3, id: { $0 }, content: { _ in Text("x") })
      }
    }
    let sections = body()
    #expect(sections.count == 1)
    #expect(sections[0].id == AnyHashable("A"))
    #expect(sections[0].itemCount == 3)
    #expect(sections[0].header == nil)
    #expect(sections[0].footer == nil)
  }

  @Test func multipleVirtualSectionsProduceSequence() {
    @VirtualListBuilder
    func body() -> [VirtualListSection] {
      VirtualSection(id: "A") {
        VirtualItems(count: 1, id: { $0 }, content: { _ in Text("x") })
      }
      VirtualSection(id: "B") {
        VirtualItems(count: 2, id: { $0 }, content: { _ in Text("x") })
      }
    }
    let sections = body()
    #expect(sections.count == 2)
    #expect(sections[0].id == AnyHashable("A"))
    #expect(sections[1].id == AnyHashable("B"))
    #expect(sections[0].itemCount == 1)
    #expect(sections[1].itemCount == 2)
  }

  @Test func bareVirtualItemsWrappedInAnonymousSection() {
    @VirtualListBuilder
    func body() -> [VirtualListSection] {
      VirtualItems(count: 4, id: { $0 }, content: { _ in Text("x") })
    }
    let sections = body()
    #expect(sections.count == 1)
    #expect(sections[0].itemCount == 4)
  }

  @Test func sectionWithHeaderCapturesIt() {
    @VirtualListBuilder
    func body() -> [VirtualListSection] {
      VirtualSection(id: "H", header: { Text("Header") }) {
        VirtualItems(count: 1, id: { $0 }, content: { _ in Text("x") })
      }
    }
    let sections = body()
    #expect(sections.count == 1)
    #expect(sections[0].header != nil)
  }

  @Test func sectionFlattensMultipleVirtualItemsGroups() {
    @VirtualListBuilder
    func body() -> [VirtualListSection] {
      VirtualSection(id: "S") {
        VirtualItems(count: 2, id: { "pinned-\($0)" }, content: { _ in Text("p") })
        VirtualItems(count: 3, id: { "rest-\($0)" }, content: { _ in Text("r") })
      }
    }
    let sections = body()
    #expect(sections.count == 1)
    let s = sections[0]
    #expect(s.itemCount == 5)
    // Group boundaries respected: first 2 rows come from the pinned group,
    // next 3 from the rest group, and each group keeps its own id scheme.
    #expect(s.itemID(0) == AnyHashable("pinned-0"))
    #expect(s.itemID(1) == AnyHashable("pinned-1"))
    #expect(s.itemID(2) == AnyHashable("rest-0"))
    #expect(s.itemID(3) == AnyHashable("rest-1"))
    #expect(s.itemID(4) == AnyHashable("rest-2"))
  }

  @Test func sectionHandlesEmptyLeadingOrTrailingGroup() {
    @VirtualListBuilder
    func body() -> [VirtualListSection] {
      VirtualSection(id: "S") {
        VirtualItems(count: 0, id: { $0 }, content: { _ in Text("empty") })
        VirtualItems(count: 3, id: { "mid-\($0)" }, content: { _ in Text("m") })
        VirtualItems(count: 0, id: { $0 }, content: { _ in Text("tail") })
      }
    }
    let sections = body()
    #expect(sections[0].itemCount == 3)
    #expect(sections[0].itemID(0) == AnyHashable("mid-0"))
    #expect(sections[0].itemID(2) == AnyHashable("mid-2"))
  }
}
