// Expected violations: 5, 10, 18, 25, 30
// A violation is reported on the line with the name, not the parenthesis.

let split = Text("x")
  .minimumScaleFactor
  (0.5)

let blankLines = Text("x")

  .minimumScaleFactor


  (0.5)

// Same-line, block, and multi-line block comments between the name and parenthesis.

let comments = Text("x")
  .minimumScaleFactor  // Trailing comment.
  // Own-line comment.
  /* Block comment. */
  /* Multi-line
     block comment. */ (0.5)

let afterBareName = Text("x")
  .minimumScaleFactor /* Same line. */ (0.5)

let notFirst = style.minimumScaleFactor
  .rounded()
let afterProperty = Text("x")
  .minimumScaleFactor
  (TextScaling.minimumFactor * 0.9)
