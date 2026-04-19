import Foundation
import Testing

@testable import VirtualList

@Suite("VirtualListFocusCoordinator")
@MainActor
struct FocusCoordinatorTests {
  @Test func initialValueIsRespected() {
    let coord = VirtualListFocusCoordinator<String>(initial: "row-1")
    #expect(coord.currentID == "row-1")
  }

  @Test func focusUpdatesCurrentID() {
    let coord = VirtualListFocusCoordinator<Int>()
    #expect(coord.currentID == nil)
    coord.focus(id: 42)
    #expect(coord.currentID == 42)
  }

  @Test func clearSetsCurrentIDToNil() {
    let coord = VirtualListFocusCoordinator<Int>(initial: 3)
    coord.clear()
    #expect(coord.currentID == nil)
  }

  @Test func focusWithNilAlsoClears() {
    let coord = VirtualListFocusCoordinator<String>(initial: "a")
    coord.focus(id: nil)
    #expect(coord.currentID == nil)
  }
}
