import Foundation
import SwiftUI
import WidgetKit

@main
struct RunwayWidgetBundle: WidgetBundle {
  var body: some Widget {
    LeftToSpendWidget()
  }
}

struct LeftToSpendWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "LeftToSpendWidget", provider: LeftToSpendProvider()) { entry in
      RunwayWidgetView(entry: entry)
    }
    .configurationDisplayName("Left to Spend")
    .description("What you can spend today and how long this period has left.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

/// Reads the shared store through `WidgetTimelineBuilder`, where the logic and its tests live.
struct LeftToSpendProvider: TimelineProvider {
  func placeholder(in context: Context) -> RunwayWidgetEntry {
    .sample
  }

  func getSnapshot(in context: Context, completion: @escaping (RunwayWidgetEntry) -> Void) {
    completion(context.isPreview ? .sample : currentPlan().entries[0])
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<RunwayWidgetEntry>) -> Void
  ) {
    let plan = currentPlan()
    completion(Timeline(entries: plan.entries, policy: .after(plan.reloadDate)))
  }

  private func currentPlan() -> WidgetTimelinePlan {
    // The time zone may have changed since this process started.
    NSTimeZone.resetSystemTimeZone()
    return WidgetTimelineBuilder.plan(
      loadContainer: { try RunwayModelContainer.makeReadOnly() },
      amountsArePrivate: WidgetPrivacy.amountsArePrivate(in: WidgetPrivacy.sharedDefaults),
      now: .now,
      calendar: .current
    )
  }
}

#Preview("Small", as: .systemSmall) {
  LeftToSpendWidget()
} timeline: {
  RunwayWidgetEntry.sample
  RunwayWidgetEntry(
    date: .now,
    content: .allowance(
      WidgetAllowance(
        remainingTodayCents: -1_250,
        remainingPeriodCents: 30_000,
        daysLeft: 4,
        status: .over
      )
    )
  )
  RunwayWidgetEntry(date: .now, content: .noBudget)
  RunwayWidgetEntry(date: .now, content: .storeNotReady)
}

#Preview("Medium", as: .systemMedium) {
  LeftToSpendWidget()
} timeline: {
  RunwayWidgetEntry.sample
  RunwayWidgetEntry(
    date: .now,
    content: .allowance(
      WidgetAllowance(
        remainingTodayCents: 12_345_678,
        remainingPeriodCents: 186_049_248,
        daysLeft: 11,
        status: .normal
      )
    )
  )
  RunwayWidgetEntry(date: .now, content: .noBudget)
}
