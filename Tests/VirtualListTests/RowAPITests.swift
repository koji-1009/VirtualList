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

  // The two modifiers below are cross-platform drop-ins kept outside
  // the UIKit gate so native-macOS builds also cover the dispatch
  // path. They forward to SwiftUI's `.tint` / `.contextMenu` via an
  // explicit `View` wrapper — these compile-level assertions guard
  // against a regression where a `VirtualListRow` extension shadows
  // SwiftUI's version and the forward loops back into itself.
  @Test func listItemTintExtensionIsCallableOnRow() {
    let wrapped = VirtualListRowContainer { Text("x") }.listItemTint(.red)
    _ = wrapped
  }

  @Test func listItemTintAcceptsNilToClear() {
    let wrapped = VirtualListRowContainer { Text("x") }.listItemTint(nil)
    _ = wrapped
  }

  @Test func contextMenuExtensionIsCallableOnRow() {
    let wrapped = VirtualListRowContainer { Text("x") }
      .contextMenu {
        Button("Delete", role: .destructive) {}
        Button("Rename") {}
      }
    _ = wrapped
  }
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
      #expect(coord.perRowBoxes[indexPath] == nil)

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
      #expect(coord.perRowBoxes[indexPath] == nil)

      // Simulating the modifier's `.onAppear` forces the provider to
      // allocate a box for this IndexPath. After that, committing an
      // inset fires the coordinator callback the same way the real
      // modifier would.
      let box = coord.ensureRowBox(at: indexPath)
      #expect(box.insets.value == nil)

      let insets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      box.insets.commit(insets)
      #expect(coord.perRowInsets[indexPath] == insets)
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
      #expect(coord.perRowInsets[indexPath] == insets)

      // Explicit nil clears the cached value.
      box.insets.commit(nil)
      #expect(coord.perRowInsets[indexPath] == nil)
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
      #expect(coord.perRowBoxes[indexPath] == nil)
    }

    @Test func applyRowSeparatorVisibilityCachesValuePerIndexPath() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      #expect(coord.perRowSeparatorVisibility[indexPath] == nil)

      let box = coord.ensureRowBox(at: indexPath)
      #expect(box.separator.value == nil)

      let override = VirtualListRowSeparatorVisibility(top: .hidden, bottom: .hidden)
      box.separator.commit(override)
      #expect(coord.perRowSeparatorVisibility[indexPath] == override)
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
      #expect(coord.perRowSeparatorVisibility[indexPath] == override)

      // Explicit nil clears the cached override.
      box.separator.commit(nil)
      #expect(coord.perRowSeparatorVisibility[indexPath] == nil)
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
      #expect(coord.perRowBadgeHosts[indexPath] == nil)

      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))
      #expect(coord.perRowBadgeHosts[indexPath] != nil)
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
      #expect(coord.perRowBadgeHosts[indexPath] != nil)

      box.badge.commit(nil)
      #expect(coord.perRowBadgeHosts[indexPath] == nil)
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
      let first = coord.perRowBadgeHosts[indexPath]
      #expect(first != nil)

      box.badge.commit(AnyView(Text("9")))
      let second = coord.perRowBadgeHosts[indexPath]
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
      #expect(coord.perRowBadgeHosts[indexPath] != nil)

      coord.apply(sections: [syntheticSection(count: 5)], animated: false)
      #expect(coord.perRowBadgeHosts[indexPath] == nil)
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

  /// Per-IndexPath dicts on the coordinator are populated while a cell
  /// is on screen. Without a cleanup hook, scrolling 100k rows once
  /// would leave 100k entries in `perRowBoxes` (and up to two
  /// `UIHostingController`s per entry) alive until the next structural
  /// apply. The coordinator's `didEndDisplaying` delegate hook is what
  /// bounds this growth — these tests lock that contract in.
  @Suite("Per-row cache cleanup on cell eviction (iOS)")
  @MainActor
  struct PerRowCacheCleanupTests {
    @Test func didEndDisplayingDropsHeavyPerRowState() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.background.commit(AnyView(Color.blue))
      box.badge.commit(AnyView(Text("5")))
      #expect(coord.perRowBoxes[indexPath] != nil)
      #expect(coord.perRowBackgroundHosts[indexPath] != nil)
      #expect(coord.perRowBadgeHosts[indexPath] != nil)

      coord.collectionView(
        cv,
        didEndDisplaying: UICollectionViewCell(frame: .zero),
        forItemAt: indexPath
      )

      #expect(coord.perRowBoxes[indexPath] == nil)
      #expect(coord.perRowBackgroundHosts[indexPath] == nil)
      #expect(coord.perRowBadgeHosts[indexPath] == nil)
    }

    @Test func didEndDisplayingKeepsLightweightValueCaches() {
      // Insets and separator-visibility are plain values, cheap to keep
      // and cheap to re-read. Dropping them on scroll-off would make a
      // scroll-back flash through the default margins before the
      // `.onAppear` modifier re-commits — keep the contract visible.
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      let insets = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
      let separator = VirtualListRowSeparatorVisibility(top: .hidden, bottom: .hidden)
      box.insets.commit(insets)
      box.separator.commit(separator)

      coord.collectionView(
        cv,
        didEndDisplaying: UICollectionViewCell(frame: .zero),
        forItemAt: indexPath
      )

      #expect(coord.perRowInsets[indexPath] == insets)
      #expect(coord.perRowSeparatorVisibility[indexPath] == separator)
    }
  }

  /// Reorder surfaces two concerns that this suite locks in:
  ///  1. Accessory composition: when `.onMove` is set AND a row has a
  ///     badge, both accessories must be present on the cell. A prior
  ///     regression stamped `cell.accessories = [badge]` from the
  ///     badge-commit path, silently wiping the reorder handle.
  ///  2. Delegate forwarding: `canMoveItemAt` / `moveItemAt:to:` are
  ///     the data-source hooks UIKit calls at drag-end; these must
  ///     gate on the presence of `onMove` and forward to the caller's
  ///     closure.
  @Suite("Reorder wiring (iOS)")
  @MainActor
  struct ReorderWiringTests {
    @Test func canMoveGatedOnOnMovePresence() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)

      let indexPath = IndexPath(item: 0, section: 0)
      #expect(coord.collectionView(cv, canMoveItemAt: indexPath) == false)

      var config = VirtualListConfiguration()
      config.onMove = { _, _ in }
      coord.configuration = config
      #expect(coord.collectionView(cv, canMoveItemAt: indexPath) == true)
    }

    @Test func moveItemForwardsSourceAndDestinationToCaller() {
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 5)], animated: false)

      var received: (IndexPath, IndexPath)?
      var config = VirtualListConfiguration()
      config.onMove = { src, dst in received = (src, dst) }
      coord.configuration = config

      let src = IndexPath(item: 0, section: 0)
      let dst = IndexPath(item: 3, section: 0)
      coord.collectionView(cv, moveItemAt: src, to: dst)

      #expect(received?.0 == src)
      #expect(received?.1 == dst)
    }

    @Test func reorderAndBadgeAccessoriesCoexistOnSameCell() {
      // Config must be set before `install`: `canReorderItem` in the
      // reorderingHandlers closes over `onMove` through `self?.configuration`
      // — the accessory path separately reads `configuration.onMove`, so
      // setting it before the first cell-configure keeps both surfaces
      // aligned from the start.
      let coord = VirtualListPlatformCoordinator()
      var config = VirtualListConfiguration()
      config.onMove = { _, _ in }
      coord.configuration = config

      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))

      guard let cell = cv.cellForItem(at: indexPath) as? UICollectionViewListCell else {
        Issue.record("Cell missing after layoutIfNeeded")
        return
      }
      // Badge + reorder = 2 trailing accessories. A regression that
      // restamps only `[badge]` would show 1 here.
      #expect(cell.accessories.count == 2)
    }

    @Test func badgeAloneDoesNotInstallReorderAccessory() {
      // Control test for the suite above: without `onMove`, committing
      // a badge leaves exactly one accessory on the cell.
      let coord = VirtualListPlatformCoordinator()
      let cv = makePlatformCollectionView(height: 220)
      coord.install(on: cv)
      coord.apply(sections: [syntheticSection(count: 3)], animated: false)
      cv.layoutIfNeeded()

      let indexPath = IndexPath(item: 0, section: 0)
      let box = coord.ensureRowBox(at: indexPath)
      box.badge.commit(AnyView(Text("5")))

      guard let cell = cv.cellForItem(at: indexPath) as? UICollectionViewListCell else {
        Issue.record("Cell missing after layoutIfNeeded")
        return
      }
      #expect(cell.accessories.count == 1)
    }
  }
#endif
