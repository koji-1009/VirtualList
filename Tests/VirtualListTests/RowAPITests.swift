import SwiftUI
import Testing

@testable import VirtualList

#if canImport(UIKit)
  import UIKit
#endif

/// Compile-level guard on `VirtualListRow` modifier dispatch. Each test
/// compiles only because Swift's method lookup picks the `VirtualListRow`
/// extension over `SwiftUI.View`'s equivalent; a regression that drops
/// the protocol extension would silently fall through to SwiftUI's
/// (which is a no-op inside `VirtualList`).
@Suite("VirtualListRow protocol")
@MainActor
struct VirtualListRowProtocolTests {
  @Test func containerAdoptsProtocol() {
    let container = VirtualListRowContainer { Text("x") }
    // Compile-time assertion: `container` is usable where
    // `some VirtualListRow` is required.
    acceptRow(container)
  }

  @Test func userRowTypeCanAdoptProtocol() {
    struct MyRow: VirtualListRow {
      let item: String
      var body: some View { Text(item) }
    }
    let row = MyRow(item: "a")
    acceptRow(row)
  }

  private func acceptRow(_ row: some VirtualListRow) {
    _ = row.body
  }

  #if canImport(UIKit)
    @Test func listRowBackgroundExtensionIsCallableOnRow() {
      let wrapped = VirtualListRowContainer { Text("x") }
        .listRowBackground(Color.blue)
      _ = wrapped
    }

    @Test func listRowBackgroundAcceptsNilToClear() {
      let wrapped = VirtualListRowContainer { Text("x") }
        .listRowBackground(nil as Color?)
      _ = wrapped
    }

    @Test func listRowInsetsExtensionIsCallableOnRow() {
      let wrapped = VirtualListRowContainer { Text("x") }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
      _ = wrapped
    }

    @Test func listRowInsetsAcceptsNil() {
      let wrapped = VirtualListRowContainer { Text("x") }
        .listRowInsets(nil)
      _ = wrapped
    }

    @Test func listRowBackgroundAcceptsGradient() {
      // Any SwiftUI view — not just `Color` — can back a row.
      let gradient = LinearGradient(
        colors: [.blue, .purple],
        startPoint: .top,
        endPoint: .bottom
      )
      let wrapped = VirtualListRowContainer { Text("x") }
        .listRowBackground(gradient)
      _ = wrapped
    }

    @Test func swipeActionsExtensionIsCallableOnRow() {
      let wrapped = VirtualListRowContainer { Text("x") }
        .swipeActions {
          VirtualListSwipeAction(title: "Delete", style: .destructive) { _ in }
        }
      _ = wrapped
    }

    @Test func listRowSeparatorExtensionIsCallableOnRow() {
      let wrapped = VirtualListRowContainer { Text("x") }
        .listRowSeparator(.hidden)
      _ = wrapped
    }

    @Test func listRowSeparatorAcceptsEdges() {
      let wrapped = VirtualListRowContainer { Text("x") }
        .listRowSeparator(.hidden, edges: .bottom)
      _ = wrapped
    }

    @Test func badgeExtensionAcceptsInt() {
      let wrapped = VirtualListRowContainer { Text("x") }.badge(5)
      _ = wrapped
    }

    @Test func badgeExtensionAcceptsText() {
      let wrapped = VirtualListRowContainer { Text("x") }.badge(Text("new"))
      _ = wrapped
    }

    @Test func badgeExtensionAcceptsLocalizedStringKey() {
      let wrapped = VirtualListRowContainer { Text("x") }
        .badge("key" as LocalizedStringKey?)
      _ = wrapped
    }

    @Test func badgeExtensionAcceptsStringProtocol() {
      let wrapped = VirtualListRowContainer { Text("x") }.badge("new")
      _ = wrapped
    }

    @Test func badgeExtensionAcceptsNilToClear() {
      let wrapped = VirtualListRowContainer { Text("x") }.badge(nil as Text?)
      _ = wrapped
    }
  #endif
}

#if canImport(UIKit)
  /// Verifies the per-row swipe box wiring end-to-end: a configured cell
  /// writes its actions into the box via the `.swipeActions` modifier,
  /// and the coordinator's swipe-actions helper reads them back under the
  /// cell's IndexPath.
  @Suite("Per-row swipe actions (iOS)")
  @MainActor
  struct PerRowSwipeActionsTests {
    @Test func coordinatorReturnsNoConfigWhenNoPerRowActionsRecorded() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView()
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let cfg = coord.swipeActionsConfiguration(
        for: IndexPath(item: 0, section: 0),
        edge: .trailing
      )
      #expect(cfg == nil)
    }

    @Test func coordinatorSwipeConfigurationReflectsBoxContents() {
      // Drive the per-row box directly (the usual path is via the
      // `.swipeActions` modifier inside a hosted SwiftUI view, but
      // exercising the coordinator side alone keeps the test off the
      // SwiftUI-layout critical path). Because box allocation is
      // lazy — created only when a row modifier actually fires — the
      // test has to call `ensureRowBox` explicitly to simulate that.
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      #expect(coord.debug_perRowBox(for: indexPath) == nil)

      let box = coord.ensureRowBox(at: indexPath)
      box.trailingSwipeActions = [
        VirtualListSwipeAction(title: "Delete", style: .destructive) { _ in }
      ]

      let cfg = coord.swipeActionsConfiguration(
        for: indexPath,
        edge: .trailing
      )
      #expect(cfg != nil)
      #expect(cfg?.actions.count == 1)
      #expect(cfg?.actions.first?.title == "Delete")
      #expect(cfg?.actions.first?.style == .destructive)
    }

    @Test func applyRowInsetsCachesValuePerIndexPath() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      // Box allocation is lazy — nothing was allocated yet.
      #expect(coord.debug_perRowBox(for: indexPath) == nil)

      // Simulating the modifier's `.onAppear` forces the provider to
      // allocate a box for this IndexPath. After that, committing an
      // inset fires the coordinator callback the same way the real
      // modifier would.
      let box = coord.ensureRowBox(at: indexPath)
      #expect(box.insets.value == nil)

      let insets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      box.insets.commit(insets)
      #expect(coord.debug_perRowInsets(at: indexPath) == insets)
    }

    @Test func applyRowInsetsClearsOnNil() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      let insets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      box.insets.commit(insets)
      #expect(coord.debug_perRowInsets(at: indexPath) == insets)

      // Explicit nil clears the cached value.
      box.insets.commit(nil)
      #expect(coord.debug_perRowInsets(at: indexPath) == nil)
    }

    @Test func structuralApplyClearsPerRowBoxes() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.trailingSwipeActions = [
        VirtualListSwipeAction(title: "Keep", style: .normal) { _ in }
      ]

      // A structural change invalidates the dict — stale IndexPaths
      // shouldn't survive an insert / reorder.
      coord.apply(sections: [syntheticSection(count: 5)], animated: false)
      #expect(coord.debug_perRowBox(for: indexPath) == nil)
    }

    @Test func applyRowSeparatorVisibilityCachesValuePerIndexPath() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      #expect(coord.debug_perRowSeparatorVisibility(at: indexPath) == nil)

      let box = coord.ensureRowBox(at: indexPath)
      #expect(box.separator.value == nil)

      let override = VirtualListRowSeparatorVisibility(top: .hidden, bottom: .hidden)
      box.separator.commit(override)
      #expect(coord.debug_perRowSeparatorVisibility(at: indexPath) == override)
    }

    @Test func applyRowSeparatorVisibilityClearsOnNil() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      let override = VirtualListRowSeparatorVisibility(top: .hidden, bottom: .hidden)
      box.separator.commit(override)
      #expect(coord.debug_perRowSeparatorVisibility(at: indexPath) == override)

      // Explicit nil clears the cached override.
      box.separator.commit(nil)
      #expect(coord.debug_perRowSeparatorVisibility(at: indexPath) == nil)
    }

    @Test func rowSeparatorVisibilityReturnsCachedValue() {
      // The internal `rowSeparatorVisibility(at:)` accessor is the
      // input the layout's `itemSeparatorHandler` reads. Verify it
      // mirrors the cached state so the handler path can trust it.
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 1, section: 0)
      #expect(coord.rowSeparatorVisibility(at: indexPath) == nil)

      let box = coord.ensureRowBox(at: indexPath)
      let override = VirtualListRowSeparatorVisibility(top: .automatic, bottom: .hidden)
      box.separator.commit(override)
      #expect(coord.rowSeparatorVisibility(at: indexPath) == override)
    }

    @Test func applyRowBadgeAllocatesHostOnFirstCommit() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      #expect(coord.debug_perRowBadgeHost(at: indexPath) == nil)

      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))
      #expect(coord.debug_perRowBadgeHost(at: indexPath) != nil)
    }

    @Test func applyRowBadgeClearsHostOnNil() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))
      #expect(coord.debug_perRowBadgeHost(at: indexPath) != nil)

      box.badge.commit(nil)
      #expect(coord.debug_perRowBadgeHost(at: indexPath) == nil)
    }

    @Test func applyRowBadgeReusesExistingHostOnUpdate() {
      // A second commit with new content should update the existing
      // host rather than allocating a new one — otherwise scroll-paced
      // updates through an animating counter would thrash hosting
      // controllers.
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))
      let first = coord.debug_perRowBadgeHost(at: indexPath)
      #expect(first != nil)

      box.badge.commit(AnyView(Text("9")))
      let second = coord.debug_perRowBadgeHost(at: indexPath)
      #expect(second === first)
    }

    @Test func structuralApplyClearsPerRowBadgeHosts() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))
      #expect(coord.debug_perRowBadgeHost(at: indexPath) != nil)

      coord.apply(sections: [syntheticSection(count: 5)], animated: false)
      #expect(coord.debug_perRowBadgeHost(at: indexPath) == nil)
    }
  }

  /// Verifies `.onDelete(perform:)` materialises a default destructive
  /// trailing-swipe action that calls the handler with the affected
  /// row's `IndexSet`.
  @Suite("onDelete default swipe action (iOS)")
  @MainActor
  struct OnDeleteDefaultSwipeTests {
    @Test func returnsNilWhenOnDeleteIsNotSet() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView()
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let cfg = coord.defaultDeleteSwipeConfiguration(
        for: IndexPath(item: 0, section: 0)
      )
      #expect(cfg == nil)
    }

    @Test func returnsDestructiveDeleteActionWhenOnDeleteIsSet() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView()
      coord.install(on: cv)
      var config = VirtualListConfiguration()
      config.onDelete = { _ in }
      coord.configuration = config
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let cfg = coord.defaultDeleteSwipeConfiguration(
        for: IndexPath(item: 1, section: 0)
      )
      #expect(cfg != nil)
      #expect(cfg?.actions.count == 1)
      #expect(cfg?.actions.first?.style == .destructive)
      // UIKit's localised "Delete" string ("Delete" in English,
      // translated in other locales) — just assert non-empty so the
      // test doesn't lock to a specific locale.
      #expect(cfg?.actions.first?.title?.isEmpty == false)
    }

    @Test func invokingActionFiresHandlerWithExpectedIndexSet() throws {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView()
      coord.install(on: cv)
      var received: IndexSet?
      var config = VirtualListConfiguration()
      config.onDelete = { indexSet in received = indexSet }
      coord.configuration = config
      coord.apply(sections: [syntheticSection(count: 5)], animated: false)

      let indexPath = IndexPath(item: 2, section: 0)
      let cfg = coord.defaultDeleteSwipeConfiguration(for: indexPath)
      let action = try #require(cfg?.actions.first)
      action.handler(action, UIView()) { _ in }

      #expect(received == IndexSet(integer: 2))
    }
  }

  /// Verifies that the `\.editMode` environment binding forwards
  /// through `VirtualList.applyEditMode(to:from:)` onto the
  /// collection view's `isEditing` flag — the hook SwiftUI-style
  /// edit-mode toggling relies on.
  @Suite("editMode environment wiring (iOS)")
  @MainActor
  struct EditModeEnvironmentTests {
    @Test func activeEnvironmentTurnsOnCollectionViewEditing() {
      let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      let cv = makePlatformCollectionView()
      #expect(cv.isEditing == false)

      var env = EnvironmentValues()
      env.editMode = .constant(.active)
      list.applyEditMode(to: cv, from: env)

      #expect(cv.isEditing == true)
    }

    @Test func inactiveEnvironmentTurnsOffCollectionViewEditing() {
      let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      let cv = makePlatformCollectionView()
      cv.isEditing = true

      var env = EnvironmentValues()
      env.editMode = .constant(.inactive)
      list.applyEditMode(to: cv, from: env)

      #expect(cv.isEditing == false)
    }

    @Test func missingEnvironmentBindingLeavesEditingOff() {
      // With no `.environment(\.editMode, ...)` applied, the
      // environment value is `nil` and the helper should default to
      // "not editing".
      let list = VirtualList(itemCount: 3, id: { $0 }, content: { _ in Text("x") })
      let cv = makePlatformCollectionView()

      let env = EnvironmentValues()
      list.applyEditMode(to: cv, from: env)

      #expect(cv.isEditing == false)
    }
  }
#endif
