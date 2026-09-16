import SwiftUI

/// Session options form. Used both as the overlay gear popover and embedded in
/// the Settings window's Transcription tab — one source of truth (SettingsStore).
struct SessionOptionsForm: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Language hints") {
                LanguageChips(selection: $settings.languageHints)
                Toggle("Strict language hints", isOn: $settings.strictLanguageHints)
                    .disabled(settings.languageHints.isEmpty)
                    .help("Only transcribe the hinted languages.")
            }

            Section("Recognition") {
                Toggle("Speaker diarization", isOn: $settings.speakerDiarization)
                Toggle("Endpoint detection", isOn: $settings.endpointDetection)
                    .help("Split captions at natural utterance boundaries.")
            }

            Section("Audio") {
                Toggle("Also capture microphone", isOn: $settings.captureMicrophone)
                    .help("Mix your microphone into the capture so your own speech is transcribed too — useful in meetings.")
                Toggle("Auto-pause after 30 s of silence", isOn: $settings.autoPauseEnabled)
                    .help("Stops transcription automatically when no audio is playing, so silence doesn't burn API minutes.")
            }

            Section("Translation") {
                Toggle("Enable translation", isOn: $settings.translationEnabled)
                if settings.translationEnabled {
                    Picker("Target language", selection: $settings.targetLanguage) {
                        ForEach(Language.translationTargets) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(AccentSwitchStyle())
    }
}

/// A switch that is always drawn in the accent color when on. The system
/// switch renders grey whenever the app is inactive — which is permanently
/// the case for the non-activating pinned caption window and its popover —
/// so on/off became hard to tell apart. Drawing it ourselves sidesteps that.
struct AccentSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.22))
                .frame(width: 38, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .padding(2)
                }
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
                .contentShape(Capsule())
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

/// Toggleable chips for the language-hint multi-select.
struct LanguageChips: View {
    @Binding var selection: [String]

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Language.hintOptions) { lang in
                let isOn = selection.contains(lang.code)
                Button {
                    if isOn {
                        selection.removeAll { $0 == lang.code }
                    } else {
                        selection.append(lang.code)
                    }
                } label: {
                    Text(lang.name)
                        .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.08))
                        )
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The gear-button popover on the overlay's glass bar.
struct QuickSettingsView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Session Options")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            SessionOptionsForm()
                .scrollContentBackground(.hidden)
            HStack {
                Text("Changes restart the live session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .frame(width: 340, height: 480)
        // The overlay control bar's styling (white foreground, 14 pt font,
        // borderless buttons) leaks into this popover through the environment
        // of its anchor view. Reset so the popover follows the system
        // light/dark appearance instead of the dark overlay's.
        .font(.body)
        .foregroundStyle(Color.primary)
        .buttonStyle(.automatic)
    }
}
