import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Runway

private let rgbaBitmapInfo =
  CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

/// Draws `image` into a bitmap this function owns, so the bytes never depend on how, or whether,
/// the image's own storage can be read back.
func bitmapBytes(of image: CGImage) throws -> Data {
  let bytesPerRow = image.width * 4
  let buffer = UnsafeMutableRawBufferPointer.allocate(
    byteCount: bytesPerRow * image.height,
    alignment: 4
  )
  defer { buffer.deallocate() }
  buffer.initializeMemory(as: UInt8.self, repeating: 0)
  let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
  let context = try #require(
    CGContext(
      data: buffer.baseAddress,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: rgbaBitmapInfo
    )
  )
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return Data(buffer)
}

private let amounts: [(today: Int, period: Int)] = [
  (0, 0),
  (4_250, 48_000),
  (-12_500, -30_000),
  (12_345_678, 186_049_248),
  (-10_000_000_000_000, -20_000_000_000_000),
]

private func allowance(
  today: Int,
  period: Int,
  daysLeft: Int = 9,
  status: TodayStatus
) -> WidgetAllowance {
  WidgetAllowance(
    remainingTodayCents: today,
    remainingPeriodCents: period,
    daysLeft: daysLeft,
    periodDays: 14,
    status: status
  )
}

struct WidgetRedactedTextTests {
  @Test("Redacted, every amount displays the same text, full or abbreviated")
  func redactedAmount() {
    for amount in amounts {
      let texts = [
        Money.format(cents: amount.today, locale: Money.fixedLocale),
        Money.abbreviated(cents: amount.today, locale: Money.fixedLocale),
      ]
      for text in texts {
        #expect(AmountCandidate.displayed(text, isRedacted: true) == "$0,000.00")
        #expect(AmountCandidate.displayed(text, isRedacted: false) == text)
      }
    }
  }

  @Test("Redacted, every amount has one candidate per step, all with the same text")
  func redactedCandidates() {
    let steps = LockScreenText.rectangularAmountSteps
    let expected = steps.map { AmountCandidate(style: $0, text: "$0,000.00") }
    for amount in amounts {
      let candidates = AmountCandidate.candidates(
        cents: amount.today,
        steps: steps,
        isRedacted: true,
        locale: Money.fixedLocale
      )
      #expect(candidates == expected)
    }
  }

  @Test("Unredacted, candidates keep the amount, abbreviating at the smallest size")
  func unredactedCandidates() {
    let steps = LockScreenText.rectangularAmountSteps
    let candidates = AmountCandidate.candidates(
      cents: 12_345_678,
      steps: steps,
      isRedacted: false,
      locale: Money.fixedLocale
    )
    let texts = candidates.map { $0.text }
    #expect(texts == ["$123,456.78", "$123,456.78", "$123,456.78", "$123.5K"])
  }

  @Test("Redacted, every status displays the same title and symbol")
  func redactedStatus() {
    for status in TodayStatus.allCases {
      #expect(LockScreenText.statusTitle(status, isRedacted: true) == "Budget status")
      #expect(LockScreenText.statusSymbol(status, isRedacted: true) == "circle")
    }
  }

  @Test("Unredacted, the status keeps its title and symbol")
  func unredactedStatus() {
    for status in TodayStatus.allCases {
      #expect(LockScreenText.statusTitle(status, isRedacted: false) == status.title)
      #expect(LockScreenText.statusSymbol(status, isRedacted: false) == status.symbol)
    }
  }

  @Test("Redacted, the inline text is the same for every amount, status, and day count")
  func redactedInline() {
    for status in TodayStatus.allCases {
      for amount in amounts {
        for days in [0, 1, 14] {
          let figures = allowance(
            today: amount.today,
            period: amount.period,
            daysLeft: days,
            status: status
          )
          let inline = LockScreenText.inline(
            figures,
            isRedacted: true,
            locale: Money.fixedLocale
          )
          let compact = LockScreenText.compactInline(
            figures,
            isRedacted: true,
            locale: Money.fixedLocale
          )
          #expect(inline == "$0,000.00 today · 00 days left")
          #expect(compact == "$0,000.00 · 00d")
        }
      }
    }
  }

  @Test("Unredacted, the inline text keeps its figures")
  func unredactedInline() {
    let figures = allowance(today: -12_500, period: 0, daysLeft: 14, status: .over)
    let inline = LockScreenText.inline(figures, isRedacted: false, locale: Money.fixedLocale)
    let compact = LockScreenText.compactInline(
      figures,
      isRedacted: false,
      locale: Money.fixedLocale
    )
    #expect(inline == "-$125.00 today · 14 days left")
    #expect(compact == "-$125.00 · 14d")
  }
}

struct WidgetBitmapBytesTests {
  @Test("Bitmap bytes keep each pixel's value, top row first")
  func knownPixels() throws {
    let topRow: [UInt8] = [0x12, 0x34, 0x56, 0xFF, 0x78, 0x9A, 0xBC, 0xFF]
    let bottomRow: [UInt8] = [0xDE, 0xF0, 0x11, 0xFF, 0x22, 0x33, 0x44, 0xFF]
    let pixels = topRow + bottomRow
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try #require(
      CGImage(
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 8,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: rgbaBitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )
    let bytes = try bitmapBytes(of: image)
    #expect(bytes == Data(pixels))
  }
}

/// Measures widget content at its ideal size, where its width follows its text, and renders it in
/// a frame the size of a real widget, where the frame hides that width and only the pixels can
/// differ.
@MainActor
struct WidgetRedactionRenderTests {
  private struct Rendering: Equatable {
    let idealSize: CGSize
    let framedImage: Data
  }

  private func render(_ content: some View, in frame: CGSize) throws -> Rendering {
    let themed = content.environment(\.colorScheme, .light)
    // The renderer reports the size up front, and not calling its draw callback skips the pixels.
    var measuredSize: CGSize?
    ImageRenderer(content: themed).render { size, _ in measuredSize = size }
    let idealSize = try #require(measuredSize)
    let framed = ImageRenderer(content: themed.frame(width: frame.width, height: frame.height))
    framed.scale = 1
    let framedImage = try #require(framed.cgImage)
    return Rendering(idealSize: idealSize, framedImage: try bitmapBytes(of: framedImage))
  }

  private var redactedWidget: some View {
    RunwayWidgetContent(
      entry: entry(
        allowance(today: 4_250, period: 48_000, status: .normal),
        amountsArePrivate: true
      ),
      layout: .small
    )
    .redacted(reason: .privacy)
  }

  private func entry(
    _ figures: WidgetAllowance,
    amountsArePrivate: Bool
  ) -> RunwayWidgetEntry {
    RunwayWidgetEntry(
      date: .now,
      content: .allowance(figures),
      amountsArePrivate: amountsArePrivate
    )
  }

  private func frame(of layout: RunwayWidgetContent.Layout) -> CGSize {
    switch layout {
    case .small: CGSize(width: 116, height: 116)
    case .medium: CGSize(width: 289, height: 116)
    }
  }

  private func frame(of family: LockScreenWidgetContent.Family) -> CGSize {
    switch family {
    case .circular: CGSize(width: 68, height: 68)
    case .rectangular: CGSize(width: 153, height: 68)
    case .inline: CGSize(width: 225, height: 26)
    }
  }

  /// Every status with every amount. The days stay fixed, since only the amount and status vary.
  private var allFigures: [WidgetAllowance] {
    TodayStatus.allCases.flatMap { status in
      amounts.map { allowance(today: $0.today, period: $0.period, status: status) }
    }
  }

  @Test("Redacted, home-screen widgets render the same for every status and amount")
  func homeScreen() throws {
    for layout in RunwayWidgetContent.Layout.allCases {
      var first: Rendering?
      for figures in allFigures {
        let rendering = try render(
          RunwayWidgetContent(entry: entry(figures, amountsArePrivate: true), layout: layout)
            .redacted(reason: .privacy),
          in: frame(of: layout)
        )
        let expected = first ?? rendering
        first = expected
        #expect(rendering.idealSize == expected.idealSize)
        #expect(rendering.framedImage == expected.framedImage)
      }
    }
  }

  @Test("Redacted, lock-screen widgets render the same for every status and amount")
  func lockScreen() throws {
    for family in LockScreenWidgetContent.Family.allCases {
      var first: Rendering?
      for figures in allFigures {
        let rendering = try render(
          LockScreenWidgetContent(entry: entry(figures, amountsArePrivate: true), family: family)
            .redacted(reason: .privacy),
          in: frame(of: family)
        )
        let expected = first ?? rendering
        first = expected
        #expect(rendering.idealSize == expected.idealSize)
        #expect(rendering.framedImage == expected.framedImage)
      }
    }
  }

  @Test("The same redacted widget renders equal bytes, and one changed byte breaks the equality")
  func oneByteMismatch() throws {
    let size = frame(of: RunwayWidgetContent.Layout.small)
    let first = try render(redactedWidget, in: size)
    let second = try render(redactedWidget, in: size)
    #expect(first == second)
    // Blank bitmaps would compare equal whatever the widget drew.
    let hasContent = first.framedImage.contains { $0 != 0 }
    #expect(hasContent)

    var changedBytes = first.framedImage
    changedBytes[changedBytes.startIndex + changedBytes.count / 2] ^= 1
    let changed = Rendering(idealSize: first.idealSize, framedImage: changedBytes)
    #expect(changed != first)
  }

  @Test("A 1pt mark on a redacted widget changes its rendered bytes")
  func onePointMismatch() throws {
    let size = frame(of: RunwayWidgetContent.Layout.small)
    let plain = try render(redactedWidget, in: size)
    let marked = try render(
      redactedWidget.overlay(alignment: .topLeading) {
        Rectangle().fill(.red).frame(width: 1, height: 1)
      },
      in: size
    )
    #expect(plain.framedImage != marked.framedImage)
  }

  @Test("Unredacted, a home-screen widget's rendering follows its amount")
  func unredactedWidth() throws {
    let layout = RunwayWidgetContent.Layout.small
    let small = try render(
      RunwayWidgetContent(
        entry: entry(
          allowance(today: 0, period: 0, status: .normal),
          amountsArePrivate: true
        ),
        layout: layout
      ),
      in: frame(of: layout)
    )
    let large = try render(
      RunwayWidgetContent(
        entry: entry(
          allowance(today: 12_345_678, period: 186_049_248, status: .normal),
          amountsArePrivate: true
        ),
        layout: layout
      ),
      in: frame(of: layout)
    )
    // The widget frame clamps the ideal size, so compare pixels: this proves the redaction
    // comparisons above would catch a difference.
    #expect(small.framedImage != large.framedImage)
  }

  @Test("With the app lock off, widgets keep their real figures on a locked device")
  func notPrivate() throws {
    let low = allowance(today: 0, period: 0, status: .noAllowance)
    let high = allowance(today: 12_345_678, period: 186_049_248, status: .normal)
    for layout in RunwayWidgetContent.Layout.allCases {
      let renderings = try [low, high].map { figures in
        try render(
          RunwayWidgetContent(entry: entry(figures, amountsArePrivate: false), layout: layout)
            .redacted(reason: .privacy),
          in: frame(of: layout)
        )
      }
      #expect(renderings[0].framedImage != renderings[1].framedImage)
    }
    for family in [LockScreenWidgetContent.Family.rectangular, .inline] {
      let renderings = try [low, high].map { figures in
        try render(
          LockScreenWidgetContent(entry: entry(figures, amountsArePrivate: false), family: family)
            .redacted(reason: .privacy),
          in: frame(of: family)
        )
      }
      #expect(renderings[0].framedImage != renderings[1].framedImage)
    }
  }
}
