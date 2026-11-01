import Foundation
import SwiftUI

/// Text an amount can show, and the size to show it at.
struct AmountCandidate: Hashable {
  let style: AmountStyle
  let text: String

  /// Drawn instead of a redacted amount. Redaction draws a placeholder as wide as its text, so the
  /// real text would show the amount's length and sign.
  static let redactedText = "$0,000.00"

  /// The amount's `text`, or the fixed text when it's redacted.
  static func displayed(_ text: String, isRedacted: Bool) -> String {
    isRedacted ? redactedText : text
  }

  /// The full amount at each step, largest first, then abbreviated at the smallest. Amounts that
  /// abbreviating wouldn't change have no abbreviated candidate, and a redacted amount has none.
  static func candidates(
    cents: Int,
    steps: [AmountStyle],
    isRedacted: Bool = false,
    locale: Locale = .autoupdatingCurrent
  ) -> [AmountCandidate] {
    let full = displayed(Money.format(cents: cents, locale: locale), isRedacted: isRedacted)
    var candidates = steps.map { AmountCandidate(style: $0, text: full) }
    let abbreviated = displayed(
      Money.abbreviated(cents: cents, locale: locale),
      isRedacted: isRedacted
    )
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
  /// Read instead of the title and amount, for a view that can't always read the amount.
  var accessibilityOverride: String?
  /// Draws fixed text in place of the amount, for a view that's being redacted.
  var isRedacted = false
  var locale = Locale.autoupdatingCurrent

  var candidates: [AmountCandidate] {
    AmountCandidate.candidates(cents: cents, steps: steps, isRedacted: isRedacted, locale: locale)
  }

  var accessibilityText: String {
    Money.format(cents: cents, locale: locale)
  }

  var body: some View {
    if let accessibilityOverride {
      fittingText
        .accessibilityLabel(accessibilityOverride)
    } else if let accessibilityTitle {
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
