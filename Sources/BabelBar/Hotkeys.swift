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

/// Click, then press the desired combination; Esc cancels, ⌫ isn't captured as
/// a shortcut. Captures keys with a local NSEvent monitor while recording.
struct ShortcutRecorder: View {
    let title: String
    @Binding var spec: HotkeySpec

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            Button {
                recording ? endRecording() : beginRecording()
            } label: {
                Text(recording ? "Press keys…" : spec.display)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
        }
        .onDisappear { endRecording() }
    }

    private func beginRecording() {
        recording = true
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
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
