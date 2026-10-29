# Runway

A local-only iPhone app that shows how much you can spend today.

You set a budget for a period (weekly, biweekly, or monthly), list your fixed bills, and log
expenses as you go. Runway shows how much of the period's "runway" you have left. Amounts are in
US dollars.

> **Status:** early scaffold. The data model, persistence, money helpers, and CI are in place. The
> UI is a placeholder that shows today's date and an empty state.

## Requirements

- Xcode 27 or later
- iOS 18.0 or later (iPhone only)

The minimum is iOS 18 because Runway is built on SwiftData and the modern SwiftUI APIs that ship
with it: versioned schemas and migration plans, `@Query`, `#Preview` with model containers, and
`ContentUnavailableView`. Targeting iOS 18 lets the app use these directly, with no fallback code
paths or Core Data shims.

## Getting started

1. Clone the repo and open `Runway.xcodeproj` in Xcode.
2. Pick an iPhone simulator (for example, iPhone 17) from the run destination menu.
3. Press **Run** (⌘R).

To run the tests, press ⌘U, or choose **Product › Test**. The tests use Swift Testing and an
in-memory SwiftData store, so they never touch the data on your simulator.

To run on a physical iPhone, select your own team under **Signing & Capabilities**. The project
uses automatic signing and does not commit a development team.

From the command line:

```sh
xcodebuild test \
  -project Runway.xcodeproj \
  -scheme Runway \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Project layout

| Path | Contents |
| --- | --- |
| `Runway/App` | App entry point |
| `Runway/Models` | SwiftData models (`RunwaySchemaV1`) |
| `Runway/Persistence` | Model container setup and migration plan |
| `Runway/Money` | Cents ↔ dollars conversion and USD formatting |
| `Runway/Views` | SwiftUI views |
| `RunwayTests` | Unit tests (Swift Testing) |

Money is always stored and calculated as integer cents (`Int`). Values only become `Decimal` for
display, and `Double` is never used for money.

Schema changes go in a new `VersionedSchema` (`RunwaySchemaV2`, …) with a matching stage in
`RunwayMigrationPlan`. Don't edit `RunwaySchemaV1` once it has shipped.

## Code style

The code uses 2-space indentation and is checked with `swift-format` using the `.swift-format`
config in the repo root:

```sh
xcrun swift-format lint --strict --recursive Runway RunwayTests
xcrun swift-format format --in-place --recursive Runway RunwayTests  # auto-fix
```

## CI

`.github/workflows/ios.yml` runs on every pull request and on pushes to `main`, on the `xcode-27`
macOS runner. It:

1. Selects Xcode 27 and fails if the version is wrong.
2. Runs `swift-format lint --strict`.
3. Finds the first available iPhone simulator on the newest iOS runtime and prints which one it
   picked. This avoids hard-coding a device name that the runner image might not have.
4. Runs `xcodebuild build-for-testing` and then `test-without-building`, with code signing
   turned off.
5. Uploads the `.xcresult` bundles as an artifact if any step fails.

A newer push to the same pull request cancels the older run. Runs on `main` are never cancelled.
Third-party actions are pinned to commit SHAs.

## Privacy

Everything you enter stays on your device. Runway has no accounts, analytics, or network code, and
it doesn't sync. The SwiftData store is local and CloudKit is explicitly turned off. If you delete
the app, your data is deleted with it.
