import Foundation
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

struct AmountStyleTests {
  @Test("Ordinary amounts keep the full size and existing shrink steps")
  func ordinaryAmountsAreUnchanged() {
    #expect(AmountStyle.heroSteps.first == .scaled(1))
    #expect(
      Array(AmountStyle.heroSteps.prefix(3)) == [
        .scaled(1),
        .scaled(0.85),
        .scaled(TextScaling.minimumFactor),
      ]
    )
    #expect(AmountStyle.maximumSize == 96)
  }

  @Test("The amount is limited to one line")
  func amountNeverWraps() {
    #expect(AmountStyle.lineLimit == 1)
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
      for steps in [AmountStyle.heroSteps, AmountStyle.summarySteps, AmountStyle.rowSteps] {
        let sizes = try steps.map { try pointSize(of: $0, traits: traits) }
        for (larger, smaller) in zip(sizes, sizes.dropFirst()) {
          #expect(larger > smaller, "\(category.rawValue): \(sizes)")
        }
      }
    }
  }

  @Test("The last fallback at the import maximum is abbreviated, with no ellipsis")
  @MainActor
  func importMaximumEndsAbbreviated() throws {
    for cents in [DataImport.maximumMagnitudeCents, -DataImport.maximumMagnitudeCents] {
      for steps in [AmountStyle.heroSteps, AmountStyle.summarySteps, AmountStyle.rowSteps] {
        let view = AmountText(cents: cents, steps: steps, locale: Money.fixedLocale)
        let abbreviated = cents < 0 ? "-$100B" : "$100B"
        let full = cents < 0 ? "-$100,000,000,000.00" : "$100,000,000,000.00"
        let smallest = try #require(steps.last)
        #expect(view.candidates.count == steps.count + 1)
        #expect(view.candidates.dropLast().allSatisfy { $0.text == full })
        #expect(view.candidates.last == AmountCandidate(style: smallest, text: abbreviated))
        #expect(view.candidates.allSatisfy { !$0.text.contains("…") })
        let chosen = AmountCandidate.selected(from: view.candidates) { _ in false }
        #expect(chosen?.text == abbreviated)
        #expect(view.accessibilityText == full)
      }
    }
  }

  @Test("The import maximum abbreviates only when the full amount can't fit a narrow phone")
  @MainActor
  func importMaximumSelection() throws {
    // The screenshot device's 375pt width, less Today's horizontal padding.
    let width: CGFloat = 343
    let largest = UITraitCollection(
      preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
    )
    let standard = UITraitCollection(preferredContentSizeCategory: .large)
    for steps in [AmountStyle.heroSteps, AmountStyle.summarySteps, AmountStyle.rowSteps] {
      let candidates = AmountCandidate.candidates(
        cents: DataImport.maximumMagnitudeCents,
        steps: steps,
        locale: Money.fixedLocale
      )
      let atLargest = try selection(from: candidates, width: width, traits: largest)
      let atStandard = try selection(from: candidates, width: width, traits: standard)
      #expect(atLargest?.text == "$100B")
      #expect(atStandard?.text == "$100,000,000,000.00")
    }
  }

  @Test("Ordinary amounts have no abbreviated candidate, and every candidate is distinct")
  func ordinaryAmountsStayFull() {
    let candidates = AmountCandidate.candidates(
      cents: 1_234,
      steps: AmountStyle.heroSteps,
      locale: Money.fixedLocale
    )
    #expect(candidates.count == AmountStyle.heroSteps.count)
    #expect(candidates.allSatisfy { $0.text == "$12.34" })
    #expect(Set(candidates).count == candidates.count)
  }

  @Test("Fallbacks keep the first candidate that fits")
  func selectsFirstThatFits() {
    let candidates = AmountCandidate.candidates(
      cents: DataImport.maximumMagnitudeCents,
      steps: AmountStyle.rowSteps,
      locale: Money.fixedLocale
    )
    let chosen = AmountCandidate.selected(from: candidates) { _ in true }
    #expect(chosen == candidates.first)
    let none = AmountCandidate.selected(from: []) { _ in true }
    #expect(none == nil)
  }

  /// Measures with the system bold font, close enough to each step's font at these widths.
  @MainActor
  private func selection(
    from candidates: [AmountCandidate],
    width: CGFloat,
    traits: UITraitCollection
  ) throws -> AmountCandidate? {
    var widths: [AmountCandidate: CGFloat] = [:]
    for candidate in candidates {
      let size = try pointSize(of: candidate.style, traits: traits)
      let font = UIFont.systemFont(ofSize: size, weight: .bold)
      widths[candidate] = (candidate.text as NSString).size(withAttributes: [.font: font]).width
    }
    return AmountCandidate.selected(from: candidates) { (widths[$0] ?? .infinity) <= width }
  }

  @MainActor
  private func pointSize(
    of style: AmountStyle,
    traits: UITraitCollection
  ) throws -> CGFloat {
    switch style {
    case .scaled(let factor):
      // Matches the amount's @ScaledMetric in ContentView.
      let scaled = UIFontMetrics(forTextStyle: .largeTitle)
        .scaledValue(for: 80, compatibleWith: traits)
      return min(scaled, AmountStyle.maximumSize) * factor
    case .textStyle(let textStyle), .plain(let textStyle, _):
      let textStyles: [Font.TextStyle: UIFont.TextStyle] = [
        .largeTitle: .largeTitle,
        .title: .title1,
        .title3: .title3,
        .headline: .headline,
        .body: .body,
        .subheadline: .subheadline,
        .caption: .caption1,
      ]
      let uiTextStyle = try #require(textStyles[textStyle])
      return UIFont.preferredFont(forTextStyle: uiTextStyle, compatibleWith: traits).pointSize
    }
  }
}
