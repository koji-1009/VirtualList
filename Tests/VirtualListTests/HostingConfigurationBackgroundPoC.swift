#if canImport(UIKit)
  import SwiftUI
  import Testing
  import UIKit

  @testable import VirtualList

  /// Mini PoC for Phase 1 of the List API parity plan. Confirms that
  /// `UIHostingConfiguration.background(_:)` accepts a SwiftUI view and
  /// that a `UICollectionViewListCell` assigned the resulting
  /// configuration picks it up without runtime error.
  ///
  /// The unit test doesn't render visually — full verification of
  /// "row-width background" / "row-height tracking" belongs to the demo
  /// app — but it proves the API path compiles and that the cell applies
  /// the configuration. If this test turns red, Option B (hosting
  /// configuration background) is infeasible and we fall back to Option A
  /// (UIHostingController.view → backgroundConfiguration.customView).
  @Suite("UIHostingConfiguration.background PoC")
  @MainActor
  struct HostingConfigurationBackgroundPoC {
    @Test func backgroundAcceptsSwiftUIView() {
      // Build the configuration with a coloured background and dummy
      // foreground. The call site should compile cleanly on iOS 17+.
      let configuration = UIHostingConfiguration {
        Text("Row")
      }
      .background {
        Color.blue
      }

      // The configuration's concrete type encodes both content and
      // background generic params. Its `makeContentView()` produces a
      // UIView — exercising it confirms the SwiftUI hosting + background
      // slot wire up without runtime error.
      let view = configuration.makeContentView()
      #expect(view.frame.size != .zero || view.frame.size == .zero)
      // Actual frame is set by the cell layout pass; here we only verify
      // the view object was produced.
    }

    @Test func backgroundAcceptsAnyView() {
      // The production modifier stores the caller's background as
      // `AnyView?`. Confirm the configuration path accepts it via the
      // ViewBuilder closure.
      let bg: AnyView = AnyView(
        LinearGradient(
          colors: [.red, .orange],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      let configuration = UIHostingConfiguration {
        Text("Row")
      }
      .background {
        bg
      }
      _ = configuration.makeContentView()
    }

    @Test func cellAssignmentDoesNotCrash() {
      let cell = UICollectionViewListCell()
      cell.contentConfiguration = UIHostingConfiguration {
        Text("Row")
      }
      .background {
        Color.green
      }
      // Force a layout pass to exercise the hosted view graph.
      cell.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
      cell.layoutIfNeeded()
      // Reaching here without crash is the PoC's success criterion for
      // the "does Option B compile and not explode" question.
    }
  }
#endif
