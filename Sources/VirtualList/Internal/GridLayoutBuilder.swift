#if canImport(UIKit)
  import UIKit

  /// Translates a `VirtualListGridColumns` spec into a `UICollectionViewCompositionalLayout`.
  ///
  /// The layout places cells in a horizontal group with the requested column sizes and
  /// stacks groups vertically with the caller-supplied row spacing. Section insets match
  /// the default `UICollectionLayoutListConfiguration` so swapping between list and grid
  /// doesn't visibly shift content.
  enum GridLayoutBuilder {
    static func make(columns: VirtualListGridColumns) -> UICollectionViewLayout {
      UICollectionViewCompositionalLayout { _, environment in
        let containerWidth = environment.container.effectiveContentSize.width
        let interItemSpacing = columns.spacing

        let items: [NSCollectionLayoutItem]
        let groupWidth: NSCollectionLayoutDimension

        switch columns.sizes.first {
        case .adaptive(let min, _)?:
          let columnCount = max(
            1, Int(floor((containerWidth + interItemSpacing) / (min + interItemSpacing))))
          items = Array(
            repeating: .init(
              layoutSize: .init(
                widthDimension: .fractionalWidth(1.0 / CGFloat(columnCount)),
                heightDimension: .estimated(44)
              )
            ), count: columnCount)
          groupWidth = .fractionalWidth(1.0)

        default:
          let totalFixed = columns.sizes.reduce(into: (fixed: CGFloat(0), flexibleCount: 0)) {
            acc, size in
            switch size {
            case .fixed(let value): acc.fixed += value
            case .flexible: acc.flexibleCount += 1
            case .adaptive: break
            }
          }
          let remaining = max(
            0,
            containerWidth - totalFixed.fixed - interItemSpacing * CGFloat(columns.sizes.count - 1))
          let flexibleShare =
            totalFixed.flexibleCount > 0
            ? remaining / CGFloat(totalFixed.flexibleCount)
            : 0
          items = columns.sizes.map { size in
            let width: NSCollectionLayoutDimension =
              switch size {
              case .fixed(let value):
                .absolute(value)
              case .flexible(let minimum, let maximum):
                .absolute(max(minimum, min(maximum, flexibleShare)))
              case .adaptive(let minimum, _):
                .absolute(minimum)
              }
            return NSCollectionLayoutItem(
              layoutSize: .init(widthDimension: width, heightDimension: .estimated(44))
            )
          }
          groupWidth = .fractionalWidth(1.0)
        }

        let group = NSCollectionLayoutGroup.horizontal(
          layoutSize: .init(widthDimension: groupWidth, heightDimension: .estimated(44)),
          subitems: items
        )
        group.interItemSpacing = .fixed(interItemSpacing)

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = columns.rowSpacing
        section.boundarySupplementaryItems = [
          .init(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
          ),
          .init(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
            elementKind: UICollectionView.elementKindSectionFooter,
            alignment: .bottom
          ),
        ]
        return section
      }
    }
  }
#endif
