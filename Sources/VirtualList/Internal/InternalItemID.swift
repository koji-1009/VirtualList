import Foundation

/// A compound identifier used by the diffable data source.
///
/// `UICollectionViewDiffableDataSource` requires item identifiers to be unique across the
/// entire snapshot. To allow the same user-supplied item ID to appear in different sections,
/// VirtualList namespaces every item ID by its section ID before handing it to the data source.
struct InternalItemID: Hashable {
  let sectionID: AnyHashable
  let itemID: AnyHashable
}
