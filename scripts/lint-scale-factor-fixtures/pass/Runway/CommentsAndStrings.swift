// Don't use .minimumScaleFactor(0.5) here.
/* Nor .minimumScaleFactor(0.5) here,
   or .minimumScaleFactor
   (0.5) here. /* Nested .minimumScaleFactor(0.5). */ */
let inString = "call .minimumScaleFactor(0.5) to shrink"
let splitInString = "minimumScaleFactor" + "(0.5)"
let inMultilineString = """
  .minimumScaleFactor(0.5)
  .minimumScaleFactor
  (0.5)
  """
let afterComment = Text("x").minimumScaleFactor(/* not 0.5 */ TextScaling.minimumFactor)
