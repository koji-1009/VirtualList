import SwiftUI
import VirtualList

/// Forwarding a custom environment value and environment object into cells.
///
/// `UIHostingConfiguration` doesn't see SwiftUI environment values attached on the
/// parent host, so `.virtualListEnvironment(_:_:)` bridges them explicitly.
public struct EnvironmentExample: View {
  public final class Theme: ObservableObject {
    @Published public var accent: Color = .accentColor
    public init() {}
  }

  @StateObject private var theme = Theme()
  @State private var emphasis: Bool = false

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      Form {
        Picker("Accent", selection: $theme.accent) {
          Text("Accent").tag(Color.accentColor)
          Text("Purple").tag(Color.purple)
          Text("Green").tag(Color.green)
        }
        Toggle("Emphasis", isOn: $emphasis)
      }
      .frame(height: 120)

      VirtualList(itemCount: 40, id: { $0 }) { index in
        Cell(index: index)
      }
      .virtualListEnvironmentObject(theme)
      .virtualListEnvironment(\.emphasis, emphasis)
    }
    .ignoresSafeArea(edges: .bottom)
  }

  private struct Cell: View {
    @EnvironmentObject var theme: Theme
    @Environment(\.emphasis) var emphasis

    let index: Int

    var body: some View {
      HStack {
        Circle().fill(theme.accent).frame(width: 20, height: 20)
        Text("Row \(index)")
          .fontWeight(emphasis ? .bold : .regular)
      }
    }
  }
}

private struct EmphasisKey: EnvironmentKey {
  static let defaultValue: Bool = false
}

extension EnvironmentValues {
  var emphasis: Bool {
    get { self[EmphasisKey.self] }
    set { self[EmphasisKey.self] = newValue }
  }
}

#Preview("Environment") {
  EnvironmentExample()
}
