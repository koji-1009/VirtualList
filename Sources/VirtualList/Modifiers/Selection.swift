import SwiftUI

/// Type-erased container for the caller's selection binding.
///
/// The enum carries the fully-typed binding; the outer surface projects
/// between it and the `Set<AnyHashable>` shape the data source operates on.
/// Struct (not class) so each re-render's modifier chain doesn't heap-allocate
/// a new box. Only the read/write methods are main-actor-isolated — the
/// initializers are nonisolated so the modifier extension (which SwiftUI
/// invokes during body evaluation) can construct the box from any context.
struct VirtualListSelectionBox<ID: Hashable>: VirtualListSelectionBoxProtocol {
  enum Source {
    case single(Binding<ID?>)
    case multiple(Binding<Set<ID>>)
  }

  let source: Source

  init(single binding: Binding<ID?>) {
    source = .single(binding)
  }

  init(multiple binding: Binding<Set<ID>>) {
    source = .multiple(binding)
  }

  var allowsSelection: Bool {
    true
  }

  var allowsMultipleSelection: Bool {
    if case .multiple = source { return true }
    return false
  }

  @MainActor
  func read() -> Set<AnyHashable> {
    switch source {
    case .single(let binding):
      binding.wrappedValue.map { [AnyHashable($0)] } ?? []
    case .multiple(let binding):
      Set(binding.wrappedValue.map(AnyHashable.init))
    }
  }

  @MainActor
  func write(_ selection: Set<AnyHashable>) {
    switch source {
    case .single(let binding):
      let newValue = selection.first.flatMap { $0.base as? ID }
      if binding.wrappedValue != newValue {
        binding.wrappedValue = newValue
      }
    case .multiple(let binding):
      let newValue = Set(selection.compactMap { $0.base as? ID })
      if binding.wrappedValue != newValue {
        binding.wrappedValue = newValue
      }
    }
  }
}

extension VirtualList {
  /// Binds the list's single-selection state to a SwiftUI binding.
  public func virtualListSelection(_ selection: Binding<(some Hashable)?>) -> VirtualList {
    var copy = self
    copy.configuration.selectionBox = VirtualListSelectionBox(single: selection)
    return copy
  }

  /// Binds the list's multi-selection state to a SwiftUI binding.
  public func virtualListSelection(_ selection: Binding<Set<some Hashable>>) -> VirtualList {
    var copy = self
    copy.configuration.selectionBox = VirtualListSelectionBox(multiple: selection)
    return copy
  }
}
