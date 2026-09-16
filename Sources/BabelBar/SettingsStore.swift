import SwiftUI
import Combine

/// Single source of truth for user settings. The overlay popover and the
/// Settings window both bind here. Session options are persisted in
/// UserDefaults; the API key lives in the Keychain.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // MARK: Session options

    @Published var languageHints: [String] {
        didSet { defaults.set(languageHints, forKey: "languageHints") }
    }
    @Published var strictLanguageHints: Bool {
        didSet { defaults.set(strictLanguageHints, forKey: "strictLanguageHints") }
    }
    @Published var speakerDiarization: Bool {
        didSet { defaults.set(speakerDiarization, forKey: "speakerDiarization") }
    }
    @Published var endpointDetection: Bool {
        didSet { defaults.set(endpointDetection, forKey: "endpointDetection") }
    }
    @Published var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: "translationEnabled") }
    }
    @Published var targetLanguage: String {
        didSet { defaults.set(targetLanguage, forKey: "targetLanguage") }
    }

    // MARK: API key (Keychain-backed; never written to UserDefaults)

    @Published var apiKey: String {
        didSet { Keychain.saveAPIKey(apiKey) }
    }

    // MARK: Audio

    /// Mix the microphone into the capture so the user's own speech is
    /// transcribed alongside system audio.
    @Published var captureMicrophone: Bool {
        didSet { defaults.set(captureMicrophone, forKey: "captureMicrophone") }
    }

    @Published var autoPauseEnabled: Bool {
        didSet { defaults.set(autoPauseEnabled, forKey: "autoPauseEnabled") }
    }

    // MARK: Window mode

    /// Pinned = borderless HUD floating above everything; unpinned = a normal
    /// titled window. Remembered across launches.
    @Published var isPinned: Bool {
        didSet { defaults.set(isPinned, forKey: "windowPinned") }
    }

    // MARK: Hotkeys (persisted key code + modifier flags)

    @Published var toggleAppShortcut: HotkeySpec {
        didSet { toggleAppShortcut.save(to: defaults, key: "hotkeyToggleApp") }
    }
    @Published var toggleRecordingShortcut: HotkeySpec {
        didSet { toggleRecordingShortcut.save(to: defaults, key: "hotkeyToggleRecording") }
    }

    private init() {
        languageHints = defaults.stringArray(forKey: "languageHints") ?? ["en"]
        strictLanguageHints = defaults.bool(forKey: "strictLanguageHints")
        speakerDiarization = defaults.bool(forKey: "speakerDiarization")
        endpointDetection = defaults.object(forKey: "endpointDetection") as? Bool ?? true
        translationEnabled = defaults.object(forKey: "translationEnabled") as? Bool ?? true
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "zh"
        apiKey = Keychain.loadAPIKey()
        captureMicrophone = defaults.bool(forKey: "captureMicrophone")
        autoPauseEnabled = defaults.bool(forKey: "autoPauseEnabled")
        isPinned = defaults.object(forKey: "windowPinned") as? Bool ?? true
        toggleAppShortcut = HotkeySpec.load(from: defaults, key: "hotkeyToggleApp")
            ?? HotkeySpec.defaultToggleApp
        toggleRecordingShortcut = HotkeySpec.load(from: defaults, key: "hotkeyToggleRecording")
            ?? HotkeySpec.defaultToggleRecording
        migrateAPIKeyFromDefaults()
    }

    /// Earlier builds kept the key in UserDefaults (plain text in the prefs
    /// plist). Move it into the Keychain once and scrub the plist entry.
    private func migrateAPIKeyFromDefaults() {
        guard let legacy = defaults.string(forKey: "apiKey") else { return }
        if apiKey.isEmpty, !legacy.isEmpty {
            apiKey = legacy  // didSet persists to the Keychain
        }
        defaults.removeObject(forKey: "apiKey")
    }

    /// Snapshot used to (re)start a transcription session.
    var transcriptionConfig: TranscriptionConfig {
        TranscriptionConfig(
            apiKey: apiKey,
            languageHints: languageHints,
            strictLanguageHints: strictLanguageHints && !languageHints.isEmpty,
            speakerDiarization: speakerDiarization,
            endpointDetection: endpointDetection,
            translationTarget: translationEnabled ? targetLanguage : nil
        )
    }

    // MARK: Overlay window frame persistence

    func saveOverlayFrame(_ frame: NSRect) {
        defaults.set(NSStringFromRect(frame), forKey: "overlayFrame")
    }

    func loadOverlayFrame() -> NSRect? {
        guard let s = defaults.string(forKey: "overlayFrame") else { return nil }
        let rect = NSRectFromString(s)
        return rect == .zero ? nil : rect
    }
}

/// A recorded global hotkey: Carbon key code + Cocoa modifier flags.
struct HotkeySpec: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let defaultToggleApp = HotkeySpec(keyCode: 37, modifiers: [.option, .command])       // ⌥⌘L
    static let defaultToggleRecording = HotkeySpec(keyCode: 15, modifiers: [.option, .command]) // ⌥⌘R

    func save(to defaults: UserDefaults, key: String) {
        defaults.set(["keyCode": Int(keyCode), "modifiers": Int(modifiers.rawValue)], forKey: key)
    }

    static func load(from defaults: UserDefaults, key: String) -> HotkeySpec? {
        guard let dict = defaults.dictionary(forKey: key),
              let code = dict["keyCode"] as? Int,
              let mods = dict["modifiers"] as? Int
        else { return nil }
        return HotkeySpec(keyCode: UInt32(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(mods)))
    }

    var display: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }
        return parts + KeyCodeNames.name(for: keyCode)
    }
}

/// Human-readable names for common virtual key codes.
enum KeyCodeNames {
    private static let map: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    static func name(for keyCode: UInt32) -> String {
        map[keyCode] ?? "Key\(keyCode)"
    }
}
