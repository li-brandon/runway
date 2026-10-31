// Expected violations: 4
// Only Runway/Views/TextScaling.swift is exempt, not every file with that name.

let notExempt = Text("x").minimumScaleFactor(0.5)
