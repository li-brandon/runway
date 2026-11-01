import Foundation
import SwiftUI
import WidgetKit

/// The text lock-screen widgets show. Amounts come from `Money`, so they abbreviate per LIB-477.
enum LockScreenText {
  /// The sizes the rectangular widget's amount tries, before abbreviating at the smallest.
  static var rectangularAmountSteps: [AmountStyle] {
    [
      .plain(.title3, .bold),
      .plain(.headline, .bold),
      .plain(.subheadline, .bold),
    ]
  }

  static func daysLeft(_ days: Int) -> String {
    days == 1 ? "1 day left" : "\(days) days left"
  }

  /// The inline widget's text. The system truncates inline text that doesn't fit, so the amount is
  /// always abbreviated and comes first.
  static func inline(
    _ allowance: WidgetAllowance,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    let amount = Money.abbreviated(cents: allowance.remainingTodayCents, locale: locale)
    return "\(amount) today · \(daysLeft(allowance.daysLeft))"
  }

  /// What the inline widget falls back to when `inline` doesn't fit.
  static func compactInline(
    _ allowance: WidgetAllowance,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    let amount = Money.abbreviated(cents: allowance.remainingTodayCents, locale: locale)
    return "\(amount) · \(allowance.daysLeft)d"
  }

  /// What VoiceOver reads, with the full amount.
  static func accessibility(
    _ allowance: WidgetAllowance,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    let amount = Money.format(cents: allowance.remainingTodayCents, locale: locale)
    return "\(amount) today, \(daysLeft(allowance.daysLeft))"
  }

  /// What VoiceOver reads for the rectangular widget's amount, with the full amount.
  static func rectangularAccessibility(
    _ allowance: WidgetAllowance,
    locale: Locale = .autoupdatingCurrent
  ) -> String {
    "Left to spend today, \(Money.format(cents: allowance.remainingTodayCents, locale: locale))"
  }

  /// What VoiceOver reads given the `text` with the figures. Redaction only covers what's drawn, so
  /// a redacted view needs a label without them.
  static func accessibilityLabel(_ text: String, isPrivate: Bool) -> String {
    isPrivate ? "Left to spend today" : text
  }
}

/// A lock-screen widget's content. Takes everything as parameters, so CI can render it outside a
/// widget. The system tints lock-screen widgets, so status colors don't apply.
struct LockScreenWidgetContent: View {
  enum Family: String, CaseIterable, Sendable {
    case circular
    case rectangular
    case inline

    /// `nil` for the families that aren't on the lock screen.
    init?(_ family: WidgetFamily) {
      switch family {
      case .accessoryCircular: self = .circular
      case .accessoryRectangular: self = .rectangular
      case .accessoryInline: self = .inline
      default: return nil
      }
    }
  }

  let entry: RunwayWidgetEntry
  let family: Family

  @Environment(\.redactionReasons) private var redactionReasons

  private var isRedacted: Bool {
    redactionReasons.contains(.privacy)
  }

  var body: some View {
    Group {
      switch entry.content {
      case .allowance(let allowance):
        figures(allowance)
          .privacySensitive(entry.amountsArePrivate)
      case .noBudget:
        message("Set up your budget", symbol: "dollarsign.circle")
      case .storeNotReady:
        message("Nothing to show yet", symbol: "hourglass")
      }
    }
    // Widgets don't scroll, so the largest text sizes would push content out of the widget.
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
  }

  @ViewBuilder
  private func figures(_ allowance: WidgetAllowance) -> some View {
    switch family {
    case .circular:
      DaysLeftGauge(allowance: allowance)
    case .rectangular:
      rectangular(allowance)
    case .inline:
      ViewThatFits(in: .horizontal) {
        inlineText(LockScreenText.inline(allowance))
        inlineText(LockScreenText.compactInline(allowance))
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        LockScreenText.accessibilityLabel(
          LockScreenText.accessibility(allowance),
          isPrivate: isRedacted
        )
      )
    }
  }

  private func rectangular(_ allowance: WidgetAllowance) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Left to spend today")
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(TextScaling.minimumFactor)
        .accessibilityHidden(true)
      AmountText(
        cents: allowance.remainingTodayCents,
        steps: LockScreenText.rectangularAmountSteps,
        accessibilityOverride: LockScreenText.accessibilityLabel(
          LockScreenText.rectangularAccessibility(allowance),
          isPrivate: isRedacted
        )
      )
      .widgetAccentable()
      Text(LockScreenText.daysLeft(allowance.daysLeft))
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(TextScaling.minimumFactor)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func inlineText(_ text: String) -> some View {
    Text(text)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private func message(_ title: String, symbol: String) -> some View {
    switch family {
    case .circular:
      Image(systemName: symbol)
        .font(.title2)
        .widgetAccentable()
        .accessibilityLabel(title)
    case .rectangular:
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(TextScaling.minimumFactor)
        Text("Open Runway")
          .font(.caption2)
          .lineLimit(1)
          .minimumScaleFactor(TextScaling.minimumFactor)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .inline:
      inlineText(title)
    }
  }
}

/// The ring fills as the period passes, with the days left in its center.
private struct DaysLeftGauge: View {
  let allowance: WidgetAllowance

  @Environment(\.redactionReasons) private var redactionReasons

  /// Redaction only covers the text, and the ring would still show how far the period has gone.
  private var isRedacted: Bool {
    redactionReasons.contains(.privacy)
  }

  var body: some View {
    Gauge(value: isRedacted ? 0 : allowance.elapsedFraction) {
      Text("Days left")
    } currentValueLabel: {
      Text(allowance.daysLeft, format: .number)
        .lineLimit(1)
        .minimumScaleFactor(TextScaling.minimumFactor)
    }
    .gaugeStyle(.accessoryCircularCapacity)
    .widgetAccentable()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isRedacted ? "Days left" : LockScreenText.daysLeft(allowance.daysLeft))
  }
}
