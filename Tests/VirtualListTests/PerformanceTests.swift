import Darwin
import Foundation
import SwiftUI
import XCTest

@testable import VirtualList

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#endif

/// Reads the current task's resident memory size (RSS) in bytes directly from
/// the kernel. Used by gates that need an absolute memory budget rather than
/// the baseline-relative numbers `XCTMemoryMetric` reports.
private func residentMemoryBytes() -> Int {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
  )
  let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(
        mach_task_self_,
        task_flavor_t(MACH_TASK_BASIC_INFO),
        $0,
        &count
      )
    }
  }
  return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
}

/// Absolute-budget CI gates.
///
/// Each test fails with an explicit wall-clock or memory budget set generously
/// wide (≥ 10× the currently-observed cost on local hardware). A test that
/// starts failing here means a change reintroduced O(N) work on a path the
/// library has publicly committed to being constant-time.
///
/// The gates are cross-platform: they run against whichever `VirtualList`
/// coordinator the current platform exposes (`UICollectionView`-backed on
/// iOS/Catalyst, `NSCollectionView`-backed on macOS). The same budgets must
/// hold on both — a regression on one surface is still a regression.
@MainActor
final class VirtualListPerformanceGates: XCTestCase {
  /// `.indexed` apply must be O(1). 10 ms at N=1M is ≥ 10× the observed ~1 ms.
  func test_gate_indexedApplyIsConstantTime() {
    let coord = VirtualListPlatformCoordinator()
    coord.setUpdatePolicy(.indexed)
    coord.install(on: makePlatformCollectionView())

    let clock = ContinuousClock()
    let elapsed = clock.measure {
      coord.apply(sections: [syntheticSection(count: 1_000_000)], animated: false)
    }
    XCTAssertLessThan(
      elapsed,
      .milliseconds(10),
      ".indexed apply of 1M rows must be O(1); took \(elapsed)"
    )
  }

  /// `.indexed` apply must not allocate per-item memory. Budget 2 MB of RSS
  /// growth for the coordinator + collection-view state at N=1M. Anything
  /// larger points at accidental per-row allocation.
  func test_gate_indexedApplyIsConstantMemory() {
    // Warm allocator / stdlib caches so the "before" reading is stable.
    autoreleasepool {
      let warmCV = makePlatformCollectionView()
      let warm = VirtualListPlatformCoordinator()
      warm.setUpdatePolicy(.indexed)
      warm.install(on: warmCV)
      warm.apply(sections: [syntheticSection(count: 1000)], animated: false)
      warm.tearDown(collectionView: warmCV)
    }

    let before = residentMemoryBytes()
    let cv = makePlatformCollectionView()
    let coord = VirtualListPlatformCoordinator()
    coord.setUpdatePolicy(.indexed)
    coord.install(on: cv)
    coord.apply(sections: [syntheticSection(count: 1_000_000)], animated: false)
    let after = residentMemoryBytes()

    withExtendedLifetime(coord) {}
    withExtendedLifetime(cv) {}

    let delta = after - before
    XCTAssertLessThan(
      delta,
      2 * 1024 * 1024,
      ".indexed apply of 1M rows grew RSS by \(delta) bytes; must not allocate per item"
    )
  }

  /// Redundant apply with matching section fingerprint must short-circuit
  /// before the snapshot loop runs. Budget 1 ms at N=100k.
  func test_gate_redundantApplyIsDeduped() {
    let coord = VirtualListPlatformCoordinator()
    coord.install(on: makePlatformCollectionView())
    coord.apply(sections: [syntheticSection(count: 100_000)], animated: false)

    let clock = ContinuousClock()
    let elapsed = clock.measure {
      coord.apply(sections: [syntheticSection(count: 100_000)], animated: false)
    }
    XCTAssertLessThan(
      elapsed,
      .milliseconds(1),
      "redundant apply must be deduped; took \(elapsed)"
    )
  }

  /// `indexPath(forItemID:)` must not scale with item count. Budget 1 ms at
  /// N=100k — an accidental reintroduction of the full-snapshot copy would
  /// blow this by orders of magnitude.
  func test_gate_indexPathLookupDoesNotCopySnapshot() {
    let coord = VirtualListPlatformCoordinator()
    coord.install(on: makePlatformCollectionView())
    coord.apply(sections: [syntheticSection(count: 100_000)], animated: false)

    let clock = ContinuousClock()
    let elapsed = clock.measure {
      _ = coord.indexPath(forItemID: AnyHashable(50000))
    }
    XCTAssertLessThan(
      elapsed,
      .milliseconds(1),
      "indexPath lookup must be O(sections), not O(items); took \(elapsed)"
    )
  }

  /// `.indexed` path repeated lookups must be O(1) in steady state via the
  /// lazy reverse map. The first lookup is amortised O(N) (map build); all
  /// subsequent lookups — 1000 of them at N=100k — stay under 5 ms total
  /// (was ~1 s before the lazy map: each call did an O(N) linear scan).
  func test_gate_indexedRepeatedLookupsAreConstantTime() {
    let coord = VirtualListPlatformCoordinator()
    coord.setUpdatePolicy(.indexed)
    coord.install(on: makePlatformCollectionView())
    coord.apply(sections: [syntheticSection(count: 100_000)], animated: false)

    // Warm the lazy map so the measured loop is steady-state only.
    _ = coord.indexPath(forItemID: AnyHashable(0))

    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for _ in 0..<1000 {
        _ = coord.indexPath(forItemID: AnyHashable(50000))
      }
    }
    XCTAssertLessThan(
      elapsed,
      .milliseconds(5),
      ".indexed steady-state lookup must be O(1); 1000 lookups took \(elapsed)"
    )
  }

  /// Repeated install→apply→tearDown cycles must plateau in memory, not
  /// grow linearly. A leak in the closures held by the data source or
  /// environment-override chain would show up here.
  func test_gate_repeatedTeardownDoesNotLeak() {
    let iterations = 50
    let rowsPerIteration = 10000

    autoreleasepool {
      runInstallApplyTeardown(count: rowsPerIteration)
    }

    let before = residentMemoryBytes()
    for _ in 0..<iterations {
      autoreleasepool {
        runInstallApplyTeardown(count: rowsPerIteration)
      }
    }
    // Encourage the autorelease pool to drain before measuring.
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let after = residentMemoryBytes()

    let delta = after - before
    XCTAssertLessThan(
      delta,
      8 * 1024 * 1024,
      "RSS grew by \(delta) bytes over \(iterations) install→apply→teardown cycles; teardown is leaking"
    )
  }

  /// 100 sequential structurally-different `.indexed` applies must stay
  /// within the single-call gate's budget. Catches accumulation of
  /// fragmentation, cache misses, or cross-apply O(N²) state.
  func test_gate_sequentialAppliesDoNotDegrade() {
    let coord = VirtualListPlatformCoordinator()
    coord.setUpdatePolicy(.indexed)
    coord.configuration.fixedRowHeight = 44
    // AppKit's `insertRows` / `noteNumberOfRowsChanged` only hit the cell
    // reuse pool when the table is actually in a window — without one, each
    // sequential apply allocates fresh row views instead of recycling.
    // Mount the table in a real window so the measurement reflects the
    // production code path.
    let cv = makePlatformCollectionView()
    let window = makeBenchWindow(hosting: cv)
    coord.install(on: cv)

    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for i in 0..<100 {
        // Vary the count so fingerprint dedup doesn't short-circuit.
        coord.apply(
          sections: [syntheticSection(count: 900_000 + i)],
          animated: false
        )
      }
    }
    withExtendedLifetime(window) {}
    XCTAssertLessThan(
      elapsed,
      .seconds(2),
      "100 sequential .indexed applies of ~1M rows took \(elapsed); expected < 2s"
    )
  }

  #if canImport(UIKit)
    private func makeBenchWindow(hosting view: UICollectionView) -> UIWindow {
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
      view.frame = window.bounds
      window.addSubview(view)
      window.isHidden = false
      return window
    }
  #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
    private func makeBenchWindow(hosting view: NSTableView) -> NSWindow {
      let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
      scroll.documentView = view
      let window = NSWindow(
        contentRect: scroll.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false
      )
      window.contentView = scroll
      return window
    }
  #endif

  // MARK: Head-to-head gate

  /// Asserts `VirtualList` beats `SwiftUI.List` on per-update cost at
  /// N=100 000. The budget uses a conservative 2× margin — measured margin
  /// is 8–36× depending on platform, so hardware noise has no room to
  /// produce a false positive. A failure here means either our update path
  /// regressed or `SwiftUI.List` fixed its O(N) walk (worth noticing).
  func test_gate_updateAtLargeNBeatsSwiftUIList() {
    let count = 100_000
    let iterations = 10

    let listPerIter = measureSwiftUIListUpdatePerIteration(
      count: count,
      iterations: iterations
    )
    let virtualPerIter = measureVirtualListUpdatePerIteration(
      count: count,
      iterations: iterations
    )

    XCTAssertLessThan(
      virtualPerIter * 2,
      listPerIter,
      """
      VirtualList per-update at N=\(count) (\(virtualPerIter * 1000) ms) \
      failed to beat SwiftUI.List (\(listPerIter * 1000) ms) by 2× or \
      more. Either VirtualList regressed or SwiftUI.List improved.
      """
    )
  }

  private func measureSwiftUIListUpdatePerIteration(
    count: Int, iterations: Int
  ) -> Double {
    let store = UpdateHarnessStore(count: count)
    let view = UpdateHarnessListView(store: store)
    return measureUpdateIterations(
      view: view, store: store, count: count, iterations: iterations
    )
  }

  private func measureVirtualListUpdatePerIteration(
    count: Int, iterations: Int
  ) -> Double {
    let store = UpdateHarnessStore(count: count)
    let view = UpdateHarnessVirtualListView(store: store)
    return measureUpdateIterations(
      view: view, store: store, count: count, iterations: iterations
    )
  }

  private func measureUpdateIterations<V: View>(
    view: V, store: UpdateHarnessStore, count: Int, iterations: Int
  ) -> Double {
    let hostSize = CGSize(width: 375, height: 800)
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

    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for i in 0..<iterations {
        store.count = count + (i % 2)
        #if canImport(UIKit)
          host.view.layoutIfNeeded()
          CATransaction.flush()
        #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
          host.needsLayout = true
          host.layoutSubtreeIfNeeded()
        #endif
      }
    }
    #if canImport(UIKit)
      withExtendedLifetime(host) {}
      withExtendedLifetime(window) {}
    #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
      withExtendedLifetime(host) {}
      withExtendedLifetime(window) {}
    #endif

    let seconds = Double(elapsed.components.seconds) +
      Double(elapsed.components.attoseconds) / 1e18
    return seconds / Double(iterations)
  }

  // MARK: Helpers

  private func runInstallApplyTeardown(count: Int) {
    let cv = makePlatformCollectionView()
    let coord = VirtualListPlatformCoordinator()
    coord.install(on: cv)
    coord.apply(sections: [syntheticSection(count: count)], animated: false)
    coord.tearDown(collectionView: cv)
  }
}


/// Trend-tracking benchmarks. Use `measure { }` so Xcode captures a baseline
/// per run; read the numbers off by eye to spot drift. CI skips this suite
/// (`-skip-testing:VirtualListTests/VirtualListBenchmarks`) because its
/// relative standard deviation is too high for a reliable gate.
@MainActor
final class VirtualListBenchmarks: XCTestCase {
  func test_bench_apply_diffed_1k() {
    measure { runApply(policy: .diffed, count: 1000) }
  }

  func test_bench_apply_diffed_10k() {
    measure { runApply(policy: .diffed, count: 10000) }
  }

  func test_bench_apply_diffed_100k() {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 3
    measure(metrics: [XCTClockMetric()], options: opts) {
      runApply(policy: .diffed, count: 100_000)
    }
  }

  func test_bench_apply_indexed_1M() {
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
      runApply(policy: .indexed, count: 1_000_000)
    }
  }

  private func runApply(policy: VirtualListUpdatePolicy, count: Int) {
    let coord = VirtualListPlatformCoordinator()
    coord.setUpdatePolicy(policy)
    coord.install(on: makePlatformCollectionView())
    coord.apply(sections: [syntheticSection(count: count)], animated: false)
  }
}
