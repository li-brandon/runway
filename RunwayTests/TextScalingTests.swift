import CoreGraphics
import Testing

@testable import Runway

struct TextScalingTests {
  @Test("Text never shrinks below the readable floor")
  func minimumFactorKeepsTextReadable() {
    #expect(TextScaling.minimumFactor >= 0.7)
  }
}
