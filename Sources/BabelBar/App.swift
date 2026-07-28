import AppKit
import Combine
import SwiftUI

/// App wiring: menu bar status item, overlay, session, settings window, hotkeys.
@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate {
    static var shared: AppCoordinator?

    let settings = SettingsStore.shared
    private(set) var session: TranscriptionSession!
    private(set) var overlay: OverlayPanelController?

    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        session = TranscriptionSession(settings: settings)
        overlay = OverlayPanelController(session: session, settings: settings)

        setupStatusItem()
        setupHotkeys()

        // Menu-bar icon mirrors recording state.
        session.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in self?.updateStatusIcon(recording: running) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
    }

    // MARK: Status item + menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(makeItem("Start Captions", action: #selector(toggleCaptions), key: "s", tag: 1))
        menu.addItem(makeItem("Show Overlay", action: #selector(toggleOverlay), key: "o", tag: 2))
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit BabelBar", action: #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func makeItem(
        _ title: String, action: Selector, key: String, tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        return item
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        let name = recording ? "captions.bubble.fill" : "captions.bubble"
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: recording ? "Captions running" : "Captions idle"
        )
        if recording {
            button.image = image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            )
        } else {
            button.image = image
        }
    }

    // MARK: Actions

    @objc private func toggleCaptions() {
        if !session.isRunning {
            overlay?.show()
        }
        session.toggle()
    }

    @objc private func toggleOverlay() {
        overlay?.toggleVisible()
    }

    /// Close button on the overlay: stop the session and hide the panel.
    func closeOverlay() {
        session.stop()
        overlay?.hide()
    }

    @objc private func openSettings() {
        openSettingsWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func openSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "BabelBar Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsRootView().environmentObject(settings)
            )
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Hotkeys

    private func setupHotkeys() {
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleApp:
                // Quick-open: show + start if idle; hide everything if active.
                if self.session.isRunning || self.overlay?.isVisible == true {
                    self.session.stop()
                    self.overlay?.hide()
                } else {
                    self.overlay?.show()
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

    private func applyHotkeySpecs() {
        hotkeys.apply(
            toggleApp: settings.toggleAppShortcut,
            toggleRecording: settings.toggleRecordingShortcut
        )
    }
}

// MARK: Menu state

extension AppCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.title = session.isRunning ? "Stop Captions" : "Start Captions"
        menu.item(withTag: 2)?.title =
            overlay?.isVisible == true ? "Hide Overlay" : "Show Overlay"
    }
}

// MARK: - Entry point

@main
struct BabelBarMain {
    static func main() {
        let app = NSApplication.shared
        let coordinator = MainActor.assumeIsolated { AppCoordinator() }
        app.delegate = coordinator
        app.setActivationPolicy(.accessory)  // LSUIElement: menu bar only, no Dock icon
        app.run()
    }
}
