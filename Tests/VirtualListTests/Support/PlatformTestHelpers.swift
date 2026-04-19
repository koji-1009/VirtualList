import SwiftUI

@testable import VirtualList

#if canImport(UIKit)
  import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#endif

// Cross-platform aliases used by the test suite.
//
// UIKit's `VirtualListCoordinator` and AppKit's `VirtualListMacCoordinator`
// expose the same public surface (`install(on:)`, `apply(_:animated:)`,
// `setUpdatePolicy(_:)`, `cellBuildCount`, `tearDown(collectionView:)`), so
// tests that don't care which one they're talking to can route through this
// typealias.
#if canImport(UIKit)
  typealias VirtualListPlatformCoordinator = VirtualListCoordinator
  typealias VirtualListPlatformCollectionView = UICollectionView
  typealias VirtualListPlatformRect = CGRect
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
  typealias VirtualListPlatformCoordinator = VirtualListMacCoordinator
  // The macOS backing is now `NSTableView`, but the typealias keeps the
  // name `VirtualListPlatformCollectionView` so cross-platform tests don't
  // have to fork. On macOS it resolves to `NSTableView`.
  typealias VirtualListPlatformCollectionView = NSTableView
  typealias VirtualListPlatformRect = NSRect
#endif

/// Builds a list-backing view appropriate for the current platform.
@MainActor
func makePlatformCollectionView(
  width: CGFloat = 320,
  height: CGFloat = 600
) -> VirtualListPlatformCollectionView {
  #if canImport(UIKit)
    var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
    listConfig.headerMode = .none
    listConfig.footerMode = .none
    let layout = UICollectionViewCompositionalLayout.list(using: listConfig)
    return UICollectionView(
      frame: CGRect(x: 0, y: 0, width: width, height: height),
      collectionViewLayout: layout
    )
  #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    let tv = NSTableView()
    tv.frame = NSRect(x: 0, y: 0, width: width, height: height)
    return tv
  #endif
}

/// A single synthetic section of `count` rows. Used by tests that only care
/// about per-row cost, not about which ID shape users are passing.
@MainActor
func syntheticSection(
  id: String = "s",
  count: Int,
  rowHeight: CGFloat = 44
) -> VirtualListSection {
  VirtualListSection(
    id: id,
    itemCount: count,
    itemID: { $0 },
    itemView: { i in Text("\(i)").frame(height: rowHeight) }
  )
}
