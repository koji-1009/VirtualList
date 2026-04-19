import CoreGraphics
import SwiftUI
import VirtualList

/// Side-by-side comparison between SwiftUI's `List` and `VirtualList` rendering the
/// same synthetic dataset.
///
/// With **Light** rows the difference is subtle because SwiftUI.List has its own
/// lazy path for `Range`-backed data. Flip **Weight** to **Heavy** and every
/// row instantiates a fresh, deterministically-coloured 64×64 bitmap via
/// `CGContext`. At that point the arithmetic flips: `VirtualList` only builds
/// the visible window, while `List` is still walking identity for every row.
/// At 100k / 1M rows the `List × Heavy` combination hammers memory hard enough
/// to make the point obvious in Xcode's memory gauge.
public struct ListComparisonExample: View {
  enum Backend: String, CaseIterable, Identifiable {
    case list
    case virtualList
    var id: Self { self }
    var label: String { self == .list ? "List" : "VirtualList" }
  }

  enum Count: Int, CaseIterable, Identifiable {
    case k1 = 1000
    case k10 = 10000
    case k100 = 100_000
    case m1 = 1_000_000
    var id: Self { self }
    var label: String {
      switch self {
      case .k1: "1k"
      case .k10: "10k"
      case .k100: "100k"
      case .m1: "1M"
      }
    }
  }

  enum Weight: String, CaseIterable, Identifiable {
    case light
    case heavy
    var id: Self { self }
    var label: String { rawValue.capitalized }
  }

  @State private var backend: Backend = .list
  @State private var count: Count = .k10
  @State private var weight: Weight = .light

  public init() {}

  public var body: some View {
    content
      .safeAreaInset(edge: .top, spacing: 0) { controls }
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle("\(backend.label) · \(count.label) · \(weight.label)")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
  }

  // MARK: Controls

  private var controls: some View {
    VStack(spacing: 10) {
      Picker("Backend", selection: $backend) {
        ForEach(Backend.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)

      Picker("Count", selection: $count) {
        ForEach(Count.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)

      Picker("Weight", selection: $weight) {
        ForEach(Weight.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)

      if let warning = warningMessage {
        Text(warning)
          .font(.caption)
          .foregroundStyle(.orange)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
    .background(.regularMaterial)
  }

  private var warningMessage: String? {
    switch (backend, count, weight) {
    case (.list, .m1, _):
      "1M rows in SwiftUI.List may hang the main thread for several seconds."
    case (.list, .k100, .heavy), (.list, .m1, .heavy):
      "Heavy rows at this size may allocate several GB and OOM-kill the app."
    default:
      nil
    }
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    // Rebuild the identity of the backend subtree whenever the configuration
    // changes so every switch feels like a cold open — that's what the memory
    // gauge should reflect.
    switch backend {
    case .list:
      standardList.id("list-\(count.rawValue)-\(weight.rawValue)")
    case .virtualList:
      virtualList.id("virtual-\(count.rawValue)-\(weight.rawValue)")
    }
  }

  private var standardList: some View {
    List(0..<count.rawValue, id: \.self) { index in
      row(index: index)
    }
    .listStyle(.plain)
  }

  private var virtualList: some View {
    VirtualList(itemCount: count.rawValue, id: { $0 }) { index in
      row(index: index)
    }
    .virtualListStyle(.plain)
    .virtualListUpdatePolicy(.indexed)
  }

  // MARK: Rows

  @ViewBuilder
  private func row(index: Int) -> some View {
    switch weight {
    case .light: lightRow(index: index)
    case .heavy: heavyRow(index: index)
    }
  }

  private func lightRow(index: Int) -> some View {
    HStack {
      Text("#\(index)")
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(.secondary)
      Text("Row \(index) – \(Self.suffix(for: index))")
      Spacer()
    }
  }

  private func heavyRow(index: Int) -> some View {
    HStack(spacing: 12) {
      if let thumb = Self.thumbnail(for: index) {
        Image(decorative: thumb, scale: 1)
          .resizable()
          .frame(width: 64, height: 64)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Item \(index)").font(.headline)
        Text("Unique 64×64 bitmap")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "chevron.right")
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
  }

  // MARK: Row helpers

  private static func suffix(for index: Int) -> String {
    ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"][index % 6]
  }

  /// Deterministic per-index 64×64 gradient bitmap. Intentionally *not*
  /// cached: each call allocates a fresh `CGContext` so the backend
  /// difference lands in the memory gauge. 64×64 × 4 bytes ≈ 16 KB per row
  /// — innocuous for a few thousand rows, devastating at 100k / 1M.
  ///
  /// Uses `CGContext` + `CGImage` directly (no `UIImage` /
  /// `UIGraphicsImageRenderer`) so the same code path runs on macOS as
  /// on iOS.
  private static func thumbnail(for index: Int) -> CGImage? {
    let side = 64
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: nil,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side * 4,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    else { return nil }

    let (r1, g1, b1) = hsbToRGB(
      hue: CGFloat((index &* 2_654_435_761) & 0xFF) / 255.0,
      saturation: 0.75,
      brightness: 0.95
    )
    let (r2, g2, b2) = hsbToRGB(
      hue: CGFloat(((index &* 2_654_435_761) & 0xFF) + 46) / 255.0,
      saturation: 0.9,
      brightness: 0.7
    )
    let colors = [
      CGColor(red: r1, green: g1, blue: b1, alpha: 1),
      CGColor(red: r2, green: g2, blue: b2, alpha: 1),
    ]
    guard let gradient = CGGradient(
      colorsSpace: space,
      colors: colors as CFArray,
      locations: [0, 1]
    )
    else { return nil }
    ctx.drawLinearGradient(
      gradient,
      start: .zero,
      end: CGPoint(x: side, y: side),
      options: []
    )
    return ctx.makeImage()
  }

  /// Cross-platform HSB → RGB conversion so the thumbnail generator
  /// doesn't depend on `UIColor` / `NSColor`.
  private static func hsbToRGB(
    hue: CGFloat,
    saturation s: CGFloat,
    brightness v: CGFloat
  ) -> (CGFloat, CGFloat, CGFloat) {
    let h = hue.truncatingRemainder(dividingBy: 1) * 6
    let c = v * s
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    let (r, g, b): (CGFloat, CGFloat, CGFloat)
    switch h {
    case ..<1: (r, g, b) = (c, x, 0)
    case ..<2: (r, g, b) = (x, c, 0)
    case ..<3: (r, g, b) = (0, c, x)
    case ..<4: (r, g, b) = (0, x, c)
    case ..<5: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return (r + m, g + m, b + m)
  }
}

#Preview {
  NavigationStack {
    ListComparisonExample()
  }
}
