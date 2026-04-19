import SwiftUI
import Testing

@testable import VirtualList

/// Proof-of-concept that an `SwiftUI.List` call site can swap in `VirtualList`
/// without changing surrounding modifier or initializer syntax. Each test
/// mirrors a common `List` shape and asserts the resulting `VirtualList`
/// captures the same intent on its internal configuration.
///
/// Per-row modifiers that `SwiftUI.List` intercepts via private preference
/// keys (`.swipeActions`, `.listRowBackground`, `.listRowInsets`) are not
/// covered here — those continue to require the explicit
/// `.virtualListSwipeActions(edge:actions:)` call.
@Suite("List API compat (drop-in)")
@MainActor
struct ListAPICompatTests {
  struct Row: Identifiable { let id: Int; let title: String }

  @Test func listStyleAlias() {
    let vl = VirtualList([Row(id: 1, title: "a")]) { Text($0.title) }
      .listStyle(.insetGrouped)
    #expect(vl.configuration.style == .insetGrouped)
  }

  @Test func listRowSeparatorVisible() {
    let vl = VirtualList([Row(id: 1, title: "a")]) { Text($0.title) }
      .listRowSeparator(.visible)
    #expect(vl.configuration.rowSeparators == true)
  }

  @Test func listRowSeparatorHidden() {
    let vl = VirtualList([Row(id: 1, title: "a")]) { Text($0.title) }
      .listRowSeparator(.hidden)
    #expect(vl.configuration.rowSeparators == false)
  }

  @Test func listRowSeparatorAutomatic() {
    let vl = VirtualList([Row(id: 1, title: "a")]) { Text($0.title) }
      .listRowSeparator(.automatic)
    #expect(vl.configuration.rowSeparators == nil)
  }

  #if canImport(UIKit)
    @Test func refreshableAlias() async {
      var fired = false
      let vl = VirtualList([Row(id: 1, title: "a")]) { Text($0.title) }
        .refreshable { fired = true }
      await vl.configuration.refreshAction?()
      #expect(fired == true)
    }
  #endif

  @Test func onMoveMapsIndexSetToCallback() {
    var captured: (IndexSet, Int)?
    let vl = VirtualList([Row(id: 1, title: "a"), Row(id: 2, title: "b")]) {
      Text($0.title)
    }
    .onMove { set, destination in captured = (set, destination) }

    vl.configuration.onMove?(
      IndexPath(item: 0, section: 0),
      IndexPath(item: 1, section: 0)
    )
    #expect(captured?.0 == IndexSet(integer: 0))
    #expect(captured?.1 == 1)
  }

  @Test func initializerWithSingleSelection() {
    var selected: Int? = nil
    let binding = Binding<Int?>(get: { selected }, set: { selected = $0 })
    let rows = [Row(id: 1, title: "a"), Row(id: 2, title: "b")]
    let vl = VirtualList(rows, selection: binding) { Text($0.title) }
    #expect(vl.configuration.selectionBox != nil)
    #expect(vl.configuration.selectionBox?.allowsSelection == true)
    #expect(vl.configuration.selectionBox?.allowsMultipleSelection == false)
  }

  @Test func initializerWithMultiSelection() {
    var selected: Set<Int> = []
    let binding = Binding<Set<Int>>(get: { selected }, set: { selected = $0 })
    let rows = [Row(id: 1, title: "a"), Row(id: 2, title: "b")]
    let vl = VirtualList(rows, selection: binding) { Text($0.title) }
    #expect(vl.configuration.selectionBox?.allowsMultipleSelection == true)
  }

  @Test func initializerWithIDKeyPathAndSelection() {
    struct Plain { let idValue: String }
    var selected: String? = nil
    let binding = Binding<String?>(get: { selected }, set: { selected = $0 })
    let rows = [Plain(idValue: "a"), Plain(idValue: "b")]
    let vl = VirtualList(rows, id: \.idValue, selection: binding) {
      Text($0.idValue)
    }
    #expect(vl.configuration.selectionBox?.allowsSelection == true)
    #expect(vl.configuration.selectionBox?.allowsMultipleSelection == false)
  }

  /// Compile-time check: a realistic `SwiftUI.List` call site builds and
  /// runs verbatim with `VirtualList` swapped in.
  @Test func dropInCompilesAndRuns() {
    var selected: Int? = nil
    let binding = Binding<Int?>(get: { selected }, set: { selected = $0 })
    let rows = [Row(id: 1, title: "a"), Row(id: 2, title: "b")]

    let vl = VirtualList(rows, selection: binding) { row in
      Text(row.title)
    }
    .listStyle(.plain)
    .listRowSeparator(.hidden)
    .onMove { _, _ in }

    #expect(vl.configuration.style == .plain)
    #expect(vl.configuration.rowSeparators == false)
    #expect(vl.configuration.selectionBox != nil)
    #expect(vl.configuration.onMove != nil)
  }
}
