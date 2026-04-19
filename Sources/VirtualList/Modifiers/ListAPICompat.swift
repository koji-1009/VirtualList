import SwiftUI

/// List-level drop-in aliases for the common `SwiftUI.List` modifiers
/// (`.listStyle`, `.listRowSeparator`, `.refreshable`, `.onMove`). Each alias
/// forwards to the namespaced `virtualList*` method so configuration stays
/// single-sourced. Per-row modifiers live in `RowAPI.swift` and dispatch via
/// the `VirtualListRow` protocol.
extension VirtualList {
  /// Sets the list style. Mirrors `SwiftUI.View.listStyle(_:)` but accepts
  /// `VirtualListStyle` rather than `SwiftUI.ListStyle` because the protocol's
  /// concrete conformers (`PlainListStyle`, `InsetGroupedListStyle`, …) are
  /// opaque to third-party code.
  public func listStyle(_ style: VirtualListStyle) -> VirtualList {
    virtualListStyle(style)
  }

  /// Toggles row separators. Mirrors the common
  /// `.listRowSeparator(_:edges:)` call — the `edges` parameter is accepted
  /// but ignored (AppKit/UIKit list-row separator visibility is all-or-none
  /// at the list level).
  public func listRowSeparator(
    _ visibility: Visibility,
    edges: VerticalEdge.Set = .all
  ) -> VirtualList {
    _ = edges
    switch visibility {
    case .visible:
      return virtualListRowSeparators(true)
    case .hidden:
      return virtualListRowSeparators(false)
    case .automatic:
      return virtualListRowSeparators(nil)
    @unknown default:
      return virtualListRowSeparators(nil)
    }
  }
}

#if canImport(UIKit)
  extension VirtualList {
    /// Adds pull-to-refresh. Mirrors `SwiftUI.View.refreshable(action:)`.
    public func refreshable(
      action: @escaping @Sendable () async -> Void
    ) -> VirtualList {
      virtualListRefreshable(action)
    }
  }
#else
  @available(
    macOS, unavailable,
    message:
      "Pull-to-refresh is iOS-only; AppKit has no equivalent gesture. Drive refresh from a toolbar / menu button on macOS."
  )
  extension VirtualList {
    public func refreshable(
      action: @escaping @Sendable () async -> Void
    ) -> VirtualList {
      self
    }
  }
#endif

extension VirtualList {
  /// Hooks a move handler that matches `SwiftUI.ForEach.onMove(perform:)`'s
  /// signature — `(IndexSet, Int) -> Void` — and forwards to the coordinator's
  /// reorder pipeline. Multi-element moves are delivered as successive
  /// single-element calls to the underlying `(IndexPath, IndexPath) -> Void`
  /// handler, matching the semantics `UICollectionViewDiffableDataSource`
  /// gives us natively.
  public func onMove(
    perform action: @escaping @MainActor (IndexSet, Int) -> Void
  ) -> VirtualList {
    virtualListReorder { source, destination in
      // `SwiftUI.ForEach.onMove` hands us a source-index set and a
      // destination index — translate our per-move delta back into that
      // shape for the caller.
      action(IndexSet(integer: source.item), destination.item)
    }
  }
}
