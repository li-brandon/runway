import SwiftUI
import Testing
import UIKit

@testable import Runway

struct TextScalingTests {
  @Test("Text never shrinks below the readable floor")
  func minimumFactorKeepsTextReadable() {
    #expect(TextScaling.minimumFactor >= 0.7)
  }
}

struct RemainingAmountStyleTests {
  @Test("Ordinary amounts keep the full size and existing shrink steps")
  func ordinaryAmountsAreUnchanged() {
    #expect(RemainingAmountStyle.steps.first == .scaled(1))
    #expect(
      Array(RemainingAmountStyle.steps.prefix(3)) == [
        .scaled(1),
        .scaled(0.85),
        .scaled(TextScaling.minimumFactor),
      ]
    )
    #expect(RemainingAmountStyle.maximumSize == 96)
  }

  @Test("The amount is limited to one line")
  func amountNeverWraps() {
    #expect(RemainingAmountStyle.lineLimit == 1)
  }

  @Test("Fallbacks go from largest to smallest at every Dynamic Type size")
  @MainActor
  func fallbacksGetSmaller() throws {
    let categories: [UIContentSizeCategory] = [
      .extraSmall,
      .large,
      .extraExtraExtraLarge,
      .accessibilityMedium,
      .accessibilityExtraExtraExtraLarge,
    ]
    for category in categories {
      let traits = UITraitCollection(preferredContentSizeCategory: category)
      let sizes = try RemainingAmountStyle.steps.map { try pointSize(of: $0, traits: traits) }
      for (larger, smaller) in zip(sizes, sizes.dropFirst()) {
        #expect(larger > smaller, "\(category.rawValue): \(sizes)")
      }
      let lastResort = try pointSize(of: RemainingAmountStyle.lastResort, traits: traits)
      #expect(try #require(sizes.last) >= lastResort, "\(category.rawValue)")
    }
  }

  @MainActor
  private func pointSize(
    of style: RemainingAmountStyle,
    traits: UITraitCollection
  ) throws -> CGFloat {
    switch style {
    case .scaled(let factor):
      // Matches the amount's @ScaledMetric in ContentView.
      let scaled = UIFontMetrics(forTextStyle: .largeTitle)
        .scaledValue(for: 80, compatibleWith: traits)
      return min(scaled, RemainingAmountStyle.maximumSize) * factor
    case .textStyle(let textStyle):
      let textStyles: [Font.TextStyle: UIFont.TextStyle] = [
        .title: .title1,
        .title3: .title3,
        .headline: .headline,
      ]
      let uiTextStyle = try #require(textStyles[textStyle])
      return UIFont.preferredFont(forTextStyle: uiTextStyle, compatibleWith: traits).pointSize
    }
  }
}
