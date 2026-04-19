# VirtualList

A high-performance SwiftUI list that scales to millions of rows by wrapping `UICollectionView` + `UICollectionViewDiffableDataSource` behind a SwiftUI-idiomatic API.

`SwiftUI.List` shows a measurable performance gap that widens with N, concentrated on the structural-update path — the Performance numbers below put `VirtualList` roughly 5× faster at 100k-row updates on iOS and around 14× faster at 100k-row updates on macOS, medianed over 30 iterations. Initial-render gaps are smaller and shape-dependent (up to ~4× on iOS Array-of-Identifiable at 100k, closer to 1-1.5× on the Range fast path Apple already optimises).

Individual sample iterations swing much further — `SwiftUI.List`'s cold-start costs have a heavy tail — so any single-run ratio should be read as "this order of magnitude" rather than a fixed number; rerun the harness on your own hardware before committing.

`VirtualList` exposes an index-based builder modeled after `UICollectionView`, `RecyclerView`, `SliverList`, and `LazyColumn` so both the initial render and subsequent updates stay O(1) / O(visible), and an `s/List/VirtualList/g` migration compiles unchanged.

---

## Quick start

```swift
import VirtualList

// Collection-based (drop-in replacement for List)
VirtualList(users) { user in
    UserRow(user: user)
}

// Index-based (for very large datasets)
VirtualList(itemCount: 1_000_000, id: { $0 }) { index in
    Row(index: index)
}

// Result-builder with multiple sections
VirtualList {
    VirtualSection(id: "favourites", header: { Text("Favourites") }) {
        VirtualItems(favourites, id: \.id) { item in
            FavRow(item: item)
        }
    }
    VirtualSection(id: "everything") {
        VirtualItems(items, id: \.id) { item in
            Row(item: item)
        }
    }
}
.virtualListStyle(.insetGrouped)
```

---

## Installation

Swift Package Manager:

```swift
.package(url: "https://example.com/VirtualList.git", from: "1.0.0")
```

Add `VirtualList` to any target's `dependencies`.

### Platform support

Latest three generations in each family:

| Platform | Minimum | Backing |
|----------|---------|---------|
| iOS 17+ | iOS 17, 18, 26 | `UICollectionView` + `UICollectionViewDiffableDataSource` + `UIHostingConfiguration` |
| iPadOS 17+ | same as iOS | same as iOS |
| macCatalyst 17+ | same as iOS | same as iOS |
| macOS 14+ | macOS 14, 15, 26 | `NSTableView` + custom `HostingTableCellView` (NSHostingView) |

`VirtualList` conforms to `UIViewRepresentable` on iOS/Catalyst and `NSViewRepresentable` on native macOS. The cross-platform parts of the API (`virtualListStyle`, `virtualListUpdatePolicy`, `virtualListSelection`, `virtualListReorder`, `virtualListColumns`, `virtualListEnvironment*`, `virtualListFocusCoordinator`) work on both. Two modifiers are UIKit-only and not exposed on macOS:

- `virtualListSwipeActions` (AppKit lists don't have swipe gestures — use a context menu instead)
- `virtualListRefreshable` (AppKit has no pull-to-refresh)

---

## API overview

### Initializers

| Form | Use when |
|------|----------|
| `VirtualList(_ data, id:) { element in ... }` | You already have a collection of model values. |
| `VirtualList(_ data) { element in ... }` where element is `Identifiable` | Same, when your element has `.id`. |
| `VirtualList(itemCount:, id:) { index in ... }` | You have a very large or synthetic dataset and want to avoid walking it. |
| `VirtualList { VirtualSection(...) ... }` | Multiple sections, with optional headers and footers. |

### Modifiers

| Modifier | Purpose |
|----------|---------|
| `.virtualListStyle(_:)` | `.plain` / `.grouped` / `.insetGrouped` / `.sidebar` / `.sidebarPlain` |
| `.virtualListUpdatePolicy(_:)` | `.diffed` (default, animated) or `.indexed` (O(1) apply, no diff animation). |
| `.virtualListRowHeight(_:)` | Force a fixed row height (skips self-sizing). |
| `.virtualListRowSeparators(_:)` | Toggle row separators. |
| `.virtualListSelection(_:)` | Single (`Binding<ID?>`) or multi (`Binding<Set<ID>>`) selection. |
| `.virtualListSwipeActions(edge:actions:)` | Attach leading/trailing swipe actions. |
| `.virtualListReorder(_:)` | Drag-and-drop reordering. |
| `.virtualListRefreshable(_:)` | Pull-to-refresh. |
| `.virtualListColumns(_:)` | Grid layout with fixed / flexible / adaptive columns. |
| `.virtualListEnvironment(_:_:)` | Forward a custom `EnvironmentKey` into hosted rows. |
| `.virtualListEnvironmentObject(_:)` | Forward an `ObservableObject` into hosted rows. |

### Drop-in `List` compatibility

`VirtualList` accepts the unprefixed `SwiftUI.List` modifier names, so an
`s/List/VirtualList/g` migration compiles unchanged. Swift's method lookup
picks the `VirtualList` (or, for per-row modifiers, `VirtualListRow`) version
over `SwiftUI.View`'s, so the list-aware implementation wins.

List-level aliases:

| Modifier | Platform | Behaviour |
|----------|----------|-----------|
| `.listStyle(_:)` | iOS + macOS | Forwards to `.virtualListStyle(_:)` |
| `.listRowSeparator(_:edges:)` (list-level) | iOS + macOS | Forwards to `.virtualListRowSeparators(_:)` |
| `.onMove(perform:)` | iOS + macOS | Forwards to `.virtualListReorder(_:)` |
| `.onDelete(perform:)` | iOS + macOS | iOS: default destructive trailing-swipe action. macOS: ⌫ key on the selected row(s). Fires the handler with an `IndexSet` per affected section, matching SwiftUI's `ForEach.onDelete` semantics. Only runs when no per-row or list-level swipe action outranks it. |
| `.scrollContentBackground(_:)` | iOS + macOS | iOS: `collectionView.backgroundColor`. macOS: `NSScrollView.drawsBackground` + `.windowBackgroundColor`. `.visible` paints the platform background; `.hidden` / `.automatic` keeps it clear. |
| `.refreshable(action:)` | iOS only | Forwards to `.virtualListRefreshable(_:)`. Calling on macOS is a compile error (AppKit has no pull-to-refresh gesture). |
| `.scrollDismissesKeyboard(_:)` | iOS only | Maps to `UIScrollView.keyboardDismissMode`. Calling on macOS is a compile error (no on-screen keyboard). |
| `\.editMode` environment | iOS only | Mirrors into `collectionView.isEditing` via `.environment(\.editMode, $binding)` or an ancestor `EditButton`. |

Per-row modifiers (iOS + macOS except where noted):

| Modifier | Platform | Behaviour |
|----------|----------|-----------|
| `.listRowBackground(_:)` | iOS + macOS | iOS: `UIBackgroundConfiguration.customView`, edge-to-edge. macOS: `NSHostingView` behind the cell's content. |
| `.listRowInsets(_:)` | iOS + macOS | iOS: `UIHostingConfiguration.margins`. macOS: padding on the hosted view inside the table cell. |
| `.listRowSeparator(_:edges:)` (per-row) | iOS + macOS | iOS: `UICollectionLayoutListConfiguration.itemSeparatorHandler`. macOS: per-row hair-line subviews (top / bottom) drawn at backing-scale thickness. |
| `.badge(_:)` | iOS + macOS | iOS: trailing `UICellAccessory.customView`. macOS: trailing `NSHostingView` pinned to the padded content frame. All four SwiftUI overloads — `Int`, `Text?`, `LocalizedStringKey?`, `StringProtocol?` — are supported. |
| `.swipeActions { VirtualListSwipeAction(...) }` | iOS only | Leading or trailing swipe actions; wins over list-level swipe actions. Calling on macOS is a compile error. |

#### Important: per-row modifiers require a `VirtualListRow` receiver

SwiftUI.List reads modifiers like `.listRowBackground` through **private `PreferenceKey`s** that only framework-internal code can see, so third-party packages cannot observe them on a bare `View`. `VirtualList` works around this with a dispatch trick — a protocol extension on `VirtualListRow` that the Swift compiler picks over `SwiftUI.View`'s version for any receiver whose static type conforms to `VirtualListRow`.

The practical consequence: **the row you apply `.listRowBackground` / `.listRowInsets` / `.listRowSeparator` / `.swipeActions` / `.badge` to must conform to `VirtualListRow`**, otherwise the call falls through to SwiftUI's version, which is a silent no-op inside `VirtualList`.

Two adoption paths:

```swift
// (1) inline — wrap the content in VirtualListRowContainer
VirtualList(items) { item in
  VirtualListRowContainer {
    Label(item.title, systemImage: item.icon)
  }
  .listRowBackground(Color.blue.opacity(0.15))
  .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
  .listRowSeparator(.hidden)
  .badge(item.unread)
  #if canImport(UIKit)
    .swipeActions {
      VirtualListSwipeAction(title: "Delete", style: .destructive) { _ in ... }
    }
  #endif
}
.onDelete { indexSet in ... }

// (2) bespoke row type — conform it to VirtualListRow directly
struct InboxRow: VirtualListRow {
  let message: Message
  var body: some View {
    Label(message.subject, systemImage: message.icon)
  }
}

VirtualList(messages) { InboxRow(message: $0) }
```

Rows that never use any per-row modifier pay nothing — the backing box and its callback closures are only allocated the first time a row-level modifier's `.onAppear` fires on a given IndexPath.

### Focus

SwiftUI's `@FocusState` is unreliable across reused cells. `VirtualList` provides `VirtualListFocusCoordinator<ID>`, a published-ID store that rehydrates focus state from value-type identity instead:

```swift
@StateObject var focus = VirtualListFocusCoordinator<Row.ID>()

VirtualList(rows) { row in
    TextField("...", text: binding(for: row.id))
        .virtualListFocused(focus, id: row.id)
}
.virtualListFocusCoordinator(focus)  // enables auto-scroll on focus(id:)

focus.focus(id: rows[0].id)          // focuses AND scrolls
focus.currentID = rows[0].id          // focuses without scrolling
```

Without `.virtualListFocusCoordinator(_:)`, focus still synchronises for rows that are already on screen, but `focus(id:)` has no visible effect for off-screen rows. Attaching the coordinator wires up auto-scrolling so programmatic focus always brings the target row into view.

---

## Performance

Measured against `SwiftUI.List`, same data, same host. iOS numbers come from an iPhone 17e simulator (iOS 26.3); macOS numbers from a native M-series build. `VirtualList` is configured with `.virtualListUpdatePolicy(.indexed)`.

**Methodology**: 30 iterations per test after a discarded warm-up invocation. `SwiftUI.List`'s cold-host costs have a heavy-tailed distribution (single-iteration measurements span roughly 30 ms to 300+ ms on the same hardware because JIT / font-descriptor / diffable-data-source cold paths land unpredictably), so the arithmetic mean is noticeably skewed by a handful of outliers. The tables below report **median** over the 30 kept samples, which is the robust central-tendency number for this kind of distribution. `sd` is relative standard deviation of the raw sample list, kept in the table to flag how much per-iteration spread sits behind each cell. Debug build unless otherwise noted.

Per-run variance is real — rerun the harness on your own hardware before committing to any specific ratio. The orderings (which engine wins, and by how many ×) are stable across runs; the absolute ms values are not.

**Initial render** (cold host attached to a real window + body + layout, median ms):

| N              | Platform | `List` (sd)     | `VirtualList` (sd)  | Winner          |
|----------------|----------|----------------:|--------------------:|:----------------|
| 1k range       | iOS      | 17.7 (sd 5%)    | **15.2 (sd 3%)**    | VL 1.2×         |
| 10k range      | iOS      | 18.2 (sd 10%)   | **14.9 (sd 2%)**    | VL 1.2×         |
| 100k range     | iOS      | 23.2 (sd 4%)    | **18.8 (sd 25%)**   | VL 1.2×         |
| 10k collection | iOS      | 30.9 (sd 54%)   | **14.5 (sd 13%)**   | **VL 2.1×**     |
| 100k collection| iOS      | 61.3 (sd 119%)  | **14.0 (sd 2%)**    | **VL 4.4×**     |
| 1k range       | macOS    | 18.7 (sd 9%)    | **18.6 (sd 6%)**    | VL 1.0×         |
| 10k range      | macOS    | 20.3 (sd 11%)   | **18.2 (sd 8%)**    | VL 1.1×         |
| 100k range     | macOS    | 27.9 (sd 7%)    | **17.8 (sd 7%)**    | **VL 1.6×**     |
| 10k collection | macOS    | 17.3 (sd 4%)    | **16.5 (sd 5%)**    | VL 1.0×         |
| 100k collection| macOS    | 22.5 (sd 6%)    | **16.2 (sd 5%)**    | **VL 1.4×**     |

`SwiftUI.List` has a Range fast path (iOS range-initialised lists skip per-element identity walk, which keeps the Range rows roughly flat rather than scaling with N), but the Array-of-Identifiable variant (the realistic call site) still scales with N. `VirtualList` stays flat at ~14 ms on iOS / ~17 ms on macOS regardless of shape or N.

The iOS `List` collection rows show large SD (54 % at 10k, 119 % at 100k) because the cold-host cost is skewed — a handful of the 30 iterations cost several × the typical one, which is why median and mean diverge on those cells. Median is the robust number; mean is inflated by the tail. `VirtualList` SD stays mostly under ~15 % (one iOS Range cell shows ~40 % on cold-small-N runs); the update-path cells are tight at ~1-10 %.

**Per-update** (structural change — single item added/removed, median ms per flip):

| N    | Platform | `List` (sd)    | `VirtualList` (sd) | Winner           |
|------|----------|---------------:|-------------------:|:-----------------|
| 10k  | iOS      | 2.38 (sd 4%)   | **2.14 (sd 6%)**   | VL 1.1×          |
| 10k  | macOS    | 3.80 (sd 1%)   | **1.71 (sd 1%)**   | **VL 2.2×**      |
| 100k | iOS      | 12.27 (sd 4%)  | **2.23 (sd 9%)**   | **VL 5.5×**      |
| 100k | macOS    | 23.53 (sd 1%)  | **1.70 (sd 1%)**   | **VL 13.8×**     |

The pattern:

- **Initial render**: `VirtualList` is flat regardless of N (~14 ms on iOS, ~17 ms on macOS); `SwiftUI.List` scales with N for anything but the Range fast path.
- **Update**: `VirtualList` routes tail-shape changes through `insertRows`/`removeRows` on macOS and `insertItems`/`deleteItems` on iOS so each apply is O(visible) regardless of N. `SwiftUI.List` walks every row's identity on each update and scales with N.
- **`.indexed` + `animated: true`** is honoured: surgical inserts and deletes animate; only a full structural change (reorder, section shuffle) falls back to `reloadData`.
- **`.indexed` lookup** (e.g. binding-driven selection on a 1M-row list) amortises to O(1) via a lazy reverse map: the first lookup after an apply builds the map in O(N); subsequent lookups are constant-time until the next apply.

**Release vs Debug** — the Debug numbers above are not a compilation-mode artefact. Both engines' hot paths live in system frameworks (`UICollectionView`, `UICollectionViewDiffableDataSource`, SwiftUI's hosting machinery) that ship pre-optimised regardless of the user target's configuration. A Release-build iOS measurement produces effectively the same ratios — `VirtualList` itself stays within ±2 % between Debug and Release, so the tables above are a faithful stand-in for production behaviour.

Head-to-head harness at `Tests/VirtualListTests/ListVsVirtualListBenchmarks.swift`; run locally with `swift test --filter ListVsVirtualListBenchmarks` (CI skips it because hosting cost varies with hardware). Parser script at `benchmark/parse_bench.swift` extracts per-test median / average / min / max / SD from an `xcodebuild test` or `swift test` log.

Separate from the comparison, the library asserts its own absolute O(1) budgets as CI gates (see _Test architecture_ below). A PR that breaks any of them broke a publicly-committed complexity claim.

### Test architecture

Three layers, separated so CI has a stable signal:

| Layer | Framework | Purpose | CI role |
|-------|-----------|---------|---------|
| Functional | Swift Testing | Behaviour / API | gating |
| Performance gates | `XCTAssertLessThan` + `ContinuousClock` | Guard O(1) / bounded claims with absolute budgets | gating |
| Trend benchmarks | `XCTestCase.measure` | Observe cost over time | manual |

The gate layer is what catches complexity regressions. The file lives at `Tests/VirtualListTests/PerformanceTests.swift` and asserts:

- `.indexed` apply of 1M rows completes in < 10 ms — any slower means an accidental item-count walk was reintroduced
- Redundant apply (same `(id, itemCount)` fingerprint) completes in < 1 ms — the snapshot dedup is intact
- `indexPath(forItemID:)` at N=100k completes in < 1 ms — no full-snapshot copy
- `cellBuildCount` after a single layout is bounded (< 50) regardless of item count — the visible window, not `N`, drives cell configuration

These are *absolute* assertions, not baseline-relative. A PR that makes any of them fail broke a publicly-committed complexity claim.

Trend benchmarks live in the same file but in `VirtualListBenchmarks`. They use `measure {}` for visual inspection in Xcode. CI skips them (`-skip-testing` in the workflow) because their relative-SD is too high to be a reliable gate.

### Running

```sh
# macOS: functional tests only (gates and benchmarks are UIKit-gated)
swift test

# iOS: everything except trend benchmarks
xcodebuild test \
  -scheme VirtualList \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skip-testing:VirtualListTests/VirtualListBenchmarks

# Trend benchmarks only (run manually, then read the numbers in Xcode)
xcodebuild test \
  -scheme VirtualList \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:VirtualListTests/VirtualListBenchmarks
```

The GitHub Actions workflow in `.github/workflows/ci.yml` runs the suite against a matrix of Xcode / iOS-simulator combinations on every push and pull request. Apple-side comparison ("is this faster than SwiftUI.List?") is *not* in CI — that depends on Apple's implementation and drifts between iOS releases; use the `List vs VirtualList` screen in the demo app and Xcode's memory gauge when you need to make that call visually.

### What isn't automated

Dynamic Type is covered by `AccessibilityTests/cellHeightRespondsToDynamicTypeTrait()`. Two concerns need a manual pass:

- **VoiceOver** — `UIHostingConfiguration` builds its accessibility tree lazily, only when VoiceOver or Accessibility Inspector is active. Verify by walking a few rows under Accessibility Inspector.
- **iPad hardware-keyboard navigation** — `UIKeyCommand` is not reachable from `XCTestCase`. Verify on an iPad simulator with Connect Hardware Keyboard enabled (⌘K).

### Update policies

`VirtualList` lets you pick between two data-source strategies:

- **`.diffed` (default)** — backed by `UICollectionViewDiffableDataSource`. Gives you automatic insert / delete / move animations, but every apply walks the full item count to build a snapshot. Cost and memory are O(N).
- **`.indexed`** — backed by a classic `UICollectionViewDataSource` that serves `numberOfItemsInSection` straight from the stored count. Apply is O(1) and no per-row identifiers are allocated, so opening a 1-million-row page is essentially free. The trade-off is that reloads go through `reloadData`
  instead of diff animations; in-place inserts and deletes look abrupt.

Pick `.indexed` for huge or synthetic lists that don't need animated updates:

```swift
VirtualList(itemCount: 1_000_000, id: { $0 }) { index in Row(index: index) }
    .virtualListUpdatePolicy(.indexed)
```

---

## Environment forwarding

Trait-backed environment values (`colorScheme`, `layoutDirection`, `dynamicTypeSize`, `displayScale`, …) propagate into cells automatically via `UITraitCollection`, so `VirtualList` does **not** re-apply them — doing so would wrap every row in a stack of `AnyView(... .environment(...))` calls on a hot path without buying anything the trait chain doesn't already deliver.

Values that SwiftUI cannot deliver through traits — parent `.font`, `.disabled`, custom `EnvironmentKey`s, `ObservableObject`s — need an explicit forward:

```swift
VirtualList(...)
    .virtualListEnvironment(\.myCustomValue, value)
    .virtualListEnvironmentObject(myStore)
```

---

## Caveats

- **Cross-cell `matchedGeometryEffect`.** UIKit/AppKit own cell lifecycle, so the SwiftUI transition system cannot see views that live in different cells. Callers that need cross-cell animations drive them with explicit snapshot crossfades on top of the list.
- **macOS style parity.** The macOS backing (`NSTableView`) renders as a plain list regardless of the `VirtualListStyle` picked. AppKit has no list-style analogue to UIKit's `.plain` / `.insetGrouped` / `.sidebar` appearance, so the enum is there for cross-platform source parity and currently only differentiates on iOS.
- **macOS grid.** `.virtualListColumns(_:)` is iOS-only. The table-backed macOS path does not provide a grid layout; callers that need a grid on macOS compose `LazyVGrid` inside a `ScrollView`.

---

## Examples

A gallery of example screens ships inside the demo app at `Examples/VirtualListDemo/VirtualListDemo/Examples/`:

- `HugeListExample` — one million rows
- `DropInListExample` — `List`-compatible replacement
- `SectionedExample` — headers, footers, result builder
- `SelectionExample` — single and multi-selection
- `SwipeActionsExample` — leading / trailing swipe actions
- `ReorderExample` — drag-and-drop reorder
- `RefreshExample` — pull-to-refresh
- `GridExample` — adaptive grid layout
- `FocusExample` — programmatic focus across reused cells
- `EnvironmentExample` — custom environment and environment objects
- `ExamplesGallery` — the navigation view that ties them all together

Each example is a small SwiftUI `View` next to `VirtualListDemoApp.swift`, so they double as idiomatic usage snippets — read one file to see the full integration for a given feature.

### Running the demo app

A ready-to-run SwiftUI demo app lives at `Examples/VirtualListDemo/VirtualListDemo.xcodeproj`. The project references this package as a local Swift Package dependency, so no other setup is needed:

```sh
open Examples/VirtualListDemo/VirtualListDemo.xcodeproj
```

Then pick an iOS Simulator and run. Swift Package Manager cannot produce a runnable iOS app bundle on its own, so the demo is distributed as a small companion Xcode project — this is the same convention that Kingfisher, TCA, and Alamofire use for their example apps.

If you prefer to build the demo from the command line:

```sh
cd Examples/VirtualListDemo
xcodebuild \
  -project VirtualListDemo.xcodeproj \
  -scheme VirtualListDemo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Creating your own host app

If you'd rather start a new demo target from scratch, add `VirtualList` as a Swift Package dependency of any SwiftUI iOS app and copy any example file from `Examples/VirtualListDemo/VirtualListDemo/Examples/` into your own target. A three-step walkthrough in Xcode:

1. **File › New › Project… › iOS › App** — SwiftUI lifecycle, iOS 16 deployment target.
2. **File › Add Package Dependencies…** — click _Add Local…_, select this repo's root; tick **VirtualList**.
3. Copy one of the example `.swift` files into your app target and use it from `ContentView`.

---

## License

MIT.
