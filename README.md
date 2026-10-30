# Runway

A local-only iPhone app that shows how much you can spend today.

You set a budget for a period (weekly, biweekly, or monthly), list your fixed bills, and log
expenses as you go. Runway shows how much of the period's "runway" you have left. Amounts are in
US dollars.

> **Status:** early. The data model, persistence, money helpers, allowance engine, budget setup,
> categories, quick expense logging, the Today view, History, and CI are in place.

## Budget setup

On first launch (no saved budget) the app opens **Set Up Budget** as a sheet over Today.
Cancel or dismiss the sheet to see the Today empty state. **Set up budget** opens it again.
Saving the first budget replaces the empty state with Today and removes the setup sheet.
After that, the gear button reopens it as **Budget**, with Cancel and Save.

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

`CategoryPicker` returns a saved category through `onSelect`. `CategoryOrdering` puts the three
most recently logged distinct categories first, then the rest in saved order. It uses `createdAt`,
so logging a backdated expense still makes that category recent. Equal logging times keep saved
order. Normal create/delete operations fetch Other directly and only seed if it is missing.

## Today

The large USD figure shows **Left to spend today**. It scales with Dynamic Type up to 96 points
and shrinks to fit one line on narrow screens. Spent today and today's allowance appear below it,
followed by the period remainder and days left, including today. Carry-in appears only when
carryover is enabled at the current period's start, so a pending settings change cannot hide it.

The daily remainder determines the state. Negative means **Over budget**. Less than 20% of a
positive daily allowance means **Near limit**; exactly 20% stays **On track**. Zero or negative
allowances skip the percentage comparison. Each state has a symbol and text as well as a color.
`TodayStatus` uses decimal arithmetic to compare integer cents without overflow or rounding.

Only today's expenses appear, newest spending date first, then newest `createdAt` for ties.
Rows show category symbols and colors, notes, amounts, and times. Negative expenses have an
explicit **Refund** label. System backgrounds support dark mode. The undo banner insets the scroll
area, and extra bottom padding keeps the final row clear at accessibility text sizes.

Today refreshes at calendar midnight and whenever the app becomes active. `nextMidnight` uses
calendar day boundaries, including Chicago's 23-hour and 25-hour DST days. The midnight task
cancels and reschedules when the foreground refresh changes the current time.

## Quick expense logging

Tap **Log Expense** on Today to open the USD decimal keypad, focused on the amount. Enter a
positive amount; **Save** stays disabled with a message for empty, zero, or invalid input.
Category and note are optional (category defaults to Other). **Refund** saves the entered amount
as a negative expense. The date defaults to now and can only be backdated within the current
period. A budget whose first period starts in the future permits today only until that start.

Saving updates **Left to spend today** from `AllowanceEngine` through the model adapter and SwiftData
queries, and plays success haptic feedback. An **Undo** banner deletes the saved expense for five
seconds; saving again replaces that opportunity. The sheet uses standard Dynamic Type controls,
and the undo banner stacks at accessibility sizes. Dismissing the keyboard scrolls the Date field
into view after the keyboard animation.

`ExpenseDraft` shares `BudgetDraft` parsing, validates the amount, applies the refund sign, clamps
the date again at save time, and creates expenses exclusively through `CategoryService`.
`ExpenseUndo` provides the tested expiry and deletion operation. `Expense.createdAt` records when
an expense was logged independently of its spending date. V1 is still unshipped and edited in place.

## History

Tap **History** (the clock button on Today) to see the current period, newest day first. Each day
shows its allowance, what was spent, and **Over by** or **Under by** with a symbol as well as a
color. Above the days, a summary gives spent and available (spendable + carry-in), over or under
for the period, days over budget, carry-in, and carry-out, followed by net spending by category.
**Earlier period** and **Later period** browse back to the budget's first period. The current
period runs through today and its carry-out shows as pending; carry-in and carry-out read **Off**
when carryover didn't apply at that boundary.

Tap an expense, or swipe it, to edit or delete it. The edit sheet reuses the quick-log form and
`ExpenseDraft` validation; the date stays inside that expense's own period and never after now.
Deleting shows an **Undo** banner for five seconds that restores the amount, note, dates, and
category (Other if the category was deleted meanwhile), recreated through
`CategoryService.createExpense`. Edits go through `CategoryService.updateExpense`.

Expenses dated before the start of the budget's first period appear in a **Before budget** section
below the oldest period, newest first, and edit, delete, and undo like any other expense. They
count toward no period's totals or carryover. Their date can be any day through today, and choosing
one in the budget moves the expense into that period.

Nothing per day is stored. `HistoryEngine` (`Runway/Engine`) derives every figure from the budget
and expenses with `AllowanceEngine`'s rules, so an edit or delete updates later days, carryover,
and Today's number at once. Each day row equals `AllowanceEngine` evaluated on that day. One sort
and one sweep over the days builds all periods, so hundreds of expenses stay fast, and the list is
a lazy `List`.

## Launch arguments

Used for CI screenshots. You can also set them in Xcode under **Edit Scheme › Run › Arguments**.

| Argument | Effect |
| --- | --- |
| `-RunwayInMemoryStore` | Uses a fresh in-memory store instead of the on-disk one. |
| `-RunwayScreenshotScenario <name>` | Seeds sample data and opens the scenario screen. Ignored without `-RunwayInMemoryStore`, so sample data never reaches your real store. |

Scenarios: `setup-empty` (first launch, defaults), `setup-filled` (a budget with money available,
reopened from Settings), `setup-warning` (bills and savings exceed spendable),
`categories` (seeded category settings), and `category-picker` (a sheet with Shopping, Groceries,
and Transport first based on sample expenses), `quick-log-empty` (empty sheet, Save disabled),
`quick-log-filled` (amount, Food category, and note), and `today-undo` (saved expense and Undo).
Today scenarios: `today-normal` ($80 left), `today-near` ($10 left), `today-over` (-$20 left),
and `today-no-budget` (the empty state with setup closed). These use a fixed local noon on
June 10, 2026, and categorized expenses including a refund. `today-large-amount` ($123,456.78 left)
and `extra-money` (This Period with large extra money, a long note, and large bills) use the same
date.
History scenarios use the same date with two biweekly periods of sample spending starting May 24:
`history-list` (the current period, scrolled to its days), `history-period-summary` (the previous
period's summary, carryover, and categories), and `history-edit` (the edit sheet for yesterday's
latest expense), and `history-before-budget` (the oldest period's page, scrolled to expenses dated
before the budget's start). `-RunwayScreenshotScrollTo categories` scrolls History to its category
totals, `before-budget` scrolls it to the end of its Before budget section, `today` scrolls Today
to what's left to spend, `bills` scrolls This Period to its bills, and `extras` scrolls it to the
end of its last extra money row.
Privacy scenarios: `privacy-settings` (Privacy & Data with the lock on), `privacy-locked` (the lock
screen), `privacy-import-confirm`, and `privacy-reset-confirm` (their confirm alerts). In-memory
launches keep the lock setting in memory and never show a Face ID prompt.
The undo scenario delays showing its five-second banner until launch has settled for CI capture.

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
| `Runway/Engine` | Daily allowance and History engines and their mapping from the models |
| `Runway/Categories` | Category persistence service and pure picker ordering |
| `Runway/Expenses` | Quick-log and edit draft validation, creation, deletion, and expiring undo |
| `Runway/Setup` | `BudgetDraft`: budget setup parsing, validation, and saving |
| `Runway/Privacy` | App lock state machine, data export, import validation, and reset |
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
   uploads `screenshots/<ticket>-<scenario>.png` as the `screenshots` artifact: setup uses 430,
   categories and category-picker use 440, quick logging uses 432, the four Today scenarios
   use 433, the three History scenarios use 434, and the privacy scenarios use 437, except the
   import and reset confirms, which use 468. `history-before-budget` uses 463b, and
   `today-large-amount` and `extra-money` use 469. A failed
   capture fails the job. Every scenario is captured at default and largest accessibility text sizes. Setup
   scenarios also get a second accessibility capture scrolled to the amount fields, and
   `history-period-summary` one scrolled to its categories, and `history-before-budget` one scrolled
   to the end of its Before budget section.
   `today-normal`, `today-over`, and `history-list` also get dark captures at both sizes, named
   `<ticket>-<scenario>-dark.png` and `<ticket>-<scenario>-ax5-dark.png`. The capture step
   restores light appearance and default text size even on failure.
6. Uploads the `.xcresult` bundles as an artifact if any step fails.

A newer push to the same pull request cancels the older run. Runs on `main` are never cancelled.
Third-party actions are pinned to commit SHAs.

## Privacy

Everything you enter stays on your device. Runway has no accounts, analytics, or network code, and
it doesn't sync. The SwiftData store is local and CloudKit is explicitly turned off. If you delete
the app, your data is deleted with it.

No analytics or third-party data collection, and no third-party dependencies. Data leaves your
device only when you share an export yourself. Exported files aren't encrypted.

**Settings › Privacy & Data** has:

- **App lock:** asks for Face ID, Touch ID, or your passcode when you launch or return to Runway,
  and hides the app in the app switcher. It's off by default.
- **Export:** every record as versioned JSON, and expenses as CSV, through the share sheet. JSON
  dates are seconds since 2001-01-01 UTC, which keeps them exact.
- **Import:** replaces all data with a JSON export, after a confirmation. The whole file is checked
  first, and any failure leaves your data untouched. Refunds, and derived amounts that can
  legitimately go below zero, may be negative. All other amounts may not.
- **Reset:** after a confirmation, erases everything and restores the default categories. The app
  lock setting stays as it is.

See [docs/branch-protection.md](docs/branch-protection.md) for the rules on `main`.
