import Foundation

/// Sentinel section identifier assigned when a list has no caller-supplied
/// section ID. Two such sections inside one builder block collide at apply
/// time — signal to disambiguate with `VirtualSection`.
enum DefaultSectionID: Hashable {
  case `default`
}
