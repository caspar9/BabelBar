import AppKit
import Combine
import SwiftUI

/// SwiftUI App lifecycle: MenuBarExtra for the status item, a Settings scene
/// for preferences (which also gives us the standard main menu, ⌘, shortcut,
/// and Edit-menu clipboard handling for free). The caption overlay is the one
/// piece SwiftUI scenes can't express — a non-activating NSPanel — owned by
/// AppModel.
@main
struct BabelBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            StatusIcon(session: appDelegate.model.session)
        }

        Settings {
            SettingsRootView()
                .environmentObject(appDelegate.model.settings)
        }
    }
}

/// Status-item icon. Rendered as a template image per HIG — state is conveyed
/// by symbol variant, not color. A plain closure in `label:` would not observe
/// the session, so this is a separate observing view.
private struct StatusIcon: View {
    @ObservedObject var session: TranscriptionSession

    var body: some View {
        let recording = session.isRunning
        Image(systemName: recording ? "captions.bubble.fill" : "captions.bubble")
            .accessibilityLabel(recording ? "BabelBar, captions running" : "BabelBar, idle")
    }
}

/// Menu shown from the status item.
private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TranscriptionSession
    @Environment(\.openSettings) private var openSettings

    init(model: AppModel) {
        self.model = model
        self.session = model.session
    }

    var body: some View {
        Button(session.isRunning ? "Stop Captions" : "Start Captions") {
            model.toggleCaptions()
        }
        Button(model.overlayVisible ? "Hide Overlay" : "Show Overlay") {
            model.toggleOverlay()
        }
        Divider()
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit BabelBar") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - App model (composition root)

/// Owns the object graph and the overlay panel. Views talk to this model;
/// lower layers (session, provider, audio) never reach up into UI.
@MainActor
final class AppModel: ObservableObject {
    let settings = SettingsStore.shared
    let session: TranscriptionSession
    let hotkeys = HotkeyManager()

    @Published private(set) var overlayVisible = false

    private var overlay: OverlayPanelController?
    private var stateObservation: AnyCancellable?
    private var hotkeyObservation: AnyCancellable?

    init() {
        session = TranscriptionSession(settings: settings)

        // needsAPIKey is a session state, but routing the user to Settings is
        // a UI decision — made here, not in the session layer.
        stateObservation = session.$state.sink { [weak self] state in
            if state == .needsAPIKey {
                self?.openSettingsForAPIKey()
            }
        }

        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleApp:
                // Quick-open: show + start if idle; hide everything if active.
                if self.session.isRunning || self.overlayVisible {
                    self.session.stop()
                    self.hideOverlay()
                } else {
                    self.showOverlay()
                    self.session.start()
                }
            case .toggleRecording:
                self.session.toggle()
            }
        }
        applyHotkeySpecs()
        hotkeyObservation = settings.$toggleAppShortcut
            .combineLatest(settings.$toggleRecordingShortcut)
            .dropFirst()
            .sink { [weak self] _, _ in self?.applyHotkeySpecs() }
    }

    // MARK: Overlay

    func showOverlay() {
        if overlay == nil {
            overlay = OverlayPanelController(model: self, session: session, settings: settings)
        }
        overlay?.show()
        overlayVisible = true
    }

    func hideOverlay() {
        overlay?.hide()
        overlayVisible = false
    }

    func toggleOverlay() {
        overlayVisible ? hideOverlay() : showOverlay()
    }

    /// Close button on the overlay: hide the panel only — the session keeps
    /// running (the menu bar icon still shows recording state).
    func closeOverlayKeepingSession() {
        hideOverlay()
    }

    func toggleCaptions() {
        if !session.isRunning {
            showOverlay()
        }
        session.toggle()
    }

    private func openSettingsForAPIKey() {
        // The openSettings environment action only exists inside scene views,
        // so the model uses the selector-based fallback.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }

    private func applyHotkeySpecs() {
        hotkeys.apply(
            toggleApp: settings.toggleAppShortcut,
            toggleRecording: settings.toggleRecordingShortcut
        )
    }
}

/// Thin delegate: keeps the app an accessory (LSUIElement) and stops the
/// session cleanly on quit.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @MainActor lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.app.info("BabelBar launched")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.session.isRunning else { return .terminateNow }
        // Give the provider a beat to send end-of-audio and drain.
        Task { @MainActor in
            model.session.stop()
            try? await Task.sleep(for: .seconds(1))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
