import AppKit
import SwiftUI

/// The caption window. One NSPanel, two modes, switched at runtime without
/// recreating the window (position, content, and scroll state survive):
///
/// - **Pinned** (floating): borderless, non-activating, above everything
///   including full-screen apps, on every Space. Clicking it never steals
///   focus from the meeting/video app.
/// - **Normal**: titled window with traffic lights (transparent titlebar,
///   glass extends edge-to-edge), normal level and Space behavior, appears
///   in the Window menu and Mission Control.
///
/// Closing the window in either mode stops transcription ("window visible =
/// transcribing"); the delegate reports it via `onUserClosed`.
@MainActor
final class CaptionWindowController: NSObject, NSWindowDelegate {
    private let panel: CaptionPanel
    private let effect = NSVisualEffectView()
    private let settings: SettingsStore
    private var frameSaveDebounce: Timer?

    /// Set by AppModel; called when the user closes the window (red light or ⌘W).
    var onUserClosed: (() -> Void)?

    /// Mirrors the SwiftUI chrome state so mode switches restore the right
    /// traffic-light alpha.
    private var chromeVisible = true

    init(model: AppModel, session: TranscriptionSession, settings: SettingsStore) {
        self.settings = settings

        let defaultFrame = NSRect(x: 0, y: 0, width: 640, height: 160)
        // .titled + .fullSizeContentView in BOTH modes: the glass fills the
        // whole frame and the (transparent) titlebar overlays it, so the
        // traffic lights sit embedded in the glass, Infuse-style. Mode
        // switching only toggles buttons/level/activation — the window is
        // never rebuilt between borderless and titled, which is exactly the
        // transition AppKit relayouts unreliably.
        panel = CaptionPanel(
            contentRect: Self.validatedFrame(settings.loadOverlayFrame()) ?? defaultFrame,
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "BabelBar"
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 360, height: 100)
        panel.isReleasedWhenClosed = false
        // The glass is dark in both modes; a fixed dark appearance keeps
        // titlebar buttons and popovers legible over it.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        // Glass: NSVisualEffectView (.hudWindow, behind-window) below the
        // SwiftUI content. It fills the entire frame (fullSizeContentView),
        // and the system's own corner rounding for titled windows clips it —
        // no manual mask needed.
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active

        let content = OverlayContentView(model: model)
            .environmentObject(session)
            .environmentObject(session.captions)
            .environmentObject(settings)
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Don't let SwiftUI's ideal size constrain the window: the panel is
        // freely resizable by edge-dragging, bounded only by panel.minSize.
        hosting.sizingOptions = []

        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        if Self.validatedFrame(settings.loadOverlayFrame()) == nil {
            centerNearBottom()
        }

        applyMode(pinned: settings.isPinned)
    }

    // MARK: Mode switching

    /// Reconfigures the live window in place; position, content, and scroll
    /// state survive.
    func applyMode(pinned: Bool) {
        let wasVisible = panel.isVisible

        if pinned {
            // Non-activating: clicking captions never steals focus from the
            // meeting/video app underneath. No visible chrome.
            panel.styleMask = [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel]
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.acceptsActivation = false
        } else {
            // A regular window: clicking activates the app, it stacks with
            // other windows, closes with ⌘W / the red light.
            panel.styleMask = [
                .titled, .fullSizeContentView, .resizable, .closable, .miniaturizable,
            ]
            panel.isFloatingPanel = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = .normal
            panel.collectionBehavior = [.managed, .fullScreenNone]
            panel.acceptsActivation = true
        }

        // The titlebar exists in both modes but never draws: content fills
        // the full frame and the traffic lights (normal mode only) float
        // embedded over the glass. Re-asserted after every mask change
        // because AppKit recreates titlebar internals with the mask.
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // A ScrollView in the content would otherwise trigger the automatic
        // titlebar separator — the telltale opaque-strip look.
        panel.titlebarSeparatorStyle = .none
        for buttonType in Self.trafficLights {
            let button = panel.standardWindowButton(buttonType)
            button?.isHidden = pinned
            button?.alphaValue = chromeVisible ? 1 : 0
        }
        // Mask changes don't reliably relayout the content under the
        // titlebar; forcing the frame does.
        panel.setFrame(panel.frame, display: true)

        if wasVisible {
            panel.orderFrontRegardless()
        }
    }

    private static let trafficLights: [NSWindow.ButtonType] = [
        .closeButton, .miniaturizeButton, .zoomButton,
    ]

    /// Fades the traffic lights with the overlay's glass bar: quick in
    /// (0.2 s), slow out (1 s), matching the SwiftUI animation.
    func setChromeVisible(_ visible: Bool) {
        chromeVisible = visible
        guard !settings.isPinned else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.2 : 1.0
            for buttonType in Self.trafficLights {
                panel.standardWindowButton(buttonType)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        if !settings.isPinned {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    /// Red light / ⌘W — "window visible = transcribing", so closing stops
    /// the session. The window is only ordered out (isReleasedWhenClosed is
    /// false) and can be reopened from the Dock, menu bar, or hotkey.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onUserClosed?()
        return true
    }

    func windowDidMove(_ notification: Notification) { debounceSaveFrame() }
    func windowDidResize(_ notification: Notification) { debounceSaveFrame() }

    // MARK: Frame persistence

    /// A saved frame is only restored if it is still meaningfully on some
    /// screen — otherwise (display unplugged, resolution changed) fall back
    /// to the default position.
    private static func validatedFrame(_ frame: NSRect?) -> NSRect? {
        guard let frame else { return nil }
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= 100 && overlap.height >= 50
        }
        return visible ? frame : nil
    }

    private func centerNearBottom() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: f.midX - size.width / 2,
            y: f.minY + f.height * 0.12
        ))
    }

    private func debounceSaveFrame() {
        frameSaveDebounce?.invalidate()
        frameSaveDebounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.settings.saveOverlayFrame(self.panel.frame)
            }
        }
    }
}

/// NSPanel whose key/main eligibility follows the current mode. In pinned
/// mode it never activates (clicks pass focus through to the app below);
/// in normal mode it behaves like a regular window.
private final class CaptionPanel: NSPanel {
    var acceptsActivation = false

    override var canBecomeKey: Bool {
        // Key status is needed for text selection and the settings popover
        // in both modes; .nonactivatingPanel keeps app activation away in
        // pinned mode.
        true
    }

    override var canBecomeMain: Bool { acceptsActivation }
}

