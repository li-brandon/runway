import CoreGraphics

/// Limits on shrinking text to fit. Text should wrap rather than shrink past this floor, so it
/// stays readable at the largest accessibility sizes.
enum TextScaling {
  static let minimumFactor: CGFloat = 0.7
}
