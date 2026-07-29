import AppKit
import Carbon.HIToolbox

/// Registers user-configurable global hotkeys via Carbon RegisterEventHotKey so
/// they fire while other apps (Zoom, video players) are focused.
@MainActor
final class HotkeyManager {
    enum Action: UInt32 {
        case toggleApp = 1
        case toggleRecording = 2
    }

    var onAction: ((Action) -> Void)?

    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4D_54_52_4E  // 'MTRN'

    init() {
        installHandler()
    }

    func apply(toggleApp: HotkeySpec, toggleRecording: HotkeySpec) {
        register(spec: toggleApp, action: .toggleApp)
        register(spec: toggleRecording, action: .toggleRecording)
    }

    private func register(spec: HotkeySpec, action: Action) {
        if let old = hotKeyRefs[action] {
            UnregisterEventHotKey(old)
            hotKeyRefs[action] = nil
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            spec.keyCode,
            carbonModifiers(from: spec.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[action] = ref
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if hotKeyID.signature == HotkeyManager.signature,
                   let action = Action(rawValue: hotKeyID.id) {
                    Task { @MainActor in
                        manager.onAction?(action)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }
}

// MARK: - Shortcut recorder control (Settings → Shortcuts)

import SwiftUI

/// Shared coordinator so only one recorder captures keys at a time — starting
/// a recording cancels any other active recorder.
@MainActor
final class ShortcutRecordingCoordinator: ObservableObject {
    static let shared = ShortcutRecordingCoordinator()
    @Published var activeRecorder: UUID?
}

/// Click, then press the desired combination; Esc cancels. A reset button
/// restores the default. Captures keys with a local NSEvent monitor while
/// recording.
struct ShortcutRecorder: View {
    let title: String
    let defaultSpec: HotkeySpec
    @Binding var spec: HotkeySpec

    @StateObject private var coordinator = ShortcutRecordingCoordinator.shared
    @State private var id = UUID()
    @State private var monitor: Any?

    private var recording: Bool { coordinator.activeRecorder == id }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Button {
                    recording ? endRecording() : beginRecording()
                } label: {
                    Text(recording ? "Press keys…" : spec.display)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .tint(recording ? .accentColor : nil)
                .accessibilityLabel("\(title) shortcut: \(spec.display)")

                Button {
                    endRecording()
                    spec = defaultSpec
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to default (\(defaultSpec.display))")
                .accessibilityLabel("Reset \(title) to default")
                .disabled(spec == defaultSpec)
            }
        }
        .onChange(of: coordinator.activeRecorder) { _, active in
            // Another recorder took over — drop this one's monitor.
            if active != id { removeMonitor() }
        }
        .onDisappear { endRecording() }
    }

    private func beginRecording() {
        coordinator.activeRecorder = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { endRecording() }
            if event.keyCode == UInt16(kVK_Escape) { return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { return nil }  // require at least one modifier
            spec = HotkeySpec(keyCode: UInt32(event.keyCode), modifiers: flags)
            return nil
        }
    }

    private func endRecording() {
        if recording {
            coordinator.activeRecorder = nil
        }
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
