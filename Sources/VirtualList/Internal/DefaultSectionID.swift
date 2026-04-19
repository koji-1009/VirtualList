import Foundation

/// Sentinel section identifier used when no explicit section ID is needed.
///
/// Two constructor paths resolve to this:
/// 1. The `VirtualList(itemCount:id:content:)` and `VirtualList(_ data,...)`
///    initialisers, which build a synthetic single-section list.
/// 2. The result-builder `buildExpression(_ items: VirtualItems)` overload,
///    which wraps a bare `VirtualItems` expression in a synthetic section.
///
/// All such lists share the same identity, so if a caller expresses two bare
/// `VirtualItems` blocks inside one builder the diffable snapshot rejects the
/// duplicate at apply time — a clear signal to disambiguate with
/// `VirtualSection`.
enum DefaultSectionID: Hashable {
  case `default`
}
