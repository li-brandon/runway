// Exempt: this path, relative to the root, owns the floor.
enum TextScaling {
  static let minimumFactor: CGFloat = 0.7
}

let exempt = Text("x").minimumScaleFactor(0.5)
