// The name without a following `(` is not a call.
struct Style {
  var minimumScaleFactor: CGFloat = 0.5
}

let style = Style()
let bare = style.minimumScaleFactor
let scaled = style.minimumScaleFactor * 2
let tuple = (style.minimumScaleFactor, 0.5)

let nextLineOperator =
  style.minimumScaleFactor
  + (0.5)

let nextLineMember = style.minimumScaleFactor
  // Comments don't change what comes next.

  .rounded()

// Longer identifiers are different names.
let longer = minimumScaleFactorFor(0.5)
let prefixed = myminimumScaleFactor(0.5)
let underscored = minimumScaleFactor_(0.5)

// Ends the file with the name; nothing follows.
let last = style.minimumScaleFactor
