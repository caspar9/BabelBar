import SwiftUI

/// The full Settings window: Account / Transcription / Shortcuts tabs.
struct SettingsRootView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView {
            AccountTab()
                .tabItem { Label("Account", systemImage: "person.badge.key") }
            SessionOptionsForm()
                .tabItem { Label("Transcription", systemImage: "captions.bubble") }
            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - Account tab

private struct AccountTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var testState: TestState = .none

    enum TestState: Equatable {
        case none, testing
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Soniox API Key") {
                SecureField("API key", text: $settings.apiKey, prompt: Text("sk-…"))
                    .textContentType(.password)
                Text("Stored securely in the macOS Keychain. Get a key at soniox.com.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Connection") {
                    HStack(spacing: 10) {
                        switch testState {
                        case .none:
                            EmptyView()
                        case .testing:
                            ProgressView().controlSize(.small)
                        case .success:
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                        Button("Test Connection") {
                            runTest()
                        }
                        .disabled(testState == .testing || settings.apiKey.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func runTest() {
        testState = .testing
        let key = settings.apiKey
        Task {
            let result = await SonioxConnectionTest.run(apiKey: key)
            switch result {
            case .success:
                testState = .success
            case .failure(let err):
                testState = .failure(err.message)
            }
        }
    }
}

// MARK: - Shortcuts tab

private struct ShortcutsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Global Shortcuts") {
                ShortcutRecorder(
                    title: "Toggle app (overlay + captions)",
                    spec: $settings.toggleAppShortcut
                )
                ShortcutRecorder(
                    title: "Start/Stop recording",
                    spec: $settings.toggleRecordingShortcut
                )
            }
            Section {
                Text("Shortcuts work system-wide, even while Zoom or a video player is focused. Click a shortcut, then press the new key combination (must include ⌘, ⌥, ⌃ or ⇧).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
