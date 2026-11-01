import SwiftUI
import WidgetKit

/// The widget as WidgetKit hosts it: reads the family and rendering mode from the environment, and
/// adds what only applies inside a widget.
struct RunwayWidgetView: View {
  let entry: RunwayWidgetEntry

  @Environment(\.widgetFamily) private var family
  @Environment(\.widgetRenderingMode) private var renderingMode

  var body: some View {
    content
      .widgetURL(AppDeepLink.todayURL)
  }

  @ViewBuilder
  private var content: some View {
    if let lockScreenFamily = LockScreenWidgetContent.Family(family) {
      LockScreenWidgetContent(entry: entry, family: lockScreenFamily)
        .containerBackground(.clear, for: .widget)
    } else {
      RunwayWidgetContent(
        entry: entry,
        layout: family == .systemMedium ? .medium : .small,
        usesStatusColor: renderingMode == .fullColor
      )
      .containerBackground(.background, for: .widget)
    }
  }
}

/// A widget's content. Takes everything as parameters, so CI can render it outside a widget.
struct RunwayWidgetContent: View {
  enum Layout: String, CaseIterable, Sendable {
    case small
    case medium

    /// The size `AmountStyle.scaled` steps scale from. `AmountText` drops to smaller steps.
    var heroSize: CGFloat {
      switch self {
      case .small: 40
      case .medium: 44
      }
    }
  }

  let entry: RunwayWidgetEntry
  let layout: Layout
  /// Off when the system tints the widget or makes it clear, where status colors don't apply.
  var usesStatusColor = true

  @Environment(\.redactionReasons) private var redactionReasons

  private var isRedacted: Bool {
    redactionReasons.contains(.privacy)
  }

  var body: some View {
    Group {
      switch entry.content {
      case .allowance(let allowance):
        switch layout {
        case .small: small(allowance)
        case .medium: medium(allowance)
        }
      case .noBudget:
        message(
          "Set up your budget",
          detail: "Open Runway to see what you can spend today.",
          symbol: "dollarsign.circle"
        )
      case .storeNotReady:
        message(
          "Nothing to show yet",
          detail: "Open Runway to see what you can spend today.",
          symbol: "hourglass"
        )
      }
    }
    // Widgets don't scroll, so the largest text sizes would push content out of the widget.
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func small(_ allowance: WidgetAllowance) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      title
      Spacer(minLength: 0)
      hero(allowance)
      statusLabel(allowance)
    }
  }

  private func medium(_ allowance: WidgetAllowance) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        title
        Spacer(minLength: 0)
        statusLabel(allowance)
      }
      hero(allowance)
      Spacer(minLength: 0)
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 0) {
          Text("Days left")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(allowance.daysLeft, format: .number)
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        VStack(alignment: .leading, spacing: 0) {
          Text("Left this period")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
          AmountText(
            cents: allowance.remainingPeriodCents,
            steps: [.plain(.subheadline, .semibold), .plain(.caption, .semibold)],
            accessibilityOverride: LockScreenText.periodAccessibilityLabel(
              allowance,
              isPrivate: isRedacted
            )
          )
          .privacySensitive(entry.amountsArePrivate)
        }
      }
    }
  }

  private var title: some View {
    Text("Left to spend today")
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(2)
      .minimumScaleFactor(TextScaling.minimumFactor)
      .accessibilityHidden(true)
  }

  private func hero(_ allowance: WidgetAllowance) -> some View {
    AmountText(
      cents: allowance.remainingTodayCents,
      steps: AmountStyle.heroSteps,
      fullSize: layout.heroSize,
      accessibilityOverride: LockScreenText.accessibilityLabel(
        LockScreenText.rectangularAccessibility(allowance),
        isPrivate: isRedacted
      )
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(statusColor(allowance))
    .widgetAccentable()
    .privacySensitive(entry.amountsArePrivate)
  }

  private func statusLabel(_ allowance: WidgetAllowance) -> some View {
    Label(allowance.status.title, systemImage: allowance.status.symbol)
      .font(.caption2)
      .foregroundStyle(statusColor(allowance))
      .lineLimit(1)
      .minimumScaleFactor(TextScaling.minimumFactor)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        LockScreenText.statusAccessibilityLabel(allowance.status, isPrivate: isRedacted)
      )
      .privacySensitive(entry.amountsArePrivate)
  }

  private func statusColor(_ allowance: WidgetAllowance) -> Color {
    usesStatusColor ? allowance.status.color : .primary
  }

  private func message(
    _ title: LocalizedStringKey,
    detail: LocalizedStringKey,
    symbol: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Image(systemName: symbol)
        .font(.title2)
        .widgetAccentable()
        .accessibilityHidden(true)
      Spacer(minLength: 0)
      Text(title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
        .minimumScaleFactor(TextScaling.minimumFactor)
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .minimumScaleFactor(TextScaling.minimumFactor)
    }
  }
}
