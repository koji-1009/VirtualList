import SwiftUI
import XCTest

@testable import VirtualList

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#endif

/// Head-to-head benchmark: SwiftUI.List vs VirtualList, same data, same host.
///
/// Two data shapes are compared because SwiftUI.List has a heavily-optimized
/// code path for `Range<Int>` that skips per-element identity work — so a
/// Range-only comparison flatters List. Real apps mostly pass an `Array` of
/// `Identifiable` elements, which is what the `_collection_` variants exercise.
///
/// No CI gate — hosting cost varies with hardware and OS version; these numbers
/// exist so the library's value proposition is visible rather than asserted.
/// CI skips this suite via `-skip-testing:VirtualListTests/ListVsVirtualListBenchmarks`.
@MainActor
final class ListVsVirtualListBenchmarks: XCTestCase {
  private let hostSize = CGSize(width: 375, height: 800)

  /// Standard measurement options — 100 iterations. Benchmark
  /// distributions here are heavy-tailed (cold-host / GC / scheduler
  /// effects land on a handful of samples and pull the mean around),
  /// so n=30 — the classical CLT rule of thumb, which assumes a
  /// roughly normal distribution — gives only ~30-50 % power to
  /// distinguish a 5-10 % ratio from noise. n=100 brings that to
  /// ~80 %+ across the range of ratios this suite reports, and the
  /// total wall clock stays under a minute on macOS / under two
  /// minutes on an iPhone simulator because each `measure` block is
  /// a single render or single flip (ms-scale, not seconds).
  ///
  /// `compare_bench.swift` pairs these samples through a Mann-Whitney
  /// U rank test rather than a Welch t-test, so the distributional
  /// assumption sits at "samples are exchangeable under the null",
  /// not "samples are normally distributed".
  private func renderMeasureOptions() -> XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 100
    return opts
  }

  /// Runs the view-hosting block once to prime caches / JIT / font-descriptor
  /// lookups / SwiftUI-internal state before starting the measured loop. The
  /// first `measure` iteration is otherwise inflated by these one-shot
  /// costs.
  private func measureRender<V: View>(
    metrics: [any XCTMetric] = [XCTClockMetric(), XCTMemoryMetric()],
    view: () -> V
  ) {
    hostAndLayout(view())  // warm-up — result discarded
    measure(metrics: metrics, options: renderMeasureOptions()) {
      hostAndLayout(view())
    }
  }

  // MARK: - Small-N range (crossover probing)
  //
  // Short lists (N ≤ 100) are where the "list widget should always be fast"
  // claim is decided. `SwiftUI.List` has a fixed ~10 ms setup floor; its
  // per-item identity walk is cheap at small N. `VirtualList` also has a
  // setup floor plus per-visible-cell NSHostingView / UIHostingConfiguration
  // cost. If VirtualList loses or ties at these sizes, the "always fast"
  // thesis is unproven.

  func test_list_range_10() {
    measureRender { listRangeView(count: 10) }
  }

  func test_virtualList_range_10() {
    measureRender { virtualListRangeView(count: 10) }
  }

  func test_list_range_20() {
    measureRender { listRangeView(count: 20) }
  }

  func test_virtualList_range_20() {
    measureRender { virtualListRangeView(count: 20) }
  }

  func test_list_range_50() {
    measureRender { listRangeView(count: 50) }
  }

  func test_virtualList_range_50() {
    measureRender { virtualListRangeView(count: 50) }
  }

  func test_list_range_100() {
    measureRender { listRangeView(count: 100) }
  }

  func test_virtualList_range_100() {
    measureRender { virtualListRangeView(count: 100) }
  }

  func test_list_range_500() {
    measureRender { listRangeView(count: 500) }
  }

  func test_virtualList_range_500() {
    measureRender { virtualListRangeView(count: 500) }
  }

  // MARK: - Range-based (SwiftUI.List's fast path)

  func test_list_range_1k() {
    measureRender { listRangeView(count: 1_000) }
  }

  func test_virtualList_range_1k() {
    measureRender { virtualListRangeView(count: 1_000) }
  }

  func test_list_range_10k() {
    measureRender { listRangeView(count: 10_000) }
  }

  func test_virtualList_range_10k() {
    measureRender { virtualListRangeView(count: 10_000) }
  }

  func test_list_range_100k() {
    measureRender { listRangeView(count: 100_000) }
  }

  func test_virtualList_range_100k() {
    measureRender { virtualListRangeView(count: 100_000) }
  }

  // MARK: - Collection-based (realistic case: Array of Identifiable)

  func test_list_collection_1k() {
    let data = Self.sampleRows(count: 1_000)
    measureRender { listCollectionView(data: data) }
  }

  func test_virtualList_collection_1k() {
    let data = Self.sampleRows(count: 1_000)
    measureRender { virtualListCollectionView(data: data) }
  }

  func test_list_collection_10k() {
    let data = Self.sampleRows(count: 10_000)
    measureRender { listCollectionView(data: data) }
  }

  func test_virtualList_collection_10k() {
    let data = Self.sampleRows(count: 10_000)
    measureRender { virtualListCollectionView(data: data) }
  }

  func test_list_collection_100k() {
    let data = Self.sampleRows(count: 100_000)
    measureRender { listCollectionView(data: data) }
  }

  func test_virtualList_collection_100k() {
    let data = Self.sampleRows(count: 100_000)
    measureRender { virtualListCollectionView(data: data) }
  }

  // MARK: - Views under test

  // Both sides pin `.plain` so the style-default asymmetry between
  // engines (SwiftUI.List's default is context-dependent and
  // resolves via `.automatic`; VirtualList's default is
  // unconditionally `.plain`) does not silently bias the
  // measurement. Without these modifiers, the List side may render
  // `.insetGrouped` chrome in some hosting contexts, which would
  // load it with section-background drawing costs that the VL side
  // does not pay.

  private func listRangeView(count: Int) -> some View {
    List(0..<count, id: \.self) { index in
      Text("Row \(index)")
    }
    .listStyle(.plain)
  }

  private func virtualListRangeView(count: Int) -> some View {
    VirtualList(itemCount: count, id: { $0 }) { index in
      Text("Row \(index)")
    }
    .virtualListStyle(.plain)
    .virtualListUpdatePolicy(.indexed)
  }

  private func listCollectionView(data: [Row]) -> some View {
    List(data) { row in
      Text(row.title)
    }
    .listStyle(.plain)
  }

  private func virtualListCollectionView(data: [Row]) -> some View {
    VirtualList(data) { row in
      Text(row.title)
    }
    .virtualListStyle(.plain)
    .virtualListUpdatePolicy(.indexed)
  }

  // MARK: - Realistic shape
  //
  // The `_range_` / `_collection_` tests above use a single `Text` per
  // row. That's a useful wrapper-overhead microbenchmark, but it's also
  // the shape that flatters `SwiftUI.List` most — its per-row private-
  // hosting fast path dominates when there's almost no body to render.
  // Real app rows are heavier: leading icon, primary + secondary text,
  // trailing metadata. The `_realistic_*` and `_heavy_*` suites below
  // measure VirtualList vs List under that shape so the README can
  // report both the wrapper-limited case and the content-limited case.
  //
  // Each realistic / heavy row type is a concrete `View` with deterministic
  // content so the measurement has no data-fetch variance.

  func test_list_realistic_10() {
    measureRender { ListRealisticView(count: 10) }
  }

  func test_virtualList_realistic_10() {
    measureRender { VirtualListRealisticView(count: 10) }
  }

  func test_list_realistic_100() {
    measureRender { ListRealisticView(count: 100) }
  }

  func test_virtualList_realistic_100() {
    measureRender { VirtualListRealisticView(count: 100) }
  }

  func test_list_realistic_1k() {
    measureRender { ListRealisticView(count: 1_000) }
  }

  func test_virtualList_realistic_1k() {
    measureRender { VirtualListRealisticView(count: 1_000) }
  }

  func test_list_heavy_10() {
    measureRender { ListHeavyView(count: 10) }
  }

  func test_virtualList_heavy_10() {
    measureRender { VirtualListHeavyView(count: 10) }
  }

  func test_list_heavy_100() {
    measureRender { ListHeavyView(count: 100) }
  }

  func test_virtualList_heavy_100() {
    measureRender { VirtualListHeavyView(count: 100) }
  }

  func test_list_heavy_1k() {
    measureRender { ListHeavyView(count: 1_000) }
  }

  func test_virtualList_heavy_1k() {
    measureRender { VirtualListHeavyView(count: 1_000) }
  }

  // Per-update flip on the same realistic / heavy shapes. N=100 picks
  // the case where the wrapper-limited `_range_` update is closest
  // (tied) — the realistic / heavy rows should shift further in
  // `VirtualList`'s favour once content cost joins wrapper cost.

  func test_updateList_realistic_100() {
    measureUpdate(count: 100) { RealisticUpdateListView(store: $0) }
  }

  func test_updateVirtualList_realistic_100() {
    measureUpdate(count: 100) { RealisticUpdateVirtualListView(store: $0) }
  }

  func test_updateList_heavy_100() {
    measureUpdate(count: 100) { HeavyUpdateListView(store: $0) }
  }

  func test_updateVirtualList_heavy_100() {
    measureUpdate(count: 100) { HeavyUpdateVirtualListView(store: $0) }
  }

  // MARK: - Sample data

  struct Row: Identifiable {
    let id: Int
    let title: String
  }

  private static func sampleRows(count: Int) -> [Row] {
    (0..<count).map { Row(id: $0, title: "Row \($0)") }
  }

  // MARK: - Update (state-change → re-render) benchmarks
  //
  // Initial-render is pessimistic against both backends because SwiftUI hosts
  // are lazy. The realistic hot path is: list is on screen with N rows, user
  // action mutates the data model, SwiftUI propagates the change through the
  // list's body closure. `.indexed` VirtualList promises O(1) for that path;
  // this is where the library earns its place.
  //
  // The `UpdateHarnessStore` / `UpdateHarnessListView` /
  // `UpdateHarnessVirtualListView` types live in `Support/UpdateHarness.swift`
  // so the head-to-head gate in `PerformanceTests.swift` can share them.

  func test_updateList_range_10() {
    measureUpdate(count: 10, build: { UpdateHarnessListView(store: $0) })
  }

  func test_updateVirtualList_range_10() {
    measureUpdate(count: 10, build: { UpdateHarnessVirtualListView(store: $0) })
  }

  func test_updateList_range_100() {
    measureUpdate(count: 100, build: { UpdateHarnessListView(store: $0) })
  }

  func test_updateVirtualList_range_100() {
    measureUpdate(count: 100, build: { UpdateHarnessVirtualListView(store: $0) })
  }

  func test_updateList_range_1k() {
    measureUpdate(count: 1_000, build: { UpdateHarnessListView(store: $0) })
  }

  func test_updateVirtualList_range_1k() {
    measureUpdate(count: 1_000, build: { UpdateHarnessVirtualListView(store: $0) })
  }

  func test_updateList_range_10k() {
    measureUpdate(count: 10_000, build: { UpdateHarnessListView(store: $0) })
  }

  func test_updateVirtualList_range_10k() {
    measureUpdate(
      count: 10_000,
      build: { UpdateHarnessVirtualListView(store: $0) }
    )
  }

  func test_updateList_range_100k() {
    measureUpdate(count: 100_000, build: { UpdateHarnessListView(store: $0) })
  }

  func test_updateVirtualList_range_100k() {
    measureUpdate(
      count: 100_000,
      build: { UpdateHarnessVirtualListView(store: $0) }
    )
  }

  /// Shared harness for the update benchmarks.
  ///
  /// Builds a hosted list backed by `UpdateHarnessStore` and times
  /// **one** @State flip per `measure` block. Each flip toggles the
  /// trailing item (`count ↔ count+1`) so the diffable/indexed paths
  /// see a real structural change without drifting N.
  ///
  /// Inner iteration count is fixed at 1 so the Clock-Monotonic
  /// `average` reported by `XCTestCase.measure` is **per flip**
  /// directly — there is no caller-side divisor to remember. An
  /// earlier revision accepted an `iterations` parameter and multiplied
  /// inside the block, which made the raw output 20× or 50× too large
  /// and left the reader to divide before comparing tests. The bug
  /// that caused was a script-design bug, not an arithmetic slip.
  private func measureUpdate<Body: View>(
    count: Int,
    build: (UpdateHarnessStore) -> Body
  ) {
    let store = UpdateHarnessStore(count: count)
    let view = build(store)

    #if canImport(UIKit)
      let host = UIHostingController(rootView: view)
      host.view.frame = CGRect(origin: .zero, size: hostSize)
      let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
      window.rootViewController = host
      window.isHidden = false
      host.view.layoutIfNeeded()
      CATransaction.flush()
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: hostSize),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
      )
      let host = NSHostingView(rootView: view)
      host.frame = CGRect(origin: .zero, size: hostSize)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
    #endif

    // Warm-up: drive two flips through the harness so the first measured
    // iteration doesn't absorb diffable-snapshot lazy init, SwiftUI host
    // property observers, and Metal pipeline warm-up costs.
    for i in 0..<2 {
      store.count = count + (i % 2)
      #if canImport(UIKit)
        host.view.layoutIfNeeded()
        CATransaction.flush()
      #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
      #endif
    }

    // Alternates between `count` and `count+1` across the 30 measured
    // samples so each `measure` call is a real structural flip, never a
    // fingerprint no-op. `measure`'s block is invoked once per sample,
    // and the Clock-Monotonic `average` output is therefore per-flip.
    measure(metrics: [XCTClockMetric()], options: renderMeasureOptions()) {
      store.count = (store.count == count) ? count + 1 : count
      #if canImport(UIKit)
        host.view.layoutIfNeeded()
        CATransaction.flush()
      #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
      #endif
    }

    #if canImport(UIKit)
      withExtendedLifetime(host) {}
      withExtendedLifetime(window) {}
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      withExtendedLifetime(host) {}
      withExtendedLifetime(window) {}
    #endif
  }

  // MARK: - Hosting harness

  /// Host `content` in a platform hosting view attached to a real window,
  /// size it to `hostSize`, and force the SwiftUI body + layout pass to run
  /// to completion. Every call creates a fresh host so each iteration pays
  /// the initial-render cost.
  ///
  /// The window attachment matters on macOS: detached `NSHostingView` skips
  /// some of the view-graph finalisation that a real render performs, which
  /// makes measurements diverge from production behaviour. Both platforms
  /// now route through a live window so the comparison is apples-to-apples.
  private func hostAndLayout(_ content: some View) {
    #if canImport(UIKit)
      let host = UIHostingController(rootView: content)
      host.view.frame = CGRect(origin: .zero, size: hostSize)
      let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
      window.rootViewController = host
      window.isHidden = false
      host.view.setNeedsLayout()
      host.view.layoutIfNeeded()
      CATransaction.flush()
      withExtendedLifetime(host) {}
      withExtendedLifetime(window) {}
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: hostSize),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
      )
      let host = NSHostingView(rootView: content)
      host.frame = CGRect(origin: .zero, size: hostSize)
      window.contentView = host
      host.needsLayout = true
      host.layoutSubtreeIfNeeded()
      withExtendedLifetime(host) {}
      withExtendedLifetime(window) {}
    #endif
  }
}
