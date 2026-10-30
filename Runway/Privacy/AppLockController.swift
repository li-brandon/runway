import Foundation
import LocalAuthentication
import Observation

enum AppLockAuthResult: Equatable, Sendable {
  case success
  case failed
  case cancelled
  /// The device can't authenticate anyone, because it has no passcode.
  case unavailable
}

@MainActor
protocol AppLockAuthenticating {
  func authenticate(reason: String) async -> AppLockAuthResult
}

/// Face ID or Touch ID, with the device passcode as the fallback.
struct DeviceAuthenticator: AppLockAuthenticating {
  func authenticate(reason: String) async -> AppLockAuthResult {
    let context = LAContext()
    do {
      let success = try await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: reason
      )
      return success ? .success : .failed
    } catch let error as LAError {
      switch error.code {
      case .userCancel, .appCancel, .systemCancel, .userFallback:
        return .cancelled
      case .passcodeNotSet:
        return .unavailable
      default:
        return .failed
      }
    } catch {
      return .failed
    }
  }
}

/// Used by every in-memory launch, so screenshots can never bring up a system prompt.
struct NoPromptAuthenticator: AppLockAuthenticating {
  func authenticate(reason: String) async -> AppLockAuthResult {
    .cancelled
  }
}

/// The app lock's state machine. Views report scene changes and show its state.
///
/// The system prompt makes the scene inactive and then active again, so only the background locks,
/// and each lock prompts on its own at most once. Otherwise cancelling the prompt would reopen it
/// forever. After that, the lock screen's button retries.
@MainActor
@Observable
final class AppLockController {
  enum State: Equatable, Sendable {
    case unlocked
    case locked
    case authenticating
  }

  static let enabledKey = "appLockEnabled"

  private(set) var state: State
  private(set) var isEnabled: Bool
  /// Why the last unlock or attempt to turn on the lock didn't work, for display.
  private(set) var message: String?

  private let authenticator: any AppLockAuthenticating
  private let defaults: UserDefaults?
  private var promptsWhenActive: Bool
  /// Identifies the latest prompt, so a result that arrives after going to the background, which
  /// has already locked again, can't unlock the app.
  private var attempt = 0

  /// Reads the setting from `defaults`, and starts locked if the lock is on.
  init(authenticator: any AppLockAuthenticating, defaults: UserDefaults) {
    let isEnabled = defaults.bool(forKey: Self.enabledKey)
    self.authenticator = authenticator
    self.defaults = defaults
    self.isEnabled = isEnabled
    state = isEnabled ? .locked : .unlocked
    promptsWhenActive = isEnabled
  }

  /// Keeps the setting in memory only.
  init(authenticator: any AppLockAuthenticating, isEnabled: Bool, isLocked: Bool) {
    self.authenticator = authenticator
    defaults = nil
    self.isEnabled = isEnabled
    state = isLocked ? .locked : .unlocked
    promptsWhenActive = isLocked
  }

  /// In-memory launches never read or write the real setting: a screenshot scenario mustn't leave
  /// the lock on for the next launch, or pick up a lock that would hide its screen.
  static func make(
    for options: LaunchOptions,
    defaults: UserDefaults = .standard
  ) -> AppLockController {
    guard options.usesInMemoryStore else {
      return AppLockController(authenticator: DeviceAuthenticator(), defaults: defaults)
    }
    return AppLockController(
      authenticator: NoPromptAuthenticator(),
      isEnabled: options.screenshotScenario?.isPrivacy == true,
      isLocked: options.screenshotScenario == .privacyLocked
    )
  }

  var isLocked: Bool { state != .unlocked }

  /// Whether to hide the app's content. It's hidden from the app switcher only with the lock on.
  func showsCover(isSceneActive: Bool) -> Bool {
    isLocked || (isEnabled && !isSceneActive)
  }

  func didEnterBackground() {
    attempt += 1
    guard isEnabled else { return }
    state = .locked
    promptsWhenActive = true
    message = nil
  }

  func didBecomeActive() async {
    guard state == .locked, promptsWhenActive else { return }
    await unlock()
  }

  func unlock() async {
    guard state == .locked else { return }
    promptsWhenActive = false
    message = nil
    state = .authenticating
    attempt += 1
    let current = attempt
    let result = await authenticator.authenticate(reason: "Unlock Runway")
    guard current == attempt, state == .authenticating else { return }
    switch result {
    case .success:
      state = .unlocked
    case .failed:
      state = .locked
      message = "Couldn't confirm it's you. Try again."
    case .cancelled:
      state = .locked
    case .unavailable:
      // With no passcode there's nothing to check against, and staying locked would strand the
      // user's data. Removing the passcode already requires knowing it.
      state = .unlocked
    }
  }

  /// Turning the lock on first checks that authentication works, so the user can't lock themselves
  /// out. Check `isEnabled` afterwards for the outcome.
  func setEnabled(_ enabled: Bool) async {
    guard enabled != isEnabled, state == .unlocked else { return }
    message = nil
    guard enabled else {
      store(false)
      return
    }
    attempt += 1
    let current = attempt
    let result = await authenticator.authenticate(reason: "Turn on the app lock")
    guard current == attempt else { return }
    switch result {
    case .success:
      store(true)
    case .failed:
      message = "Couldn't confirm it's you, so the lock stays off."
    case .cancelled:
      break
    case .unavailable:
      message = "Set a passcode for this iPhone to use the lock."
    }
  }

  private func store(_ enabled: Bool) {
    isEnabled = enabled
    defaults?.set(enabled, forKey: Self.enabledKey)
  }
}
