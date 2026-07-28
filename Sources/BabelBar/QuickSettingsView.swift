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

/// The gear-button popover on the overlay.
struct QuickSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Session Options")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            SessionOptionsForm()
                .scrollContentBackground(.hidden)
            Text("Changes restart the live session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(width: 340, height: 430)
    }
}
