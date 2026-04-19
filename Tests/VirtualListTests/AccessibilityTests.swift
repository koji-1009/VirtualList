#if canImport(UIKit)
  import SwiftUI
  import Testing
  import UIKit

  @testable import VirtualList

  /// End-to-end accessibility checks for `VirtualList` on UIKit.
  ///
  /// Attaches a real `UIWindow` + `UIHostingController` so the trait
  /// chain that drives Dynamic Type is actually live — detached hosts
  /// miss the `UIHostingConfiguration` propagation path.
  ///
  /// VoiceOver label exposure is deliberately *not* asserted here:
  /// `UIHostingConfiguration` builds its accessibility element tree
  /// lazily, and the simulator under `xcodebuild test` never
  /// activates VoiceOver or an Accessibility Inspector client, so the
  /// tree stays empty. That path is covered by a manual walk-through
  /// in the demo app (see the README's "What isn't automated"
  /// section).
  @Suite("Accessibility (iOS)")
  @MainActor
  struct AccessibilityTests {
    /// Dynamic Type: boosting the preferred content-size category on
    /// the hosting window should make self-sizing cells grow in height
    /// because `UIHostingConfiguration` reads the trait collection
    /// when measuring its hosted SwiftUI view.
    @Test func cellHeightRespondsToDynamicTypeTrait() {
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
      let host = UIHostingController(
        rootView: VirtualList(itemCount: 5, id: { $0 }) { index in
          Text("Row \(index)")
        }
      )
      host.view.frame = window.bounds
      window.rootViewController = host
      window.isHidden = false
      host.view.layoutIfNeeded()
      CATransaction.flush()

      guard let cv = findCollectionView(in: host.view),
        let beforeCell = cv.visibleCells.first
      else {
        Issue.record("expected at least one visible cell")
        return
      }
      let beforeHeight = beforeCell.frame.height

      host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraLarge
      cv.setNeedsLayout()
      cv.layoutIfNeeded()
      CATransaction.flush()

      guard let afterCell = cv.visibleCells.first else {
        Issue.record("expected a visible cell after re-layout")
        return
      }
      #expect(afterCell.frame.height > beforeHeight)

      withExtendedLifetime(host) {}
      withExtendedLifetime(window) {}
    }

    // MARK: - Helpers

    private func findCollectionView(in view: UIView) -> UICollectionView? {
      if let cv = view as? UICollectionView { return cv }
      for sub in view.subviews {
        if let found = findCollectionView(in: sub) { return found }
      }
      return nil
    }
  }
#endif
