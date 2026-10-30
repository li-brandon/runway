// Expected violations: 3, 4, 5, 6, 7, 8, 9, 13, 15

let literal = Text("x").minimumScaleFactor(0.5)
let scaledQualified = Text("x").minimumScaleFactor(Runway.TextScaling.minimumFactor * 0.9)
let otherPrefix = Text("x").minimumScaleFactor(Foo.TextScaling.minimumFactor)
let nestedPrefix = Text("x").minimumScaleFactor(Foo.Runway.TextScaling.minimumFactor)
let otherMember = Text("x").minimumScaleFactor(Runway.TextScaling.maximumFactor)
let stringArg = Text("x").minimumScaleFactor("TextScaling.minimumFactor")
let afterBareName = style.minimumScaleFactor + Text("x").minimumScaleFactor(0.5)

let afterGoodCall = Text("x")
  .minimumScaleFactor(TextScaling.minimumFactor)
  .minimumScaleFactor(0.5)
let multiLine = Text("x")
  .minimumScaleFactor(
    Foo.TextScaling.minimumFactor
  )
