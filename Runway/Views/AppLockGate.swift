import SwiftUI
import UIKit

/// Wraps the app's content: reports scene changes to the lock and hides the content when asked.
struct AppLockGate<Content: View>: View {
  let lock: AppLockController
  @ViewBuilder let content: Content

  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    let showsCover = lock.showsCover(isSceneActive: scenePhase == .active)
    content
      .accessibilityHidden(lock.isLocked)
      .overlay {
        // Hides the first frames at launch, before the cover window can exist.
        if showsCover {
          Color(.systemBackground)
            .ignoresSafeArea()
        }
      }
      .background {
        PrivacyCoverWindow(isPresented: showsCover) {
          LockScreenView(lock: lock)
        }
      }
      .environment(lock)
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .background:
          lock.didEnterBackground()
        case .active:
          Task { await lock.didBecomeActive() }
        default:
          break
        }
      }
      .task {
        guard scenePhase == .active else { return }
        await lock.didBecomeActive()
      }
  }
}

/// The privacy cover, plus an Unlock button while locked.
struct LockScreenView: View {
  let lock: AppLockController

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "lock.fill")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Runway")
        .font(.title.bold())
      if lock.isLocked {
        if let message = lock.message {
          Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button {
          Task { await lock.unlock() }
        } label: {
          Text("Unlock")
            .frame(minWidth: 120, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(lock.state == .authenticating)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }
}

/// Reports the window scene it lands in, which SwiftUI doesn't expose.
private final class SceneAnchorView: UIView {
  var onSceneChange: (@MainActor (UIWindowScene?) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onSceneChange?(window?.windowScene)
  }
}

/// Shows a view in its own window above the app. An overlay in the app's own window wouldn't do:
/// sheets and dialogs are presented above it and would stay visible in the app switcher.
private struct PrivacyCoverWindow<Cover: View>: UIViewRepresentable {
  let isPresented: Bool
  @ViewBuilder let cover: () -> Cover

  @MainActor
  final class Coordinator {
    private var window: UIWindow?
    private var host: UIHostingController<Cover>?

    func show(_ cover: Cover, in scene: UIWindowScene) {
      if let host {
        host.rootView = cover
      } else {
        let host = UIHostingController(rootView: cover)
        // VoiceOver mustn't reach the app's content behind the cover.
        host.view.accessibilityViewIsModal = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .statusBar + 1
        window.rootViewController = host
        self.host = host
        self.window = window
      }
      window?.isHidden = false
    }

    func hide() {
      window?.isHidden = true
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> SceneAnchorView {
    let view = SceneAnchorView()
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ view: SceneAnchorView, context: Context) {
    let coordinator = context.coordinator
    let isPresented = isPresented
    let cover = cover()
    let update: @MainActor (UIWindowScene?) -> Void = { scene in
      if isPresented, let scene {
        coordinator.show(cover, in: scene)
      } else {
        coordinator.hide()
      }
    }
    view.onSceneChange = update
    update(view.window?.windowScene)
  }

  static func dismantleUIView(_ view: SceneAnchorView, coordinator: Coordinator) {
    coordinator.hide()
  }
}

#Preview {
  LockScreenView(
    lock: AppLockController(authenticator: NoPromptAuthenticator(), isEnabled: true, isLocked: true)
  )
}
