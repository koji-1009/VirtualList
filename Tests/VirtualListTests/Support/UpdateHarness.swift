import SwiftUI

@testable import VirtualList

/// Shared harness types for tests / benchmarks that drive the same view tree
/// through successive structural updates. Flipping `count` by ±1 each tick is
/// the cheapest structural change that still exercises the full
/// `apply → insertItems/insertRows → reconfigure` pipeline.
@MainActor
final class UpdateHarnessStore: ObservableObject {
  @Published var count: Int
  init(count: Int) { self.count = count }
}

struct UpdateHarnessListView: View {
  @ObservedObject var store: UpdateHarnessStore
  var body: some View {
    List(0..<store.count, id: \.self) { index in
      Text("Row \(index)")
    }
  }
}

struct UpdateHarnessVirtualListView: View {
  @ObservedObject var store: UpdateHarnessStore
  var body: some View {
    VirtualList(itemCount: store.count, id: { $0 }) { index in
      Text("Row \(index)")
    }
    .virtualListUpdatePolicy(.indexed)
  }
}

// MARK: - Realistic / heavy row shapes

/// Settings-app-shaped row: leading SF Symbol, two stacked `Text` lines,
/// trailing caption. Representative of Mail, Messages, Settings, chat
/// channel lists — the mid-complexity shape that most real apps render.
struct RealisticRow: View {
  let index: Int
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "person.circle.fill")
        .foregroundStyle(.tint)
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text("User \(index)").font(.headline)
        Text("Subtitle line for row \(index)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text("\(index % 60)m")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
  }
}

/// Social-timeline-shaped row: avatar + metadata header, a 2-line body,
/// and a bottom action strip. Heavier than the settings shape — closer
/// to what X / Bluesky / Mastodon timeline cells render.
struct HeavyRow: View {
  let index: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Circle()
          .fill(.tint)
          .frame(width: 36, height: 36)
          .overlay(
            Text("\(index % 100)")
              .font(.caption)
              .foregroundStyle(.white)
          )
        VStack(alignment: .leading, spacing: 2) {
          Text("Name \(index)").font(.headline)
          Text("@handle\(index)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Text("2m").font(.caption).foregroundStyle(.tertiary)
      }
      Text(
        "Post body for row \(index). Multiple words to exercise the text "
          + "layout path for a realistic social-timeline cell."
      )
      .font(.body)
      .lineLimit(3)
      HStack(spacing: 16) {
        Label("\(index % 1000)", systemImage: "heart")
        Label("\(index % 500)", systemImage: "bubble.left")
        Label("Share", systemImage: "square.and.arrow.up")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }
}

// MARK: - Render views (init-path benchmarks)

struct ListRealisticView: View {
  let count: Int
  var body: some View {
    List(0..<count, id: \.self) { index in
      RealisticRow(index: index)
    }
    .listStyle(.plain)
  }
}

struct VirtualListRealisticView: View {
  let count: Int
  var body: some View {
    VirtualList(itemCount: count, id: { $0 }) { index in
      RealisticRow(index: index)
    }
    .virtualListStyle(.plain)
    .virtualListUpdatePolicy(.indexed)
  }
}

struct ListHeavyView: View {
  let count: Int
  var body: some View {
    List(0..<count, id: \.self) { index in
      HeavyRow(index: index)
    }
    .listStyle(.plain)
  }
}

struct VirtualListHeavyView: View {
  let count: Int
  var body: some View {
    VirtualList(itemCount: count, id: { $0 }) { index in
      HeavyRow(index: index)
    }
    .virtualListStyle(.plain)
    .virtualListUpdatePolicy(.indexed)
  }
}

// MARK: - Update views (flip-path benchmarks)

struct RealisticUpdateListView: View {
  @ObservedObject var store: UpdateHarnessStore
  var body: some View {
    List(0..<store.count, id: \.self) { index in
      RealisticRow(index: index)
    }
    .listStyle(.plain)
  }
}

struct RealisticUpdateVirtualListView: View {
  @ObservedObject var store: UpdateHarnessStore
  var body: some View {
    VirtualList(itemCount: store.count, id: { $0 }) { index in
      RealisticRow(index: index)
    }
    .virtualListStyle(.plain)
    .virtualListUpdatePolicy(.indexed)
  }
}

struct HeavyUpdateListView: View {
  @ObservedObject var store: UpdateHarnessStore
  var body: some View {
    List(0..<store.count, id: \.self) { index in
      HeavyRow(index: index)
    }
    .listStyle(.plain)
  }
}

struct HeavyUpdateVirtualListView: View {
  @ObservedObject var store: UpdateHarnessStore
  var body: some View {
    VirtualList(itemCount: store.count, id: { $0 }) { index in
      HeavyRow(index: index)
    }
    .virtualListStyle(.plain)
    .virtualListUpdatePolicy(.indexed)
  }
}
