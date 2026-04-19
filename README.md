# VirtualList

High-performance SwiftUI list. Drop-in replacement for `SwiftUI.List`, backed by `UICollectionView` (iOS) and `NSTableView` (macOS) via `UIViewRepresentable` / `NSViewRepresentable`. An `s/List/VirtualList/g` migration compiles unchanged.

The win is on **update**: structural insert / remove runs in O(visible) through `insertItems` / `insertRows` rather than walking the full item list. The init-path story varies by platform — see the tables below.

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
| iOS / iPadOS / macCatalyst 17+ | iOS 17, 18, 26 | `UICollectionView` + `UICollectionViewDiffableDataSource` + `UIHostingConfiguration` |
| macOS 14+ | macOS 14, 15, 26 | `NSTableView` + `NSHostingView` |

---

## Performance

30-iter averages vs `SwiftUI.List`, same data, same host, Debug build. iOS numbers from iPhone 17e simulator (iOS 26.3); macOS numbers from a native M-series build. Single-run absolutes drift — the ratios are stable, the ms values are not. Harness at `Tests/VirtualListTests/ListVsVirtualListBenchmarks.swift`.

**Initial render (Range shape, ms):**

| N      | iOS `List` | iOS `VirtualList` | iOS ratio | macOS `List` | macOS `VirtualList` | macOS ratio |
|-------:|-----------:|------------------:|:----------|-------------:|--------------------:|:------------|
|    10  |       10.2 |           **8.8** | VL 1.2×   |         12.0 |                13.0 | L 1.1×      |
|    20  |       13.4 |          **12.8** | VL 1.05×  |         14.0 |                15.0 | L 1.1×      |
|    50  |       13.3 |          **12.7** | VL 1.05×  |         19.0 |                20.0 | tied        |
|   100  |       13.3 |          **12.4** | VL 1.07×  |         19.0 |                19.0 | tied        |
|   500  |       13.5 |          **12.7** | VL 1.06×  |         21.0 |            **20.0** | VL 1.05×    |
|    1k  |       17.7 |          **15.2** | VL 1.2×   |         18.7 |                18.6 | tied        |
|   10k  |       18.2 |          **14.9** | VL 1.2×   |         20.3 |            **18.2** | VL 1.1×     |
|  100k  |       23.2 |          **18.8** | VL 1.2×   |         27.9 |            **17.8** | VL 1.6×     |

**Initial render (Array-of-Identifiable, ms):**

| N      | iOS `List` | iOS `VirtualList` | iOS ratio | macOS `List` | macOS `VirtualList` | macOS ratio |
|-------:|-----------:|------------------:|:----------|-------------:|--------------------:|:------------|
|    1k  |          — |                 — | —         |         19.0 |            **17.0** | VL 1.1×     |
|   10k  |       30.9 |          **14.5** | VL 2.1×   |         17.3 |                16.5 | tied        |
|  100k  |       61.3 |          **14.0** | VL 4.4×   |         22.5 |            **16.2** | VL 1.4×     |

**Per-update (single-item flip, ms per flip):**

| N      | iOS `List` | iOS `VirtualList` | iOS ratio | macOS `List` | macOS `VirtualList` | macOS ratio |
|-------:|-----------:|------------------:|:----------|-------------:|--------------------:|:------------|
|   10k  |       2.38 |          **2.14** | VL 1.1×   |         9.40 |            **4.20** | VL 2.2×     |
|  100k  |      12.27 |          **2.23** | VL 5.5×   |        23.50 |            **1.70** | VL 13.9×    |

**Reading the tables:**

- **iOS**: `VirtualList` is faster across the board, including at N=10. `SwiftUI.List` on iOS is itself a `UICollectionView` wrapper with diff-machinery overhead that VL's direct path avoids.
- **macOS**, short lists (N ≤ 50): `SwiftUI.List` is faster or tied. `VirtualList`'s `NSTableView` cold-start costs a few ms that `SwiftUI.List`'s native path avoids. Use `SwiftUI.List` for short static lists on macOS.
- **macOS**, medium-to-large lists (N ≥ ~500): `VirtualList` pulls ahead on init, and the update path wins decisively from at least N=10k.
- `VirtualList`'s cost stays flat in N (~14 ms iOS, ~18 ms macOS); `SwiftUI.List` scales on the Array-of-Identifiable and update paths.

Closing the macOS short-list gap is future work — the current `NSTableView` backing adds startup overhead that a hand-rolled AppKit backing could avoid. Not yet implemented.

Separately, the library enforces absolute O(1) / O(visible) budgets as CI gates (`Tests/VirtualListTests/PerformanceTests.swift`). A PR that breaks any of them broke a publicly-committed complexity claim.

---

## Drop-in compatibility

`VirtualList` accepts every `SwiftUI.List` modifier via protocol dispatch — `.listStyle`, `.onMove`, `.onDelete`, `.refreshable` (iOS), `.scrollContentBackground`, `.scrollDismissesKeyboard` (iOS), `\.editMode` (iOS). Per-row modifiers dispatch through the `VirtualListRow` protocol so Swift's method lookup prefers the list-aware implementation over `SwiftUI.View`'s: `.listRowBackground`, `.listRowInsets`, `.listRowSeparator`, `.badge`, `.swipeActions` (iOS), `.contextMenu`, `.listItemTint`.

### `VirtualListRow` conformance

Per-row modifiers require the row's **static type** to conform to `VirtualListRow`. Otherwise the call falls through to `SwiftUI.View`'s version, which is a silent no-op inside a `VirtualList`. Two adoption paths:

```swift
// (1) inline — wrap the content in VirtualListRowContainer
VirtualList(items) { item in
  VirtualListRowContainer {
    Label(item.title, systemImage: item.icon)
  }
  .listRowBackground(Color.blue.opacity(0.15))
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
  var body: some View { Label(message.subject, systemImage: message.icon) }
}
VirtualList(messages) { InboxRow(message: $0) }
```

Rows that never use a row-level modifier pay nothing — the backing box and its callback closures are only allocated the first time a per-row modifier's `.onAppear` fires on a given IndexPath.

### Not supported

- `.listItemTint(ListItemTint?)` — use `.listItemTint(VirtualListItemTint)` with `.fixed(_:)` / `.preferred(_:)` / `.monochrome`. `SwiftUI.ListItemTint` is opaque; passing it to `VirtualList` is a compile error rather than a silent no-op.
- `.swipeActions` on macOS — AppKit has no swipe gesture; use `.contextMenu` instead. Compile error on macOS rather than silent no-op.
- `.refreshable` / `.scrollDismissesKeyboard` on macOS — no pull-to-refresh / no soft keyboard. Compile error.
- Cross-cell `matchedGeometryEffect` — cells live in UIKit/AppKit, outside the SwiftUI transition system. Drive cross-cell animation with an explicit snapshot crossfade on top of the list.
- `.virtualListColumns` on macOS — `NSTableView` has no grid layout. Use `LazyVGrid` inside a `ScrollView`.
- macOS `virtualListStyle(.grouped/.insetGrouped/.sidebar)` — AppKit has no list-style analogue; accepted for cross-platform source parity and rendered as `.plain` on macOS.

---

## Focus across reused cells

`@FocusState` rehydrates unreliably across cell reuse. `VirtualListFocusCoordinator<ID>` pins focus to value-type identity:

```swift
@StateObject var focus = VirtualListFocusCoordinator<Row.ID>()

VirtualList(rows) { row in
    TextField("...", text: binding(for: row.id))
        .virtualListFocused(focus, id: row.id)
}
.virtualListFocusCoordinator(focus)  // enables auto-scroll on focus(id:)

focus.focus(id: rows[0].id)          // focuses AND scrolls
focus.currentID = rows[0].id         // focuses without scrolling
```

Without `.virtualListFocusCoordinator(_:)`, focus still synchronises for rows that are already on screen, but `focus(id:)` has no visible effect for off-screen rows.

---

## Update policies

- **`.diffed` (default)** — backed by `UICollectionViewDiffableDataSource`. Gives automatic insert / delete / move animations; every apply walks the full item count to build a snapshot (O(N)).
- **`.indexed`** — classic `UICollectionViewDataSource`; `numberOfItemsInSection` comes straight from the stored count. Apply is O(1), no per-row identifier allocation, so opening a 1M-row page is essentially free. Reloads go through `reloadData` instead of diff animations; surgical `insert` / `delete` on tail-shape changes still animate via `insertItems` / `removeRows`.

```swift
VirtualList(itemCount: 1_000_000, id: { $0 }) { Row(index: $0) }
  .virtualListUpdatePolicy(.indexed)
```

---

## Environment forwarding

Trait-backed environment values (`colorScheme`, `layoutDirection`, `dynamicTypeSize`, `displayScale`) propagate into cells automatically via `UITraitCollection`, so `VirtualList` does not re-apply them. Values SwiftUI cannot deliver through traits (parent `.font`, `.disabled`, custom `EnvironmentKey`s, `ObservableObject`s) need an explicit forward:

```swift
VirtualList(...)
    .virtualListEnvironment(\.myCustomValue, value)
    .virtualListEnvironmentObject(myStore)
```

---

## Running

```sh
# macOS target — functional tests + gates
swift test

# iOS — everything except trend benchmarks
xcodebuild test -scheme VirtualList \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skip-testing:VirtualListTests/VirtualListBenchmarks

# Head-to-head benchmarks (not in CI — hosting cost is hardware-dependent)
xcodebuild test -scheme VirtualList \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:VirtualListTests/ListVsVirtualListBenchmarks
```

CI (`.github/workflows/ci.yml`) runs functional + gates on every push across an Xcode / simulator matrix.

### Manual coverage

- **VoiceOver** — `UIHostingConfiguration` builds its accessibility tree lazily (only when VoiceOver or Accessibility Inspector is active). Verify by walking a few rows under Accessibility Inspector.
- **iPad hardware keyboard** — `UIKeyCommand` is not reachable from `XCTestCase`. Verify on an iPad simulator with Connect Hardware Keyboard enabled (⌘K).

---

## Examples

Ready-to-run SwiftUI demo at `Examples/VirtualListDemo/VirtualListDemo.xcodeproj`. Each example under `Examples/VirtualListDemo/VirtualListDemo/Examples/` is a small SwiftUI `View` — read one file to see the full integration for a given feature (huge lists, drop-in `List`, sections, selection, swipe actions, reorder, refresh, grid, focus, environment forwarding).

```sh
open Examples/VirtualListDemo/VirtualListDemo.xcodeproj
```

---

## License

MIT.
