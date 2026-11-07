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

  /// Force cleanup after all widget rendering to release graphics resources.
  deinit {
    // Drain any pending autorelease pools from ImageRenderer instances
    autoreleasepool {}
  }

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
        periodDays: 14,
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

  /// Renders `content` until two renders in a row give the same bytes, since early in the process
  /// a font or symbol can still be loading and change what's drawn. After a few tries it returns
  /// the last render as PNG data, so a widget that never settles will use its final attempt.
  private func stableSnapshot(of content: some View, scale: CGFloat) throws -> Data {
    @MainActor func renderOnce() throws -> (image: CGImage, bytes: Data) {
      let renderer = ImageRenderer(content: content)
      renderer.scale = scale
      let image = try #require(renderer.cgImage)
      let bytes = try bitmapBytes(of: image)
      return (image, bytes)
    }

    var previous = try renderOnce()
    for _ in 1..<5 {
      let next = try renderOnce()
      if next.bytes == previous.bytes {
        return try #require(UIImage(cgImage: next.image).pngData())
      }
      previous = next
    }
    return try #require(UIImage(cgImage: previous.image).pngData())
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
    let data = try stableSnapshot(of: framed, scale: 3)
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

  /// About the smallest each family gets, on a 375pt iPhone.
  private func size(of family: LockScreenWidgetContent.Family) -> CGSize {
    switch family {
    case .circular: CGSize(width: 68, height: 68)
    case .rectangular: CGSize(width: 153, height: 68)
    case .inline: CGSize(width: 225, height: 26)
    }
  }

  private func writeLockScreen(
    _ content: some View,
    family: LockScreenWidgetContent.Family,
    scheme: ColorScheme,
    name: String,
    to directory: URL
  ) throws {
    let dimensions = size(of: family)
    let framed =
      content
      .frame(width: dimensions.width, height: dimensions.height)
      .background(scheme == .dark ? Color.black : Color.white)
      .environment(\.colorScheme, scheme)
    let data = try stableSnapshot(of: framed, scale: 3)
    try data.write(to: directory.appending(path: "481-lockscreen-\(family.rawValue)-\(name).png"))
  }

  @Test("Every state renders in each lock-screen family, light and dark")
  func lockScreenStates() throws {
    let directory = try #require(widgetScreenshotsDirectory)
    for family in LockScreenWidgetContent.Family.allCases {
      for scheme in [ColorScheme.light, .dark] {
        for state in Self.states {
          let entry = RunwayWidgetEntry(date: .now, content: state.content)
          try writeLockScreen(
            LockScreenWidgetContent(entry: entry, family: family),
            family: family,
            scheme: scheme,
            name: "\(state.name)-\(scheme == .dark ? "dark" : "light")",
            to: directory
          )
        }
      }
    }
  }

  @Test("Lock-screen families with private amounts redacted, and at the largest text size")
  func lockScreenVariants() throws {
    let directory = try #require(widgetScreenshotsDirectory)
    let content = Self.allowance(
      today: -10_000_000_000_000,
      period: -20_000_000_000_000,
      days: 11,
      status: .over
    )
    for family in LockScreenWidgetContent.Family.allCases {
      try writeLockScreen(
        LockScreenWidgetContent(
          entry: RunwayWidgetEntry(date: .now, content: content, amountsArePrivate: true),
          family: family
        )
        .redacted(reason: .privacy),
        family: family,
        scheme: .dark,
        name: "locked-dark",
        to: directory
      )
      try writeLockScreen(
        LockScreenWidgetContent(
          entry: RunwayWidgetEntry(date: .now, content: content),
          family: family
        )
        .environment(\.dynamicTypeSize, .xxLarge),
        family: family,
        scheme: .dark,
        name: "import-max-xxlarge-dark",
        to: directory
      )
    }
  }
}
