import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.step.progressLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(model.step.title)
                    .font(.system(size: 18, weight: .semibold))
            }

            switch model.step {
            case .connect:
                connectStep
            case .repositories:
                repositoryStep
            case .notifications:
                notificationStep
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 440, height: 580, alignment: .topLeading)
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GitHubAccessCopy.scopeSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.showsIgnoredClientSecret {
                Text(GitHubAccessCopy.ignoredClientSecret)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.canConnect && model.device == nil && !model.showsTokenEntry && !model.isWorking {
                Text(GitHubAccessCopy.missingClientID)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let banner = model.bannerMessage {
                Text(banner)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.showsTokenEntry {
                tokenEntry
            } else if let device = model.device {
                devicePrompt(device)
            } else {
                if model.canConnect || model.isWorking {
                    Button(model.isWorking ? "Contacting GitHub…" : "Connect GitHub") {
                        model.connect()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConnect)
                }
                Button("Use a personal access token") {
                    model.showTokenEntry()
                }
                .disabled(model.isWorking)
            }
        }
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GitHubAccessCopy.personalAccessTokenSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Token", text: $model.personalAccessToken)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isWorking)
            HStack {
                Button("Back") { model.hideTokenEntry() }
                    .disabled(model.isWorking)
                Spacer()
                Button(model.isWorking ? "Checking token…" : "Save token") {
                    model.submitPersonalAccessToken()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || AccessTokenPaste.value(from: model.personalAccessToken) == nil)
            }
        }
    }

    private func devicePrompt(_ device: DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(device.userCode)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("GitHub verification code \(device.userCode)")
            Text(device.verificationURL.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            if let statusText = model.statusText {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Copy code") { model.copyUserCode() }
                Button("Open GitHub") { model.openVerificationPage() }
                Spacer()
                Button("Cancel") { model.cancelAuthorization() }
            }
        }
    }

    private var repositoryStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            RepositoryPicker(model: model.repositorySelection)
            HStack {
                Text(selectionCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue") { model.continueFromRepositories() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.repositorySelection.canContinue)
            }
        }
    }

    private var selectionCaption: String {
        if model.repositorySelection.canContinue {
            return "\(model.repositorySelection.selectedIDs.count) selected"
        }
        return "Select at least one repository"
    }

    private var notificationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(GitHubAccessCopy.notificationSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let banner = model.bannerMessage {
                Text(banner)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.notificationDenied {
                Button("Continue") { model.continueAfterDenial() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    Button("Skip") { model.skipNotifications() }
                        .disabled(model.isWorking)
                    Spacer()
                    Button("Enable Notifications") {
                        Task { await model.enableNotifications() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                }
            }
        }
    }
}

struct RepositoryPicker: View {
    @Bindable var model: RepositorySelectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GitHubAccessCopy.allowlistSummary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Search repositories", text: $model.query)
                .textFieldStyle(.roundedBorder)

            if model.isLoading && model.choices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading repositories…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    Task { await model.retry() }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.filteredChoices.isEmpty && !model.isLoading {
                        Text(model.choices.isEmpty ? "No repositories" : "No repositories match")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.filteredChoices) { choice in
                        Toggle(
                            isOn: Binding(
                                get: { model.selectedIDs.contains(choice.id) },
                                set: { _ in model.toggle(choice.id) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.displayName)
                                    .font(.system(size: 13))
                                Text(choice.statusLabel)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(choice.displayName)
                        .accessibilityValue(choice.statusLabel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 280)
        }
    }
}

struct RepositoryEditorView: View {
    var model: RepositorySelectionModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repositories")
                .font(.system(size: 18, weight: .semibold))
            RepositoryPicker(model: model)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canContinue)
            }
        }
        .padding(20)
        .frame(width: 440, height: 580, alignment: .topLeading)
    }
}
