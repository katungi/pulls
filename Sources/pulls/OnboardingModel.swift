import AppKit
import Foundation
import Observation

enum OnboardingStep: Equatable, Sendable {
    case connect
    case repositories
    case notifications

    var title: String {
        switch self {
        case .connect:
            "Connect GitHub"
        case .repositories:
            "Select repositories"
        case .notifications:
            "Configure notifications"
        }
    }

    var progressLabel: String {
        switch self {
        case .connect:
            "Step 1 of 3"
        case .repositories:
            "Step 2 of 3"
        case .notifications:
            "Step 3 of 3"
        }
    }
}

@MainActor
@Observable
final class OnboardingModel {
    var step: OnboardingStep
    var device: DeviceCode?
    var isWorking = false
    var statusText: String?
    var errorMessage: String?
    var notificationDenied = false
    var showsTokenEntry = false
    var personalAccessToken = ""
    var repositorySelection = RepositorySelectionModel()

    @ObservationIgnored
    private let session: SessionController
    @ObservationIgnored
    private var authorizationTask: Task<Void, Never>?
    @ObservationIgnored
    var onFinished: () -> Void = {}
    @ObservationIgnored
    var openURL: (URL) -> Void = { url in
        guard GitHubHosts.canOpen(url) else { return }
        NSWorkspace.shared.open(url)
    }
    @ObservationIgnored
    var copyText: (String) -> Void = { text in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    init(session: SessionController, step: OnboardingStep) {
        self.session = session
        self.step = step
    }

    var showsIgnoredClientSecret: Bool {
        session.configuration.ignoredClientSecret
    }

    var canConnect: Bool {
        session.hasClientID && !isWorking
    }

    var bannerMessage: String? {
        errorMessage ?? session.statusMessage
    }

    func connect() {
        errorMessage = nil
        notificationDenied = false
        authorizationTask?.cancel()
        isWorking = true
        statusText = "Contacting GitHub…"
        device = nil
        authorizationTask = Task {
            await runAuthorization()
        }
    }

    func cancelAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
        isWorking = false
        statusText = nil
        device = nil
        personalAccessToken = ""
    }

    func showTokenEntry() {
        cancelAuthorization()
        errorMessage = nil
        showsTokenEntry = true
    }

    func hideTokenEntry() {
        personalAccessToken = ""
        errorMessage = nil
        showsTokenEntry = false
    }

    func submitPersonalAccessToken() {
        guard !isWorking else { return }
        let token = personalAccessToken
        errorMessage = nil
        isWorking = true
        statusText = nil
        Task {
            await savePersonalAccessToken(token)
        }
    }

    private func savePersonalAccessToken(_ token: String) async {
        defer { isWorking = false }
        do {
            try await session.signIn(withPastedAccessToken: token)
            personalAccessToken = ""
            showsTokenEntry = false
            step = .repositories
            await loadRepositories()
        } catch GitHubError.unauthorized {
            errorMessage = "GitHub rejected that token."
        } catch GitHubError.insufficientScope {
            errorMessage = "That token needs the repo scope."
        } catch {
            errorMessage = (error as? GitHubError)?.userMessage ?? GitHubError.network.userMessage
        }
    }

    func copyUserCode() {
        guard let device else { return }
        copyText(device.userCode)
    }

    func openVerificationPage() {
        guard let device else { return }
        openURL(device.verificationURL)
    }

    func loadRepositories() async {
        let stored = session.account?.repositories ?? []
        await repositorySelection.reload(stored: stored) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.session.repositoryList()
        }
        if session.phase == .signedOut {
            step = .connect
            errorMessage = session.statusMessage ?? GitHubError.unauthorized.userMessage
        }
    }

    func continueFromRepositories() {
        let saved = repositorySelection.repositoriesForSave()
        guard !saved.isEmpty else { return }
        session.saveRepositories(saved)
        step = .notifications
    }

    func enableNotifications() async {
        guard !isWorking, !notificationDenied else { return }
        isWorking = true
        defer { isWorking = false }
        let granted = await session.requestSystemNotificationAuthorization()
        session.finishNotificationStep(wantsSystemNotifications: granted)
        if granted {
            onFinished()
        } else {
            notificationDenied = true
            errorMessage = "macOS did not allow notifications. You can enable them later in System Settings."
        }
    }

    func skipNotifications() {
        session.finishNotificationStep(wantsSystemNotifications: false)
        onFinished()
    }

    func continueAfterDenial() {
        onFinished()
    }

    private func runAuthorization() async {
        do {
            let device = try await session.beginDeviceAuthorization()
            guard !Task.isCancelled else { return }
            self.device = device
            statusText = "Waiting for authorization…"
            openURL(device.verificationURL)
            _ = try await session.finishDeviceAuthorization(device)
            guard !Task.isCancelled else { return }
            isWorking = false
            statusText = nil
            self.device = nil
            await advanceAfterConnect()
        } catch is CancellationError {
            isWorking = false
            statusText = nil
            device = nil
        } catch {
            isWorking = false
            statusText = nil
            device = nil
            errorMessage = (error as? GitHubError)?.userMessage ?? GitHubError.network.userMessage
            PullsLog.auth.error("Device flow failed")
        }
    }

    private func advanceAfterConnect() async {
        switch setupRoute(hasCredential: true, account: session.account) {
        case .connect:
            step = .connect
        case .repositories:
            step = .repositories
            await loadRepositories()
        case .notifications:
            step = .notifications
        case .ready:
            onFinished()
        }
    }
}
