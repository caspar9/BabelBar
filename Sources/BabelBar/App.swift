import AppKit
import Combine
import SwiftUI

/// SwiftUI App lifecycle. BabelBar is a regular app (Dock icon, ⌘Tab, main
/// menu) whose main window is the caption window — an AppKit panel that can
/// be pinned above everything or live as a normal titled window. All controls
/// live on the window's floating glass bar; the Settings scene provides the
/// full preferences window (⌘, or via the glass bar's gear popover).
@main
struct BabelBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView()
                .environmentObject(appDelegate.model.settings)
        }
        .commands {
            AppCommands(model: appDelegate.model)
        }
    }
}

/// Main-menu additions. The caption window is an AppKit panel, so the
/// standard View/Window menus don't know about it — expose its controls here.
private struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Float on Top", isOn: $settings.isPinned)
                .keyboardShortcut("p", modifiers: [.shift, .command])

            Button(model.overlayVisible ? "Close Captions Window" : "Show Captions Window") {
                model.toggleOverlay()
            }
            .keyboardShortcut("0", modifiers: [.shift, .command])

            Divider()

            Button(model.session.isRunning ? "Stop Captions" : "Start Captions") {
                model.toggleCaptions()
            }
        }
    }
}

// MARK: - App model (composition root)

/// Owns the object graph and the caption window. Views talk to this model;
/// lower layers (session, provider, audio) never reach up into UI.
@MainActor
final class AppModel: ObservableObject {
    let settings = SettingsStore.shared
    let session: TranscriptionSession
    let hotkeys = HotkeyManager()

    @Published private(set) var overlayVisible = false

    private var window: CaptionWindowController?
    private var cancellables = Set<AnyCancellable>()

    init() {
        session = TranscriptionSession(settings: settings)

        // needsAPIKey is a session state, but routing the user to Settings is
        // a UI decision — made here, not in the session layer.
        session.$state.sink { [weak self] state in
            if state == .needsAPIKey {
                self?.openSettingsForAPIKey()
            }
        }.store(in: &cancellables)

        // Pin toggle — from the menu bar, main menu, or the window's pin
        // button — reconfigures the live window.
        settings.$isPinned
            .dropFirst()
            .sink { [weak self] pinned in
                self?.window?.applyMode(pinned: pinned)
            }
            .store(in: &cancellables)

        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleApp:
                // Quick-open: show + start if idle; close everything if active.
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
        settings.$toggleAppShortcut
            .combineLatest(settings.$toggleRecordingShortcut)
            .dropFirst()
            .sink { [weak self] _, _ in self?.applyHotkeySpecs() }
            .store(in: &cancellables)
    }

    // MARK: Caption window

    func showOverlay() {
        if window == nil {
            let controller = CaptionWindowController(
                model: self, session: session, settings: settings
            )
            controller.onUserClosed = { [weak self] in self?.userClosedWindow() }
            window = controller
        }
        window?.show()
        overlayVisible = true
    }

    func hideOverlay() {
        window?.hide()
        overlayVisible = false
    }

    /// "Window visible = transcribing": dismissing the window from any entry
    /// point (menu, hotkey, close button) also stops the session.
    func toggleOverlay() {
        if overlayVisible {
            session.stop()
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    func toggleCaptions() {
        if !session.isRunning {
            showOverlay()
        }
        session.toggle()
    }

    /// Window closed by the user via AppKit chrome (red light or ⌘W):
    /// window visible = transcribing, so the session stops too. The app stays
    /// in the Dock and menu bar for quick reopening.
    func userClosedWindow() {
        session.stop()
        overlayVisible = false
    }

    /// The overlay's hover state drives the traffic lights so window chrome
    /// and the glass bar fade in and out together.
    func setWindowChromeVisible(_ visible: Bool) {
        window?.setChromeVisible(visible)
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

/// Thin delegate: standard app activation, Dock reopen behavior, and clean
/// session shutdown on quit.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @MainActor lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("BabelBar launched")
        Task { @MainActor in
            model.showOverlay()
        }
    }

    /// Clicking the Dock icon with no visible windows reopens the caption window.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        Task { @MainActor in
            if !model.overlayVisible {
                model.showOverlay()
            }
        }
        return true
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
