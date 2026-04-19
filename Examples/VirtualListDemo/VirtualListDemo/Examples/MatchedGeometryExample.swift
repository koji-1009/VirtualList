import SwiftUI
import VirtualList

/// Structurally-equivalent side-by-side probe for
/// `.matchedGeometryEffect(id:in:)` across a cell boundary, on both
/// `SwiftUI.List` and `VirtualList`.
///
/// The earlier revision of this example had a bottom-edge rendering
/// asymmetry (different separator / row padding between the two
/// engines), which contaminated the visual comparison: the circle was
/// animated correctly in both, but the surrounding chrome drifted
/// the eye and gave an incorrect impression of "broken". This revision
/// pins the row chrome on both sides:
///
/// - No separators (`.listRowSeparator(.hidden)` / `virtualListRowSeparators(false)`)
/// - No background (`.listRowBackground(Color.clear)` — VL has no
///   platform background by default)
/// - Identical row insets zeroed out, explicit padding inside the row
///   content only
/// - Identical plain list style
///
/// With the chrome neutralised, the only visual difference during the
/// matched-geometry transition is the matched-view rendering itself
/// — which is what we actually want to compare.
public struct MatchedGeometryExample: View {
  enum Backend: String, CaseIterable, Identifiable {
    case list
    case virtualList
    var id: Self { self }
    var label: String { self == .list ? "SwiftUI.List" : "VirtualList" }
  }

  @State private var backend: Backend = .list
  @State private var selected: Int?
  @Namespace private var ns

  // Small count so the list ends inside the viewport on both iPhone
  // portrait and macOS window sizes — any trailing-chrome divergence
  // between engines is visible rather than scrolled off.
  private let items = Array(0..<6)

  public init() {}

  public var body: some View {
    ZStack {
      VStack(spacing: 0) {
        Picker("Backend", selection: $backend) {
          ForEach(Backend.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding()

        content
          .id(backend)
      }

      if let sel = selected {
        overlay(for: sel)
          .transition(.opacity)
      }
    }
    .navigationTitle("Matched Geometry")
    #if canImport(UIKit)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  @ViewBuilder
  private var content: some View {
    // No `.clipped()` / `.frame(maxHeight:)` — let both engines fill
    // the viewport. The whole point is to see whether the list's
    // bottom edge (the area below the last row) actually matches
    // between List and VirtualList, so hiding it defeats the probe.
    // No `.listSectionSeparator(.hidden)` / `.scrollContentBackground(.hidden)`
    // either: those were workarounds used before VirtualList's default
    // background and default separator style were aligned with List.
    switch backend {
    case .list:
      List(items, id: \.self) { i in
        row(i)
          .listRowInsets(EdgeInsets())
      }
      .listStyle(.plain)
    case .virtualList:
      VirtualList(itemCount: items.count, id: { items[$0] }) { idx in
        VirtualListRowContainer { row(items[idx]) }
          .listRowInsets(EdgeInsets())
      }
      .virtualListStyle(.plain)
    }
  }

  /// Row content is self-contained: it sets its own padding and
  /// frame so the List / VirtualList chrome does not influence
  /// size or inset. Whatever renders around this view is noise.
  @ViewBuilder
  private func row(_ i: Int) -> some View {
    HStack(spacing: 16) {
      Circle()
        .fill(tint(for: i))
        .frame(width: 44, height: 44)
        .matchedGeometryEffect(
          id: i,
          in: ns,
          isSource: selected != i
        )
      Text("Row \(i)").font(.body)
      Spacer()
      Image(systemName: "chevron.right")
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(height: 68, alignment: .center)
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.45)) {
        selected = i
      }
    }
  }

  @ViewBuilder
  private func overlay(for id: Int) -> some View {
    ZStack {
      Color.black.opacity(0.5)
        .ignoresSafeArea()
        .onTapGesture {
          withAnimation(.easeInOut(duration: 0.45)) {
            selected = nil
          }
        }
      VStack(spacing: 20) {
        Circle()
          .fill(tint(for: id))
          .frame(width: 220, height: 220)
          .matchedGeometryEffect(
            id: id,
            in: ns,
            isSource: selected == id
          )
        Text("Detail \(id)")
          .font(.largeTitle)
          .foregroundStyle(.white)
      }
    }
  }

  private func tint(for i: Int) -> Color {
    Color(
      hue: Double(i % 12) / 12.0,
      saturation: 0.75,
      brightness: 0.9
    )
  }
}

#Preview {
  NavigationStack {
    MatchedGeometryExample()
  }
}
