import Foundation
import SwiftUI

/// Text an amount can show, and the size to show it at.
struct AmountCandidate: Hashable {
  let style: AmountStyle
  let text: String

  /// The full amount at each step, largest first, then abbreviated at the smallest. Amounts that
  /// abbreviating wouldn't change have no abbreviated candidate.
  static func candidates(
    cents: Int,
    steps: [AmountStyle],
    locale: Locale = .autoupdatingCurrent
  ) -> [AmountCandidate] {
    let full = Money.format(cents: cents, locale: locale)
    var candidates = steps.map { AmountCandidate(style: $0, text: full) }
    let abbreviated = Money.abbreviated(cents: cents, locale: locale)
    if let smallest = steps.last, abbreviated != full {
      candidates.append(AmountCandidate(style: smallest, text: abbreviated))
    }
    return candidates
  }

  /// What `ViewThatFits` shows: the first candidate that fits, or the last when none does.
  static func selected(
    from candidates: [AmountCandidate],
    fits: (AmountCandidate) -> Bool
  ) -> AmountCandidate? {
    candidates.first(where: fits) ?? candidates.last
  }
}

/// An amount on one line that never breaks mid-number and never truncates: it shows the first
/// candidate that fits. Every candidate is fixed at its ideal width, so if even the last doesn't
/// fit it overflows rather than showing "…". VoiceOver always gets the full amount.
struct AmountText: View {
  let cents: Int
  var steps = AmountStyle.rowSteps
  /// The size `AmountStyle.scaled` steps scale from.
  var fullSize = AmountStyle.maximumSize
  /// Read as the label, with the amount as its value. Without one, the amount is the label.
  var accessibilityTitle: LocalizedStringKey?
  var locale = Locale.autoupdatingCurrent

  var candidates: [AmountCandidate] {
    AmountCandidate.candidates(cents: cents, steps: steps, locale: locale)
  }

  var accessibilityText: String {
    Money.format(cents: cents, locale: locale)
  }

  var body: some View {
    if let accessibilityTitle {
      fittingText
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(accessibilityText)
    } else {
      fittingText
        .accessibilityLabel(accessibilityText)
    }
  }

  private var fittingText: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(candidates, id: \.self) { candidate in
        Text(candidate.text)
          .font(candidate.style.font(fullSize: fullSize))
          .lineLimit(AmountStyle.lineLimit)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
  }
}
