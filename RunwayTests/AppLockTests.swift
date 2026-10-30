import Foundation
import Testing

@testable import Runway

/// Returns queued results and counts how often it was asked.
@MainActor
private final class FakeAuthenticator: AppLockAuthenticating {
  var results: [AppLockAuthResult]
  private(set) var calls = 0

  init(_ results: AppLockAuthResult...) {
    self.results = results
  }

  func authenticate(reason: String) async -> AppLockAuthResult {
    calls += 1
    return results.removeFirst()
  }
}

/// Holds its answer until the test resumes it, like a prompt that's still on screen.
@MainActor
private final class PendingAuthenticator: AppLockAuthenticating {
  private var continuation: CheckedContinuation<AppLockAuthResult, Never>?

  func authenticate(reason: String) async -> AppLockAuthResult {
    await withCheckedContinuation { continuation = $0 }
  }

  func waitForPrompt() async {
    while continuation == nil { await Task.yield() }
  }

  func finish(_ result: AppLockAuthResult) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

@MainActor
struct AppLockTests {
  private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "AppLockTests-\(UUID().uuidString)")!
  }

  private func makeLocked(_ authenticator: any AppLockAuthenticating) -> AppLockController {
    AppLockController(authenticator: authenticator, isEnabled: true, isLocked: true)
  }

  @Test("Success unlocks")
  func success() async {
    let lock = makeLocked(FakeAuthenticator(.success))
    await lock.didBecomeActive()
    #expect(lock.state == .unlocked)
    #expect(lock.message == nil)
  }

  @Test("Failure stays locked with a message, and doesn't prompt again by itself")
  func failure() async {
    let authenticator = FakeAuthenticator(.failed, .success)
    let lock = makeLocked(authenticator)
    await lock.didBecomeActive()
    #expect(lock.state == .locked)
    #expect(lock.message != nil)

    // The prompt closing makes the scene active again.
    await lock.didBecomeActive()
    #expect(authenticator.calls == 1)

    await lock.unlock()
    #expect(lock.state == .unlocked)
    #expect(lock.message == nil)
  }

  @Test("Cancelling stays locked, quietly, and doesn't reopen the prompt")
  func cancel() async {
    let authenticator = FakeAuthenticator(.cancelled, .success)
    let lock = makeLocked(authenticator)
    await lock.didBecomeActive()
    #expect(lock.state == .locked)
    #expect(lock.message == nil)

    await lock.didBecomeActive()
    #expect(authenticator.calls == 1)

    await lock.unlock()
    #expect(lock.state == .unlocked)
  }

  @Test("With no device passcode, the lock can't strand the user")
  func unavailable() async {
    let lock = makeLocked(FakeAuthenticator(.unavailable))
    await lock.didBecomeActive()
    #expect(lock.state == .unlocked)
  }

  @Test("Going to the background locks, and returning prompts again")
  func lockOnBackground() async {
    let authenticator = FakeAuthenticator(.success)
    let lock = AppLockController(authenticator: authenticator, isEnabled: true, isLocked: false)
    #expect(!lock.isLocked)

    lock.didEnterBackground()
    #expect(lock.state == .locked)

    await lock.didBecomeActive()
    #expect(authenticator.calls == 1)
    #expect(lock.state == .unlocked)
  }

  @Test("A lock that's off never locks or prompts")
  func disabledNeverLocks() async {
    let authenticator = FakeAuthenticator()
    let lock = AppLockController(authenticator: authenticator, isEnabled: false, isLocked: false)
    lock.didEnterBackground()
    await lock.didBecomeActive()
    await lock.unlock()
    #expect(lock.state == .unlocked)
    #expect(authenticator.calls == 0)
    #expect(!lock.showsCover(isSceneActive: false))
    #expect(!lock.showsCover(isSceneActive: true))
  }

  @Test("A prompt's result arriving after going to the background can't unlock")
  func staleResult() async {
    let authenticator = PendingAuthenticator()
    let lock = makeLocked(authenticator)
    let unlocking = Task { await lock.didBecomeActive() }
    await authenticator.waitForPrompt()
    #expect(lock.state == .authenticating)

    lock.didEnterBackground()
    authenticator.finish(.success)
    await unlocking.value
    #expect(lock.state == .locked)
  }

  @Test("Only one prompt opens at a time")
  func noDoublePrompt() async {
    let authenticator = PendingAuthenticator()
    let lock = makeLocked(authenticator)
    let unlocking = Task { await lock.unlock() }
    await authenticator.waitForPrompt()

    await lock.unlock()
    await lock.didBecomeActive()
    #expect(lock.state == .authenticating)

    authenticator.finish(.success)
    await unlocking.value
    #expect(lock.state == .unlocked)
  }

  @Test("The cover shows while locked, and when inactive only with the lock on")
  func cover() {
    let locked = makeLocked(FakeAuthenticator())
    #expect(locked.showsCover(isSceneActive: true))
    #expect(locked.showsCover(isSceneActive: false))

    let unlocked = AppLockController(
      authenticator: FakeAuthenticator(),
      isEnabled: true,
      isLocked: false
    )
    #expect(!unlocked.showsCover(isSceneActive: true))
    #expect(unlocked.showsCover(isSceneActive: false))
  }

  @Test("Turning the lock on needs authentication, and persists only on success")
  func enabling() async {
    let cases: [(AppLockAuthResult, Bool)] = [
      (.success, true),
      (.failed, false),
      (.cancelled, false),
      (.unavailable, false),
    ]
    for (result, expected) in cases {
      let defaults = makeDefaults()
      let authenticator = FakeAuthenticator(result)
      let lock = AppLockController(authenticator: authenticator, defaults: defaults)
      await lock.setEnabled(true)
      #expect(lock.isEnabled == expected)
      #expect(defaults.bool(forKey: AppLockController.enabledKey) == expected)
      #expect(lock.state == .unlocked)
      #expect(authenticator.calls == 1)
      #expect((lock.message != nil) == (result == .failed || result == .unavailable))
    }
  }

  @Test("Turning the lock off persists without a prompt")
  func disabling() async {
    let defaults = makeDefaults()
    defaults.set(true, forKey: AppLockController.enabledKey)
    let authenticator = FakeAuthenticator(.success)
    let lock = AppLockController(authenticator: authenticator, defaults: defaults)
    await lock.unlock()
    #expect(authenticator.calls == 1)

    await lock.setEnabled(false)
    #expect(!lock.isEnabled)
    #expect(!defaults.bool(forKey: AppLockController.enabledKey))
    #expect(authenticator.calls == 1)
  }

  @Test("The saved setting decides whether launch starts locked")
  func launchState() {
    let defaults = makeDefaults()
    let off = AppLockController(authenticator: FakeAuthenticator(), defaults: defaults)
    #expect(!off.isEnabled)
    #expect(off.state == .unlocked)

    defaults.set(true, forKey: AppLockController.enabledKey)
    let on = AppLockController(authenticator: FakeAuthenticator(), defaults: defaults)
    #expect(on.isEnabled)
    #expect(on.state == .locked)
  }

  @Test("Screenshot launches set up the lock without touching the saved setting")
  func screenshotLaunches() async {
    func options(_ scenario: ScreenshotScenario) -> LaunchOptions {
      LaunchOptions(arguments: [
        "Runway",
        "-RunwayInMemoryStore",
        "-RunwayScreenshotScenario",
        scenario.rawValue,
      ])
    }
    let defaults = makeDefaults()
    defaults.set(true, forKey: AppLockController.enabledKey)

    // A lock saved on this simulator doesn't hide other scenarios' screens.
    let today = AppLockController.make(for: options(.todayNormal), defaults: defaults)
    #expect(!today.isEnabled)
    #expect(!today.isLocked)

    let settings = AppLockController.make(for: options(.privacySettings), defaults: defaults)
    #expect(settings.isEnabled)
    #expect(!settings.isLocked)

    // The stand-in authenticator leaves the lock screen up rather than prompting.
    let locked = AppLockController.make(for: options(.privacyLocked), defaults: defaults)
    #expect(locked.isLocked)
    await locked.didBecomeActive()
    #expect(locked.state == .locked)
    #expect(locked.message == nil)

    await settings.setEnabled(false)
    #expect(!settings.isEnabled)
    #expect(defaults.bool(forKey: AppLockController.enabledKey))
  }
}
