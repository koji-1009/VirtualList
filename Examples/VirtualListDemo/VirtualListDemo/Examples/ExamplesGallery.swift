import SwiftUI

/// Top-level gallery view that ties every example screen together.
public struct ExamplesGallery: View {
  public init() {}

  public var body: some View {
    NavigationStack {
      List {
        Section("Data shapes") {
          NavigationLink("Huge list (1M rows)") { HugeListExample() }
          NavigationLink("Drop-in List replacement") { DropInListExample() }
          NavigationLink("Sections with headers") { SectionedExample() }
        }
        Section("Interactions") {
          NavigationLink("Selection") { SelectionExample() }
          NavigationLink("Reorder") { ReorderExample() }
          #if canImport(UIKit)
            NavigationLink("Swipe actions") { SwipeActionsExample() }
            NavigationLink("Pull-to-refresh") { RefreshExample() }
          #endif
        }
        Section("Layout") {
          NavigationLink("Grid") { GridExample() }
        }
        Section("Advanced") {
          NavigationLink("Focus coordinator") { FocusExample() }
          NavigationLink("Environment forwarding") { EnvironmentExample() }
        }
        Section("Performance") {
          NavigationLink("List vs VirtualList") { ListComparisonExample() }
        }
      }
      .navigationTitle("VirtualList")
    }
  }
}

#Preview {
  ExamplesGallery()
}
