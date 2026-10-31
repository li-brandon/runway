// Calls that pass the shared floor, however they are laid out.
let oneLine = Text("x").minimumScaleFactor(TextScaling.minimumFactor)
let spaced = Text("x").minimumScaleFactor( TextScaling . minimumFactor )
let qualified = Text("x").minimumScaleFactor(Runway.TextScaling.minimumFactor)

let multiLineArgs = Text("x")
  .minimumScaleFactor(
    TextScaling.minimumFactor
  )

let multiLineQualified = Text("x")
  .minimumScaleFactor(
    Runway
      .TextScaling
      .minimumFactor
  )

let splitName = Text("x")
  .minimumScaleFactor
  (TextScaling.minimumFactor)

let splitQualified = Text("x")
  .minimumScaleFactor

  // The floor is shared.
  (Runway.TextScaling.minimumFactor)

let two = Text("x").minimumScaleFactor(TextScaling.minimumFactor).minimumScaleFactor(
  TextScaling.minimumFactor)
