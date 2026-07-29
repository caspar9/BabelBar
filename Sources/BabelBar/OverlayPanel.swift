import AppKit
import SwiftUI

/// Borderless, non-activating panel that hosts the caption view over a HUD
/// glass background. Permanently pinned above everything (including
/// full-screen apps) and draggable anywhere by its background.
@MainActor
final class OverlayPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let settings: SettingsStore
    private var frameSaveDebounce: Timer?

    init(model: AppModel, session: TranscriptionSession, settings: SettingsStore) {
        self.settings = settings

        let defaultFrame = NSRect(x: 0, y: 0, width: 640, height: 140)
        panel = NSPanel(
            contentRect: Self.validatedFrame(settings.loadOverlayFrame()) ?? defaultFrame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar  // always pinned on top
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 360, height: 100)
        panel.delegate = self

        // Glass: NSVisualEffectView (.hudWindow, behind-window) below the SwiftUI content.
        // Rounded corners come from maskImage so the behind-window blur itself is
        // shaped — a layer cornerRadius clips content but leaves a square blur
        // region with hard-cut edges.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = .roundedCornerMask(radius: 16)

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
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

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

    // MARK: NSWindowDelegate — persist frame

    func windowDidMove(_ notification: Notification) { debounceSaveFrame() }
    func windowDidResize(_ notification: Notification) { debounceSaveFrame() }

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

extension NSImage {
    /// Stretchable rounded-rect alpha mask for NSVisualEffectView.maskImage.
    /// Cap insets keep the corners crisp at any panel size.
    static func roundedCornerMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
