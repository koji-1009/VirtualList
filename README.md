# VirtualList

A high-performance SwiftUI list that scales to millions of rows by wrapping `UICollectionView` + `UICollectionViewDiffableDataSource` behind a SwiftUI-idiomatic API.

At large N, `SwiftUI.List`'s update path scales with the item count — each data change forces an O(N) identity walk before the collection view sees any diff. `VirtualList` exposes an index-based builder modeled after `UICollectionView`, `RecyclerView`, `SliverList`, and `LazyColumn` so both the initial render and subsequent updates stay O(1) / O(visible). The gap is measured rather than asserted — see _Performance_ below.

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

`VirtualList` conforms to `UIViewRepresentable` on iOS/Catalyst and `NSViewRepresentable` on native macOS. The cross-platform parts of the API (`virtualListStyle`, `virtualListUpdatePolicy`, `virtualListSelection`,
`virtualListReorder`, `virtualListColumns`, `virtualListEnvironment*`, `virtualListFocusCoordinator`) work on both. Two modifiers are UIKit-only and not exposed on macOS:

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

### Drop-in `List` compatibility (iOS)

`VirtualList` also accepts the unprefixed `SwiftUI.List` modifier names, so an
`s/List/VirtualList/g` migration compiles unchanged. Swift's method lookup
picks the `VirtualList` (or, for per-row modifiers, `VirtualListRow`) version
over `SwiftUI.View`'s, so the list-aware implementation wins.

List-level aliases:

| Modifier | Forwards to |
|----------|-------------|
| `.listStyle(_:)` | `.virtualListStyle(_:)` |
| `.listRowSeparator(_:edges:)` (list-level) | `.virtualListRowSeparators(_:)` |
| `.refreshable(action:)` | `.virtualListRefreshable(_:)` |
| `.onMove(perform:)` | `.virtualListReorder(_:)` |
| `.onDelete(perform:)` | Default destructive trailing-swipe action (only when no per-row or list-level swipe action is set) |
| `.scrollContentBackground(_:)` | `collectionView.backgroundColor` — `.visible` paints `.systemBackground`; `.hidden` / `.automatic` keeps it clear |
| `.scrollDismissesKeyboard(_:)` | `collectionView.keyboardDismissMode` (`.immediately` → `.onDrag`, `.interactively` → `.interactive`, `.never` → `.none`) |
| `\.editMode` environment | `collectionView.isEditing` (via `.environment(\.editMode, $binding)` or an ancestor `EditButton`) |

Per-row modifiers — written on a row that conforms to `VirtualListRow` (the
inline wrapper is `VirtualListRowContainer`):

| Modifier | Behaviour |
|----------|-----------|
| `.listRowBackground(_:)` | `UIBackgroundConfiguration.customView`, edge-to-edge across the cell |
| `.listRowInsets(_:)` | `UIHostingConfiguration.margins` |
| `.listRowSeparator(_:edges:)` (per-row) | `UICollectionLayoutListConfiguration.itemSeparatorHandler` |
| `.swipeActions { VirtualListSwipeAction(...) }` | Leading or trailing swipe actions, wins over list-level |
| `.badge(_:)` | Trailing `UICellAccessory.customView` (all four SwiftUI overloads — `Int`, `Text?`, `LocalizedStringKey?`, `StringProtocol?`) |

```swift
VirtualList(items) { item in
  VirtualListRowContainer {
    Label(item.title, systemImage: item.icon)
  }
  .listRowBackground(Color.blue.opacity(0.15))
  .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
  .listRowSeparator(.hidden)
  .badge(item.unread)
  .swipeActions {
    VirtualListSwipeAction(title: "Delete", style: .destructive) { ... }
  }
}
.onDelete { indexSet in ... }
```

Callers who author their own row type conform it directly to `VirtualListRow`
instead of wrapping in `VirtualListRowContainer`; the modifier set is the
same.

Rows that never use any per-row modifier pay nothing — the
`VirtualListRowBoxProvider` injected into the environment is a lightweight
struct, and the backing box + its callback closures are only allocated the
first time a row-level modifier's `.onAppear` fires on a given IndexPath.

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

**Methodology**: 10 iterations per test, preceded by one warm-up invocation whose result is discarded so SwiftUI's first-invocation cold-path costs (JIT, font-descriptor lookups, internal state init) don't inflate the first measured iteration. `avg` is the arithmetic mean over the ten kept runs; `sd` is relative standard deviation. Debug build unless otherwise noted.

**Initial render** (cold host attached to a real window + body + layout, ms):

| N    | Platform |     `List` |     `VirtualList` | Winner |
|------|----------|-----------:|------------------:|:------:|
| 1k range       | iOS   |  27.5 (sd 22%) | **14.2 (sd 3%)** | **VL 1.9×** |
| 10k range      | iOS   |  28.4 (sd 36%) | **14.1 (sd 3%)** | **VL 2.0×** |
| 100k range     | iOS   |  26.9 (sd 12%) | **13.5 (sd 1%)** | **VL 2.0×** |
| 10k collection | iOS   |  67.4 (sd 23%) | **13.5 (sd 3%)** | **VL 5.0×** |
| 100k collection| iOS   | 197.4 (sd 80%) | **13.9 (sd 4%)** | **VL 14.2×** |
| 10k range      | macOS |  24.0 (sd 4%)  | **21.7 (sd 14%)** | VL 1.1× |
| 100k range     | macOS |  38.2 (sd 28%) | **20.1 (sd 21%)** | **VL 1.9×** |
| 100k collection| macOS |  82.4 (sd 11%) | **18.9 (sd 13%)** | **VL 4.4×** |

`SwiftUI.List` has a Range fast path (iOS range-initialised at N=100k runs only 27 ms — it skips per-element identity walk) but the Array-of-Identifiable variant (the realistic call site) scales with N into the hundreds of milliseconds. `VirtualList` stays flat at ~14 ms on iOS / ~20 ms on macOS regardless of shape or N.

The `List` SD column is routinely large (22 %-80 %) because SwiftUI decides what to precompute on each cold host differently; a single outlier iteration of 500 ms against nine iterations of 43 ms produces both the high average and the high SD. `VirtualList` is deterministic — SD typically under 5 %.

**Per-update** (structural change — single item added/removed, ms per flip):

| N    | Platform |    `List` |    `VirtualList` | Winner |
|------|----------|----------:|-----------------:|:------:|
| 10k  | iOS      |  2.81 (sd 9%)  | **2.23 (sd 10%)** | **VL 1.3×** |
| 10k  | macOS    |  4.53 (sd 27%) | **0.71 (sd 3%)**  | **VL 6.4×** |
| 100k | iOS      | 13.35 (sd 6%)  | **2.49 (sd 28%)** | **VL 5.4×** |
| 100k | macOS    | 26.39 (sd 5%)  | **0.77 (sd 8%)**  | **VL 34×**  |

The pattern:

- **Initial render**: `VirtualList` is flat regardless of N (~14 ms on iOS, ~20 ms on macOS); `SwiftUI.List` scales with N for anything but the Range fast path.
- **Update**: `VirtualList` routes tail-shape changes through `insertRows`/`removeRows` on macOS and `insertItems`/`deleteItems` on iOS so each apply is O(visible) regardless of N. `SwiftUI.List` walks every row's identity on each update and scales with N.
- **`.indexed` + `animated: true`** is honoured: surgical inserts and deletes animate; only a full structural change (reorder, section shuffle) falls back to `reloadData`.
- **`.indexed` lookup** (e.g. binding-driven selection on a 1M-row list) amortises to O(1) via a lazy reverse map: the first lookup after an apply builds the map in O(N); subsequent lookups are constant-time until the next apply.

**Release vs Debug** — the Debug numbers above are not a compilation-mode artefact. Both engines' hot paths live in system frameworks (`UICollectionView`, `UICollectionViewDiffableDataSource`, SwiftUI's hosting machinery) that ship pre-optimised regardless of the user target's configuration. A Release-build iOS measurement produces effectively the same ratios — `VirtualList` itself stays within ±2 % between Debug and Release, so the tables above are a faithful stand-in for production behaviour.

Head-to-head harness at `Tests/VirtualListTests/ListVsVirtualListBenchmarks.swift`; run locally with `swift test --filter ListVsVirtualListBenchmarks` (CI skips it because hosting cost varies with hardware). Parser script at `benchmark/parse_bench.swift` extracts per-test averages (plus min / max / SD) from an `xcodebuild test` or `swift test` log.

Separate from the comparison, the library asserts its own absolute O(1) budgets as CI gates (see _Test architecture_ below). A PR that breaks any of them broke a publicly-committed complexity claim.

### Test architecture

Three layers, separated so CI has a stable signal:

| Layer | Framework | Purpose | CI role |
|-------|-----------|---------|---------|
| Functional | Swift Testing | Behaviour / API | gating |
| Performance gates | `XCTAssertLessThan` + `ContinuousClock` | Guard O(1) / bounded claims with absolute budgets | gating |
| Trend benchmarks | `XCTestCase.measure` | Observe cost over time | manual |

The gate layer is what catches complexity regressions. The file lives at
`Tests/VirtualListTests/PerformanceTests.swift` and asserts:

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

**Dynamic Type** is automated — `AccessibilityTests/cellHeightRespondsToDynamicTypeTrait()` asserts that self-sizing cells grow when `preferredContentSizeCategory` is boosted on the hosting window. Two remaining concerns still need a manual pass because their runtime surface depends on services that the simulator under `xcodebuild test` never activates:

- **VoiceOver**. `UIHostingConfiguration` builds its accessibility element tree lazily — it is only materialised when VoiceOver or Accessibility Inspector is actively walking the hierarchy, so a bare XCTest host never sees populated labels. Verify by running the demo app under Accessibility Inspector / VoiceOver and walking a few rows. `XCUITest` with a VoiceOver-enabled launch environment would automate this, but the project currently ships XCTest only.
- **iPad hardware-keyboard navigation**. `UIKeyCommand` dispatch is not reachable from `XCTestCase`; confirming arrow-key selection and tab-focus order needs an `XCUIApplication` session that types through `XCUIRemote` / keyboard input. Verify by running the demo on an iPad simulator with a hardware keyboard attached (Connect Hardware Keyboard, Command-K toggles).

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

Trait-backed environment values (`colorScheme`, `layoutDirection`, `dynamicTypeSize`, `displayScale`, …) propagate into cells automatically via
`UITraitCollection`, so `VirtualList` does **not** re-apply them — doing so would wrap every row in a stack of `AnyView(... .environment(...))` calls on a hot path without buying anything the trait chain doesn't already deliver.

Values that SwiftUI cannot deliver through traits — parent `.font`, `.disabled`, custom `EnvironmentKey`s, `ObservableObject`s — need an explicit
forward:

```swift
VirtualList(...)
    .virtualListEnvironment(\.myCustomValue, value)
    .virtualListEnvironmentObject(myStore)
```

`SwiftUI.List` re-forwards every environment value regardless of whether the receiving subtree reads it; `VirtualList` asks you to be explicit about values that cross the hosting boundary, and in exchange every cell configuration skips ~10 `AnyView` allocations on the hot path.

---

## Caveats

- **Cross-cell `matchedGeometryEffect`.** UIKit/AppKit own cell lifecycle, so the SwiftUI transition system cannot see views that live in different cells. Callers that need cross-cell animations drive them with explicit snapshot crossfades on top of the list.
- **macOS style parity.** The macOS backing (`NSTableView`) renders as a plain list regardless of the `VirtualListStyle` picked. AppKit has no list-style analogue to UIKit's `.plain` / `.insetGrouped` / `.sidebar` appearance, so the enum is there for cross-platform source parity and currently only differentiates on iOS.
- **macOS grid.** `.virtualListColumns(_:)` is iOS-only. The table-backed macOS path does not provide a grid layout; callers that need a grid on macOS compose `LazyVGrid` inside a `ScrollView`.

---

## Examples

A gallery of example screens ships inside the demo app at
`Examples/VirtualListDemo/VirtualListDemo/Examples/`:

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

Each example is a small SwiftUI `View` next to `VirtualListDemoApp.swift`, so they double as idiomatic usage snippets — read one file to see the full
integration for a given feature.

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

If you'd rather start a new demo target from scratch, add `VirtualList` as a
Swift Package dependency of any SwiftUI iOS app and copy any example file from
`Examples/VirtualListDemo/VirtualListDemo/Examples/` into your own target. A
three-step walkthrough in Xcode:

1. **File › New › Project… › iOS › App** — SwiftUI lifecycle, iOS 16 deployment target.
2. **File › Add Package Dependencies…** — click _Add Local…_, select this repo's root; tick **VirtualList**.
3. Copy one of the example `.swift` files into your app target and use it from `ContentView`.

---

## License

MIT.
