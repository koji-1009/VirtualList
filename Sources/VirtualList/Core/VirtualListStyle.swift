import CoreGraphics

/// Strategy used to push new data into the underlying collection view.
///
/// - `.diffed`: uses `UICollectionViewDiffableDataSource`, which gives automatic
///   insert / delete / move animations but has to walk every row once per apply
///   to build its snapshot (cost and memory are O(N)).
/// - `.indexed`: uses a classic `UICollectionViewDataSource` that answers
///   `numberOfItemsInSection` with the stored count. Applies are O(1) and no
///   per-row identifiers are allocated, at the cost of losing automatic diff
///   animations — reloads are batched as `reloadData` / `performBatchUpdates`.
///
/// Default is `.diffed`. Switch to `.indexed` for very large (≥ 10k) or
/// synthetic lists where you don't need animated updates.
public enum VirtualListUpdatePolicy: Sendable {
  case diffed
  case indexed
}

/// What a call to `VirtualListCoordinator.apply(sections:animated:)` (or the
/// AppKit counterpart) did to the underlying view.
///
/// The representable's `update…View` uses this to decide whether it still
/// needs to run `reconfigureVisibleCells()`. The library's closures capture
/// state on each SwiftUI body evaluation, so cells that the apply call did
/// *not* re-dequeue must be reconfigured to pick up the new closures.
public enum VirtualListApplyOutcome: Sendable, Equatable {
  /// Fingerprint matched the previous apply — no data-source mutation ran.
  /// Visible cells keep their content until the caller reconfigures them.
  case unchanged

  /// `reloadData()` was called; every visible cell will be re-dequeued by
  /// the underlying view on its next layout pass. Running
  /// `reconfigureVisibleCells` on top would duplicate work.
  case reloaded

  /// Incremental structural change — the diffable data source, or the
  /// classic data source's `insertItems` / `deleteItems` /
  /// `insertRows` / `removeRows`, only dequeues the affected rows.
  /// Existing visible cells keep their current configuration, so the
  /// caller still needs to reconfigure them to propagate fresh closure
  /// state.
  case incremental
}

/// Visual style applied to the underlying platform list.
///
/// On iOS/Catalyst this maps to `UICollectionLayoutListConfiguration.Appearance`. The
/// enum itself is platform-neutral so that builder code and tests can reference it
/// everywhere.
public enum VirtualListStyle: Sendable {
  case plain
  case grouped
  case insetGrouped
  case sidebar
  case sidebarPlain
}

/// Column specification for grid layouts. Mirrors the shape of `LazyVGrid`'s column API
/// but is translated into a platform collection-view layout at render time.
public struct VirtualListGridColumns: Sendable, Equatable {
  public enum Size: Sendable, Equatable {
    case fixed(CGFloat)
    case flexible(minimum: CGFloat, maximum: CGFloat)
    case adaptive(minimum: CGFloat, maximum: CGFloat)
  }

  public let sizes: [Size]
  public let spacing: CGFloat
  public let rowSpacing: CGFloat

  public init(_ sizes: [Size], spacing: CGFloat = 8, rowSpacing: CGFloat = 8) {
    self.sizes = sizes
    self.spacing = spacing
    self.rowSpacing = rowSpacing
  }
}
