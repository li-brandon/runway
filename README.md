# Runway

A local-only iPhone app that shows how much you can spend today.

You set a budget for a period (weekly, biweekly, or monthly), list your fixed bills, and log
expenses as you go. Runway shows how much of the period's "runway" you have left. Amounts are in
US dollars.

> **Status:** early. The data model, persistence, money helpers, allowance engine, budget setup,
> categories, and CI are in place. The main screen is still a placeholder.

## Budget setup

On first launch (no saved budget) the app opens **Set Up Budget**. After that, the gear button on
the main screen reopens it as **Budget**, with Cancel and Save.

- **Pay period:** weekly, biweekly (the default), or monthly, plus the payday the first period
  starts on.
- **Spendable per period** is the main figure and the only required one. **Income** is optional;
  **Use Income** copies it into spendable.
- **Fixed bills** (name, amount, optional due day) can be added, edited, and swiped away. Each
  amount comes out of every period. The due day is informational for now.
- **Savings per period** is a fixed dollar amount set aside each period.
- **Carry over leftovers** is on by default. On a saved budget, a change applies from the next
  period (`Budget.setCarryover`).
- **Available this period** = spendable − bills − savings, updated as you type. This is the
  amount the allowance engine spreads across the days of the period, so bills and savings never
  count as day-to-day money.

Amounts are parsed with `Decimal` into integer cents. `$`, spaces, and grouping separators are
ignored. Negative amounts, more than two decimal places, and amounts over $10,000,000 are errors,
and any error disables Save. If available is zero or negative, the screen shows a warning but
Save stays enabled: a tight period is real, and blocking it would strand a first-launch user on
the setup screen.

The logic lives in `BudgetDraft` (`Runway/Setup`), a plain value type with tests; the SwiftUI view
only binds to it. Changing the period length or payday goes through `Budget.updatePeriod`, which
moves a pending carryover change to the new next boundary, or drops it if it no longer changes
anything.

## Categories

Open the gear button, then **Categories** in the Budget screen. Categories are also available
before saving your first budget. Tap a category to rename it or choose a color and SF Symbol from
the fixed options. Use **+** to add one, **Edit** to reorder, and swipe left to delete.
Names are trimmed and must be nonempty and unique, ignoring case.

The app seeds Food, Groceries, Transport, Shopping, Entertainment, Bills, and Other on first
launch. Each has a symbol, `colorHex`, and saved `sortOrder`. Other has a stable `isSystem` marker
in the unshipped V1 schema. It cannot be deleted or renamed, but its color and symbol can change.
Its presence records that seeding has finished, so relaunching preserves edits and deleted defaults.

Deletion asks for confirmation and shows the expense count. Confirming moves those expenses to
Other before deleting the category; both changes save together. Expenses retain their amounts,
notes, and dates.

`CategoryService` owns validation, seeding, editing, moving, deletion, and expense creation.
App code must create expenses through `createExpense`, which assigns Other when no category is
provided. The model relationship remains optional for SwiftData; raw model insertion is reserved
for persistence tests. Startup assigns Other to any old uncategorized expenses. Service methods
stage changes in their context; callers save on success and roll back on a save failure.

`CategoryPicker` is reusable by the future quick logging screen (LIB-432). It returns a saved
category through `onSelect`. `CategoryOrdering` puts the three distinct categories with the most
recent expense dates first, then the rest in saved order. Equal dates keep saved order. The picker
uses all recorded expense dates, including future dates. Quick logging itself is not implemented.

## Launch arguments

Used for CI screenshots. You can also set them in Xcode under **Edit Scheme › Run › Arguments**.

| Argument | Effect |
| --- | --- |
| `-RunwayInMemoryStore` | Uses a fresh in-memory store instead of the on-disk one. |
| `-RunwayScreenshotScenario <name>` | Seeds sample data and opens the scenario screen. Ignored without `-RunwayInMemoryStore`, so sample data never reaches your real store. |

Scenarios: `setup-empty` (first launch, defaults), `setup-filled` (a budget with money available,
reopened from Settings), `setup-warning` (bills and savings exceed spendable),
`categories` (seeded category settings), and `category-picker` (a sheet with Shopping, Groceries,
and Transport first based on sample expenses).

```sh
xcrun simctl launch booted com.librandon.runway \
  -RunwayInMemoryStore -RunwayScreenshotScenario setup-warning
```

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
| `Runway/App` | App entry point, first-launch routing, launch arguments |
| `Runway/Models` | SwiftData models (`RunwaySchemaV1`) |
| `Runway/Persistence` | Model container setup and migration plan |
| `Runway/Money` | Cents ↔ dollars conversion and USD formatting |
| `Runway/Engine` | Daily allowance engine and its mapping from the models |
| `Runway/Categories` | Category persistence service and pure picker ordering |
| `Runway/Setup` | `BudgetDraft`: budget setup parsing, validation, and saving |
| `Runway/Views` | SwiftUI views |
| `RunwayTests` | Unit tests (Swift Testing) |

Money is always stored and calculated as integer cents (`Int`). Values only become `Decimal` for
display, and `Double` is never used for money.

Schema changes go in a new `VersionedSchema` (`RunwaySchemaV2`, …) with a matching stage in
`RunwayMigrationPlan`. Don't edit `RunwaySchemaV1` once it has shipped. V1 hasn't shipped yet, so
until the first release it may still be edited in place without a migration.

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
5. If the tests pass, installs the built app on the same simulator with the status bar clock set
   to 9:41, launches each screenshot scenario (see [Launch arguments](#launch-arguments)), and
   uploads `screenshots/430-<scenario>.png` as the `screenshots` artifact. A failed capture fails
   the job. Every scenario is captured at default and largest accessibility text sizes. Setup
   scenarios also get a second accessibility capture scrolled to the amount fields.
6. Uploads the `.xcresult` bundles as an artifact if any step fails.

A newer push to the same pull request cancels the older run. Runs on `main` are never cancelled.
Third-party actions are pinned to commit SHAs.

## Privacy

Everything you enter stays on your device. Runway has no accounts, analytics, or network code, and
it doesn't sync. The SwiftData store is local and CloudKit is explicitly turned off. If you delete
the app, your data is deleted with it.
