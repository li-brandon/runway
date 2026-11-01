import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Runway

/// Where CI wants widget screenshots. Only the Screenshots step sets this.
var widgetScreenshotsDirectory: URL? {
  ProcessInfo.processInfo.environment["RUNWAY_WIDGET_SCREENSHOTS_DIR"]
    .map { URL(filePath: $0, directoryHint: .isDirectory) }
}

/// Renders widget content to PNGs at the narrowest iPhone's widget sizes. Outside a real widget,
/// the padding and background stand in for what the system adds.
@MainActor
@Suite(.enabled(if: widgetScreenshotsDirectory != nil, "Renders screenshots for CI only"))
struct WidgetSnapshotTests {
  private static let states: [(name: String, content: RunwayWidgetEntry.Content)] = [
    ("normal", allowance(today: 4_250, period: 48_000, days: 9, status: .normal)),
    ("near", allowance(today: 950, period: 41_000, days: 9, status: .nearLimit)),
    ("zero", allowance(today: 0, period: 0, days: 1, status: .noAllowance)),
    ("negative", allowance(today: -12_500, period: -30_000, days: 14, status: .over)),
    ("large", allowance(today: 12_345_678, period: 186_049_248, days: 11, status: .normal)),
    (
      "import-max",
      allowance(
        today: -10_000_000_000_000,
        period: -20_000_000_000_000,
        days: 11,
        status: .over
      )
    ),
    ("no-budget", .noBudget),
    ("not-ready", .storeNotReady),
  ]

  private static func allowance(
    today: Int,
    period: Int,
    days: Int,
    status: TodayStatus
  ) -> RunwayWidgetEntry.Content {
    .allowance(
      WidgetAllowance(
        remainingTodayCents: today,
        remainingPeriodCents: period,
        daysLeft: days,
        status: status
      )
    )
  }

  private func size(of layout: RunwayWidgetContent.Layout) -> CGSize {
    switch layout {
    case .small: CGSize(width: 148, height: 148)
    case .medium: CGSize(width: 321, height: 148)
    }
  }

  private func write(
    _ content: some View,
    layout: RunwayWidgetContent.Layout,
    scheme: ColorScheme,
    name: String,
    to directory: URL
  ) throws {
    let dimensions = size(of: layout)
    let framed =
      content
      .padding(16)
      .frame(width: dimensions.width, height: dimensions.height)
      .background(scheme == .dark ? Color.black : Color.white)
      .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 3
    let data = try #require(renderer.uiImage?.pngData())
    try data.write(to: directory.appending(path: "480-widget-\(layout.rawValue)-\(name).png"))
  }

  @Test("Every state renders in both layouts, light and dark")
  func allStates() throws {
    let directory = try #require(widgetScreenshotsDirectory)
    for layout in RunwayWidgetContent.Layout.allCases {
      for scheme in [ColorScheme.light, .dark] {
        for state in Self.states {
          let entry = RunwayWidgetEntry(date: .now, content: state.content)
          try write(
            RunwayWidgetContent(entry: entry, layout: layout),
            layout: layout,
            scheme: scheme,
            name: "\(state.name)-\(scheme == .dark ? "dark" : "light")",
            to: directory
          )
        }
      }
    }
  }

  @Test("Tinted, and with private amounts redacted, as on a locked device")
  func variants() throws {
    let directory = try #require(widgetScreenshotsDirectory)
    let content = Self.allowance(today: -12_500, period: -30_000, days: 14, status: .over)
    for layout in RunwayWidgetContent.Layout.allCases {
      try write(
        RunwayWidgetContent(
          entry: RunwayWidgetEntry(date: .now, content: content),
          layout: layout,
          usesStatusColor: false
        ),
        layout: layout,
        scheme: .dark,
        name: "negative-tinted-dark",
        to: directory
      )
      try write(
        RunwayWidgetContent(
          entry: RunwayWidgetEntry(date: .now, content: content, amountsArePrivate: true),
          layout: layout
        )
        .redacted(reason: .privacy),
        layout: layout,
        scheme: .light,
        name: "locked-light",
        to: directory
      )
    }
  }
}
