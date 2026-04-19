import SwiftUI

/// Result builder that collects `VirtualListSection`s from a declarative block.
///
/// Accepts either `VirtualSection` or a single bare `VirtualItems`. A bare
/// `VirtualItems` is lifted into a synthetic single-section list using a stable
/// sentinel ID, so the section's identity doesn't change between SwiftUI
/// re-renders (an unstable ID would force the data source to discard and rebuild
/// everything on every render).
///
/// If you need more than one group, wrap each in `VirtualSection` with an
/// explicit id.
@resultBuilder
public enum VirtualListBuilder {
  public static func buildBlock(_ components: [VirtualListSection]...) -> [VirtualListSection] {
    components.flatMap { $0 }
  }

  public static func buildExpression(_ section: VirtualSection) -> [VirtualListSection] {
    [section.build()]
  }

  public static func buildExpression(_ items: VirtualItems) -> [VirtualListSection] {
    [items.buildAsSection(id: AnyHashable(DefaultSectionID.default))]
  }

  public static func buildArray(_ components: [[VirtualListSection]]) -> [VirtualListSection] {
    components.flatMap { $0 }
  }

  public static func buildOptional(
    _ component: [VirtualListSection]?
  ) -> [VirtualListSection] {
    component ?? []
  }

  public static func buildEither(
    first component: [VirtualListSection]
  ) -> [VirtualListSection] {
    component
  }

  public static func buildEither(
    second component: [VirtualListSection]
  ) -> [VirtualListSection] {
    component
  }
}
