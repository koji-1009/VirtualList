import Foundation
import SwiftUI
import Testing

@testable import VirtualList

/// Covers the `VirtualListSection` value type: how initializers build it, how IDs are
/// produced, and how callers can verify laziness.
///
/// These tests run on every supported platform (including plain macOS) because
/// `VirtualListSection` deliberately doesn't depend on UIKit.
@Suite("VirtualListSection")
@MainActor
struct VirtualListSectionTests {
  @Test func itemIDReportsExpectedValueForIndex() {
    let section = VirtualListSection(
      id: "s",
      itemCount: 3,
      itemID: { $0 * 10 },
      itemView: { _ in Text("x") }
    )
    #expect(section.itemID(0) == AnyHashable(0))
    #expect(section.itemID(1) == AnyHashable(10))
    #expect(section.itemID(2) == AnyHashable(20))
  }

  @Test func itemCountIsPropagated() {
    let section = VirtualListSection(
      id: "s",
      itemCount: 1_000_000,
      itemID: { $0 },
      itemView: { _ in Text("x") }
    )
    #expect(section.itemCount == 1_000_000)
  }

  @Test func itemViewBuilderIsLazy() {
    var callCount = 0
    let section = VirtualListSection(
      id: "s",
      itemCount: 1_000_000,
      itemID: { $0 },
      itemView: { idx -> Text in
        callCount += 1
        return Text("\(idx)")
      }
    )
    // Constructing the section and asking for IDs must not invoke the view builder.
    _ = section.itemID(42)
    _ = section.itemID(12345)
    #expect(callCount == 0)
  }

  @Test func itemViewBuildsWhenRequested() {
    var callCount = 0
    let section = VirtualListSection(
      id: "s",
      itemCount: 10,
      itemID: { $0 },
      itemView: { idx -> Text in
        callCount += 1
        return Text("\(idx)")
      }
    )
    _ = section.itemView(0)
    _ = section.itemView(1)
    #expect(callCount == 2)
  }
}
