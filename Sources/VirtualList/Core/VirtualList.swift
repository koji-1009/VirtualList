import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif
#if canImport(AppKit)
  import AppKit
#endif

/// A high-performance SwiftUI list that scales to millions of rows.
///
/// On iOS / Catalyst `VirtualList` wraps `UICollectionView` +
/// `UICollectionViewDiffableDataSource` via `UIViewRepresentable`. On macOS it
/// wraps `NSTableView` + `NSHostingView` per visible row via
/// `NSViewRepresentable`. Either way, only visible rows pay the cost of
/// SwiftUI view construction.
///
/// ```swift
/// // Collection-based (List-compatible)
/// VirtualList(users, id: \.id) { user in
///     UserRow(user: user)
/// }
///
/// // Index-based (large datasets)
/// VirtualList(itemCount: 1_000_000, id: { $0 }) { index in
///     Row(index: index)
/// }
/// ```
public struct VirtualList {
  let sections: [VirtualListSection]
  var configuration: VirtualListConfiguration
}

#if canImport(UIKit)
  extension VirtualList: UIViewRepresentable {
    public func makeCoordinator() -> VirtualListCoordinator {
      VirtualListCoordinator()
    }

    public func makeUIView(context: Context) -> UICollectionView {
      let layout = Self.makeLayout(for: configuration, coordinator: context.coordinator)
      let collectionView = VirtualListHostCollectionView(frame: .zero, collectionViewLayout: layout)
      applyScrollConfiguration(to: collectionView, from: configuration)
      applyEditMode(to: collectionView, from: context.environment)
      // Configuration must be set before `install(on:)` so the data-source
      // wiring (`.diffed` vs `.indexed`) runs through the user's policy on
      // the first pass, not through the default and then again from `apply`.
      context.coordinator.configuration = configuration
      context.coordinator.install(on: collectionView)
      context.coordinator.apply(sections: sections, animated: false)
      // `resolveSelection` / `resolveRefreshControl` / `resolveFocusBinder`
      // are deferred to `didMoveToWindow` — see `VirtualListHostCollectionView`.
      return collectionView
    }

    /// Drops the coordinator's strong references on removal from the view
    /// tree. SwiftUI would eventually release them on its own, but the
    /// diffable data source can hold the collection view alive past the
    /// dismiss, and environment-override closures retain user
    /// `ObservableObject`s; tearing down here makes cleanup deterministic.
    public static func dismantleUIView(
      _ uiView: UICollectionView,
      coordinator: VirtualListCoordinator
    ) {
      coordinator.tearDown(collectionView: uiView)
    }

    public func updateUIView(_ collectionView: UICollectionView, context: Context) {
      let coordinator = context.coordinator
      let layoutNeedsRebuild = shouldRebuildLayout(
        previous: coordinator.configuration,
        next: configuration
      )

      coordinator.configuration = configuration

      if layoutNeedsRebuild {
        collectionView.setCollectionViewLayout(
          Self.makeLayout(for: configuration, coordinator: coordinator),
          animated: false
        )
      }

      applyScrollConfiguration(to: collectionView, from: configuration)
      applyEditMode(to: collectionView, from: context.environment)

      let outcome = coordinator.apply(
        sections: sections,
        animated: !context.transaction.disablesAnimations
      )
      coordinator.resolveSelection()
      coordinator.resolveRefreshControl()
      coordinator.resolveFocusBinder()

      // SwiftUI rebuilds the section closures with freshly captured state on
      // every parent update. Cells that this `apply` call did NOT
      // re-dequeue therefore still carry stale content, so we reconfigure
      // them here. The only time this is redundant is after a full
      // `reloadData`, where every visible cell will be re-dequeued on the
      // next layout pass anyway — reconfiguring then would double the work.
      if outcome != .reloaded {
        coordinator.reconfigureVisibleCells()
      }
    }

    private func shouldRebuildLayout(
      previous: VirtualListConfiguration,
      next: VirtualListConfiguration
    ) -> Bool {
      previous.style != next.style || previous.gridColumns != next.gridColumns
    }

    /// Maps `.scrollContentBackground(_:)` / `.scrollDismissesKeyboard(_:)`
    /// onto the collection view.
    private func applyScrollConfiguration(
      to collectionView: UICollectionView,
      from configuration: VirtualListConfiguration
    ) {
      let targetBackground: UIColor
      switch configuration.scrollContentBackground {
      case .visible: targetBackground = .systemBackground
      case .hidden, .automatic, nil: targetBackground = .clear
      @unknown default: targetBackground = .clear
      }
      // Guarded so `updateUIView` (which runs on every SwiftUI
      // state-change) doesn't churn UIKit property setters when the
      // target is already stable.
      if collectionView.backgroundColor != targetBackground {
        collectionView.backgroundColor = targetBackground
      }

      let targetDismissMode: UIScrollView.KeyboardDismissMode
      if let mode = configuration.scrollDismissesKeyboard {
        targetDismissMode = virtualListKeyboardDismissMode(for: mode)
      } else {
        targetDismissMode = .none
      }
      if collectionView.keyboardDismissMode != targetDismissMode {
        collectionView.keyboardDismissMode = targetDismissMode
      }
    }

    /// Mirrors `\.editMode` into `UICollectionView.isEditing` so
    /// `.environment(\.editMode, $binding)` / `EditButton` turns on
    /// UIKit's editing UX (inline delete, reorder handles).
    /// `internal` so `@testable` tests can exercise the mapping without
    /// a full SwiftUI host.
    func applyEditMode(
      to collectionView: UICollectionView,
      from environment: EnvironmentValues
    ) {
      let isEditing = environment.editMode?.wrappedValue.isEditing ?? false
      guard collectionView.isEditing != isEditing else { return }
      collectionView.isEditing = isEditing
    }

    static func makeLayout(
      for configuration: VirtualListConfiguration,
      coordinator: VirtualListCoordinator?
    ) -> UICollectionViewLayout {
      if let grid = configuration.gridColumns {
        return GridLayoutBuilder.make(columns: grid)
      }
      let style = configuration.style
      let showsSeparators = configuration.rowSeparators ?? true
      // Use the per-section factory so that sections without a header/footer
      // don't reserve space for a supplementary view. `list(using:)` would apply
      // the same `.supplementary` mode to every section, leaving a visible gap
      // at the top of header-less sections.
      return UICollectionViewCompositionalLayout { [weak coordinator] sectionIndex, env in
        let sections = coordinator?.sections ?? []
        let hasHeader = sectionIndex < sections.count && sections[sectionIndex].header != nil
        let hasFooter = sectionIndex < sections.count && sections[sectionIndex].footer != nil
        var listConfig = UICollectionLayoutListConfiguration(appearance: style.appearance)
        listConfig.headerMode = hasHeader ? .supplementary : .none
        listConfig.footerMode = hasFooter ? .supplementary : .none
        listConfig.showsSeparators = showsSeparators
        // Compositional-layout lists receive swipe actions through the
        // config's own providers; `UICollectionViewDelegate`'s swipe
        // methods do not fire here. Per-row `.swipeActions` on
        // `VirtualListRow` outranks the list-level closure.
        listConfig.leadingSwipeActionsConfigurationProvider = { [weak coordinator] indexPath in
          if let cfg = coordinator?.swipeActionsConfiguration(for: indexPath, edge: .leading) {
            return cfg
          }
          return coordinator?.configuration.swipeActionsLeading?.build(indexPath)
        }
        listConfig.trailingSwipeActionsConfigurationProvider = { [weak coordinator] indexPath in
          if let cfg = coordinator?.swipeActionsConfiguration(for: indexPath, edge: .trailing) {
            return cfg
          }
          if let cfg = coordinator?.configuration.swipeActionsTrailing?.build(indexPath) {
            return cfg
          }
          // Final fallback: `.onDelete(perform:)` handler materialises
          // a default destructive "Delete" action, matching
          // `SwiftUI.ForEach.onDelete`'s behaviour.
          return coordinator?.defaultDeleteSwipeConfiguration(for: indexPath)
        }
        // Per-row `.listRowSeparator(_:edges:)` overrides flow through
        // this handler. Rows without a modifier leave the default
        // configuration untouched, so the list's global
        // `.showsSeparators` value still drives them.
        listConfig.itemSeparatorHandler = { [weak coordinator] indexPath, defaultConfig in
          var config = defaultConfig
          guard let vis = coordinator?.rowSeparatorVisibility(at: indexPath)
          else { return config }
          config.topSeparatorVisibility = vis.top.uiListSeparatorVisibility
          config.bottomSeparatorVisibility = vis.bottom.uiListSeparatorVisibility
          return config
        }
        return NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: env)
      }
    }
  }

  /// `UICollectionView` subclass that defers selection / refresh /
  /// focus resolution until `didMoveToWindow` — those steps need a
  /// live responder chain that doesn't exist during `makeUIView`.
  final class VirtualListHostCollectionView: UICollectionView {
    weak var viewCoordinator: VirtualListCoordinator?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else { return }
      viewCoordinator?.didAttachToWindow()
    }
  }
#endif
