import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    func show<Content: View>(title: String, rootView: Content, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let window {
            window.title = title
            window.contentViewController = NSHostingController(rootView: rootView)
            bringToFront()
            return
        }
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = title
        window.isReleasedWhenClosed = false
        // Stay visible while the user authorizes in the browser.
        window.hidesOnDeactivate = false
        window.level = .normal
        window.delegate = self
        self.window = window
        bringToFront()
    }

    func bringToFront() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onClose
        onClose = nil
        window = nil
        callback?()
    }
}

@MainActor
final class OnboardingCoordinator {
    private let session: SessionController
    private let setupWindow = OnboardingWindowController()
    private let repositoryWindow = OnboardingWindowController()
    private var setupModel: OnboardingModel?

    init(session: SessionController) {
        self.session = session
    }

    func presentSetup() {
        repositoryWindow.close()
        if session.phase != .signedOut && setupWindow.isVisible {
            setupWindow.bringToFront()
            return
        }
        if setupWindow.isVisible {
            setupWindow.close()
        }
        let step = session.phase == .signedOut ? OnboardingStep.connect : onboardingStep(session.route)
        guard step != .connect || session.phase == .signedOut || session.route != .ready else { return }
        let model = OnboardingModel(session: session, step: step)
        model.onFinished = { [weak self] in
            self?.setupWindow.close()
        }
        setupModel = model
        setupWindow.show(title: "Set up Pulls", rootView: OnboardingView(model: model)) { [weak model] in
            model?.cancelAuthorization()
        }
        if model.step == .repositories {
            Task { await model.loadRepositories() }
        }
    }

    func presentPersonalAccessToken() {
        repositoryWindow.close()
        if setupWindow.isVisible {
            setupWindow.close()
        }
        let model = OnboardingModel(session: session, step: .connect)
        model.showsTokenEntry = true
        model.onFinished = { [weak self] in
            self?.setupWindow.close()
        }
        setupModel = model
        setupWindow.show(title: "Personal access token", rootView: OnboardingView(model: model)) { [weak model] in
            model?.cancelAuthorization()
        }
    }

    func presentRepositories() {
        guard session.phase == .signedIn else {
            presentSetup()
            return
        }
        let model = RepositorySelectionModel()
        let stored = session.account?.repositories ?? []
        repositoryWindow.show(
            title: "Repositories",
            rootView: RepositoryEditorView(
                model: model,
                onCancel: { [weak self] in
                    self?.repositoryWindow.close()
                },
                onSave: { [weak self] in
                    guard let self else { return }
                    let saved = model.repositoriesForSave()
                    guard !saved.isEmpty else { return }
                    self.session.saveRepositories(saved)
                    self.repositoryWindow.close()
                }
            )
        ) {}
        Task { [weak self] in
            guard let self else { return }
            let session = self.session
            await model.reload(stored: stored) {
                try await session.repositoryList()
            }
        }
    }

    private func onboardingStep(_ route: SetupRoute) -> OnboardingStep {
        switch route {
        case .connect, .ready:
            .connect
        case .repositories:
            .repositories
        case .notifications:
            .notifications
        }
    }
}
