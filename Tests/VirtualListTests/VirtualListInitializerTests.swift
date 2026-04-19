import Foundation
import SwiftUI
import Testing

@testable import VirtualList

/// Verifies that each public initializer of `VirtualList` builds a coherent
/// snapshot of sections + items, and that list-level modifiers land on the
/// configuration object the coordinator reads.
///
/// Most cases are cross-platform; the UIKit-gated subset below covers the
/// iOS-only modifiers (`.virtualListSwipeActions`, `.virtualListRefreshable`,
/// `.scrollDismissesKeyboard`) that compile out of the macOS build via the
/// `@available(macOS, unavailable)` stubs.
@Suite("VirtualList initializers")
@MainActor
struct VirtualListInitializerTests {
  @Test func indexBasedInitCreatesSingleSection() {
    let list = VirtualList(
      itemCount: 7,
      id: { $0 },
      content: { Text("\($0)") }
    )
    #expect(list.sections.count == 1)
    #expect(list.sections[0].itemCount == 7)
    #expect(list.sections[0].itemID(3) == AnyHashable(3))
  }

  @Test func collectionWithKeyPathInitCapturesIDs() {
    struct Row { let id: String }
    let data = [Row(id: "a"), Row(id: "b"), Row(id: "c")]
    let list = VirtualList(data, id: \.id) { Text($0.id) }
    #expect(list.sections.count == 1)
    #expect(list.sections[0].itemCount == 3)
    #expect(list.sections[0].itemID(0) == AnyHashable("a"))
    #expect(list.sections[0].itemID(2) == AnyHashable("c"))
  }

  @Test func identifiableCollectionInit() {
    struct Row: Identifiable { let id: Int }
    let data = (0..<5).map { Row(id: $0) }
    let list = VirtualList(data) { Text("\($0.id)") }
    #expect(list.sections[0].itemCount == 5)
    #expect(list.sections[0].itemID(4) == AnyHashable(4))
  }

  @Test func resultBuilderInitProducesSections() {
    let list = VirtualList {
      VirtualSection(id: "A") {
        VirtualItems(count: 1, id: { $0 }, content: { _ in Text("x") })
      }
      VirtualSection(id: "B") {
        VirtualItems(count: 2, id: { $0 }, content: { _ in Text("x") })
      }
    }
    #expect(list.sections.count == 2)
    #expect(list.sections[0].id == AnyHashable("A"))
    #expect(list.sections[1].id == AnyHashable("B"))
  }

  @Test func virtualListStyleModifier() {
    let list = VirtualList(itemCount: 0, id: { $0 }, content: { _ in Text("x") })
      .virtualListStyle(.insetGrouped)
    #expect(list.configuration.style == .insetGrouped)
  }

  @Test func virtualListRowHeightModifier() {
    let list = VirtualList(itemCount: 0, id: { $0 }, content: { _ in Text("x") })
      .virtualListRowHeight(44)
    #expect(list.configuration.fixedRowHeight == 44)
  }

  @Test func virtualListReorderModifierStoresHandler() {
    let list = VirtualList(itemCount: 0, id: { $0 }, content: { _ in Text("x") })
      .virtualListReorder { _, _ in }
    #expect(list.configuration.onMove != nil)
  }

  @Test func virtualListColumnsModifier() {
    let list = VirtualList(itemCount: 0, id: { $0 }, content: { _ in Text("x") })
      .virtualListColumns(.init([.flexible(minimum: 100, maximum: 200)]))
    #expect(list.configuration.gridColumns != nil)
    #expect(list.configuration.gridColumns?.sizes.count == 1)
  }

  @Test func virtualListSingleSelectionBinding() {
    var selected: Int? = nil
    let binding = Binding<Int?>(get: { selected }, set: { selected = $0 })
    let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      .virtualListSelection(binding)
    #expect(list.configuration.selectionBox != nil)
    #expect(list.configuration.selectionBox?.allowsMultipleSelection == false)
  }

  @Test func virtualListMultiSelectionBinding() {
    var selected: Set<Int> = []
    let binding = Binding<Set<Int>>(get: { selected }, set: { selected = $0 })
    let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      .virtualListSelection(binding)
    #expect(list.configuration.selectionBox?.allowsMultipleSelection == true)
  }

  @Test func virtualListEnvironmentAppendsOverride() {
    let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      .virtualListEnvironment(\.lineSpacing, 8)
      .virtualListEnvironment(\.isEnabled, false)
    #expect(list.configuration.environmentOverrides.count == 2)
  }

  @Test func virtualListRowSeparatorsModifier() {
    let list = VirtualList(itemCount: 0, id: { $0 }, content: { _ in Text("x") })
      .virtualListRowSeparators(false)
    #expect(list.configuration.rowSeparators == false)
  }

  @Test func onDeleteAssignsConfiguration() {
    let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      .onDelete { _ in }
    #expect(list.configuration.onDelete != nil)
  }

  @Test func onDeleteAbsentByDefault() {
    let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
    #expect(list.configuration.onDelete == nil)
  }

  @Test func scrollContentBackgroundHidden() {
    let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      .scrollContentBackground(.hidden)
    #expect(list.configuration.scrollContentBackground == .hidden)
  }

  @Test func scrollContentBackgroundVisible() {
    let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      .scrollContentBackground(.visible)
    #expect(list.configuration.scrollContentBackground == .visible)
  }

  @Test func scrollContentBackgroundAbsentByDefault() {
    let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
    #expect(list.configuration.scrollContentBackground == nil)
  }

  // MARK: - iOS-only modifiers

  #if canImport(UIKit)
    @Test func virtualListRefreshableModifierStoresAction() {
      let list = VirtualList(itemCount: 0, id: { $0 }, content: { _ in Text("x") })
        .virtualListRefreshable {}
      #expect(list.configuration.refreshAction != nil)
    }

    @Test func virtualListSwipeActionsTrailing() {
      let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
        .virtualListSwipeActions(edge: .trailing) { _ in [] }
      #expect(list.configuration.swipeActionsTrailing != nil)
      #expect(list.configuration.swipeActionsLeading == nil)
    }

    @Test func virtualListSwipeActionsLeading() {
      let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
        .virtualListSwipeActions(edge: .leading) { _ in [] }
      #expect(list.configuration.swipeActionsLeading != nil)
      #expect(list.configuration.swipeActionsTrailing == nil)
    }

    @Test func scrollDismissesKeyboardImmediately() {
      let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
        .scrollDismissesKeyboard(.immediately)
      #expect(list.configuration.scrollDismissesKeyboard == .immediately)
    }

    @Test func scrollDismissesKeyboardNever() {
      let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
        .scrollDismissesKeyboard(.never)
      #expect(list.configuration.scrollDismissesKeyboard == .never)
    }

    @Test func scrollDismissesKeyboardAbsentByDefault() {
      let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      #expect(list.configuration.scrollDismissesKeyboard == nil)
    }
  #endif
}
