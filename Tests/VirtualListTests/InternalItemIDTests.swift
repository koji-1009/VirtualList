import Foundation
import Testing

@testable import VirtualList

@Suite("InternalItemID")
struct InternalItemIDTests {
  @Test func equalWhenBothComponentsMatch() {
    let a = InternalItemID(sectionID: AnyHashable("s"), itemID: AnyHashable(1))
    let b = InternalItemID(sectionID: AnyHashable("s"), itemID: AnyHashable(1))
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
  }

  @Test func differentSectionProducesDifferentID() {
    let a = InternalItemID(sectionID: AnyHashable("s1"), itemID: AnyHashable(1))
    let b = InternalItemID(sectionID: AnyHashable("s2"), itemID: AnyHashable(1))
    #expect(a != b)
  }

  @Test func differentItemProducesDifferentID() {
    let a = InternalItemID(sectionID: AnyHashable("s"), itemID: AnyHashable(1))
    let b = InternalItemID(sectionID: AnyHashable("s"), itemID: AnyHashable(2))
    #expect(a != b)
  }

  /// This test encodes the invariant the diffable data source relies on: identical
  /// item IDs in different sections must produce distinct identifiers so the
  /// snapshot doesn't reject the second appearance as a duplicate.
  @Test func sameItemIDAcrossSectionsStaysDistinct() {
    let ids = Set([
      InternalItemID(sectionID: AnyHashable("a"), itemID: AnyHashable(1)),
      InternalItemID(sectionID: AnyHashable("b"), itemID: AnyHashable(1)),
    ])
    #expect(ids.count == 2)
  }
}
