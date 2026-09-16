import SwiftUI

/// SwiftUI content of the caption window: scrollable caption history (each
/// translated sentence directly under its original), a compact floating glass
/// control bar in the top-right corner (record / pin / settings) that appears
/// on hover, and a status row that is icon-only except for errors.
/// The bar and the window's traffic lights fade out together ~1 s after the
/// mouse leaves.
struct OverlayContentView: View {
    let model: AppModel

    @EnvironmentObject var session: TranscriptionSession
    @EnvironmentObject var captions: CaptionModel
    @EnvironmentObject var settings: SettingsStore

    @State private var hovering = false
    @State private var chromeVisible = true
    @State private var showSettingsPopover = false
    /// Auto-scroll follows new captions only while the user is at the bottom.
    @State private var stickToBottom = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                captionArea
                statusRow
            }
            // Content starts below the (transparent) titlebar so captions
            // never sit under the traffic lights or the control bar.
            .padding(.top, 30)

            // Top-right, inside the titlebar band: out of the reading line
            // (captions grow from the bottom) and mirroring the traffic
            // lights at top-left in normal mode.
            // 26 pt tall; top inset 3 centers it on the traffic lights' axis
            // (~16 pt from the top edge).
            controlBar
                .padding(.top, 3)
                .padding(.trailing, 7)
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The transparent titlebar is reported as a top safe-area inset,
        // which would push everything down by another titlebar height. We
        // lay out relative to the window's true top edge instead.
        .ignoresSafeArea(.container, edges: .top)
        .background(Color.black.opacity(0.45))
        .onHover { inside in
            hovering = inside
            updateChrome()
        }
        .onChange(of: showSettingsPopover) {
            updateChrome()
        }
        .task {
            // Chrome starts visible for discoverability, then fades if the
            // mouse isn't over the window.
            try? await Task.sleep(for: .seconds(2.5))
            if !hovering && !showSettingsPopover { updateChrome() }
        }
    }

    /// Chrome (glass bar + traffic lights) shows while the mouse is over the
    /// window or the settings popover is open; it fades in fast (0.2 s) and
    /// out slow (1 s), traffic lights in lockstep via the window controller.
    private func updateChrome() {
        let visible = hovering || showSettingsPopover
        withAnimation(.easeInOut(duration: visible ? 0.2 : 1.0)) {
            chromeVisible = visible
        }
        model.setWindowChromeVisible(visible)
    }

    // MARK: Floating glass control bar

    private var controlBar: some View {
        HStack(spacing: 6) {
            barButton(
                symbol: session.isRunning ? "stop.fill" : "record.circle",
                tint: session.isRunning ? .red : .white.opacity(0.85),
                help: session.isRunning ? "Stop captions" : "Start captions"
            ) {
                session.toggle()
            }

            barButton(
                symbol: settings.isPinned ? "pin.fill" : "pin",
                tint: .white.opacity(0.85),
                help: settings.isPinned ? "Unpin: normal window" : "Pin above all windows"
            ) {
                settings.isPinned.toggle()
            }

            barButton(
                symbol: "gearshape.fill",
                tint: .white.opacity(0.85),
                help: "Settings"
            ) {
                showSettingsPopover.toggle()
            }
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                QuickSettingsView()
                    .environmentObject(settings)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }

    private func barButton(
        symbol: String, tint: Color, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Captions

    private var captionArea: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(visibleSegments) { segment in
                                SegmentView(
                                    segment: segment,
                                    showTranslation: settings.translationEnabled,
                                    showSpeaker: settings.speakerDiarization
                                )
                                .id(segment.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .background(
                            GeometryReader { content in
                                Color.clear.preference(
                                    key: ContentBottomKey.self,
                                    value: content.frame(in: .named("captionScroll")).maxY
                                )
                            }
                        )
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .coordinateSpace(name: "captionScroll")
                    .onPreferenceChange(ContentBottomKey.self) { contentBottom in
                        stickToBottom = contentBottom <= viewport.size.height + 24
                    }
                    .onChange(of: captions.segments) {
                        guard stickToBottom else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }

                    if !stickToBottom {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .help("Jump to latest")
                        .accessibilityLabel("Jump to latest captions")
                        .padding(10)
                    }
                }
            }
        }
    }

    private var visibleSegments: [CaptionSegment] {
        captions.segments.filter { !$0.isEmpty }
    }

    // MARK: Status row — icon-only, except errors which must be readable

    @ViewBuilder
    private var statusRow: some View {
        if let status = statusContent {
            HStack(spacing: 6) {
                Image(systemName: status.symbol)
                    .symbolEffect(.pulse, options: .repeating, isActive: status.pulsing)
                if let text = status.text {
                    Text(text).lineLimit(2)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(status.isError ? .yellow.opacity(0.9) : .white.opacity(0.55))
            .help(status.help)
            .accessibilityLabel(status.help)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private struct Status {
        var symbol: String
        var help: String
        var pulsing = false
        /// Errors show text inline; other states are icon-only with a tooltip.
        var text: String?
        var isError = false
    }

    private var statusContent: Status? {
        switch session.state {
        case .idle:
            return Status(symbol: "pause.circle", help: "Captions stopped")
        case .starting:
            return Status(symbol: "ellipsis.circle", help: "Starting…", pulsing: true)
        case .running:
            return visibleSegments.isEmpty
                ? Status(symbol: "waveform", help: "Listening…", pulsing: true)
                : nil
        case .reconnecting(let attempt):
            return Status(
                symbol: "wifi.exclamationmark",
                help: "Reconnecting… (attempt \(attempt))",
                pulsing: true
            )
        case .restarting:
            return Status(
                symbol: "arrow.triangle.2.circlepath",
                help: "Restarting with new settings…",
                pulsing: true
            )
        case .autoPaused:
            return Status(
                symbol: "moon.zzz",
                help: "Auto-paused after 30 s of silence",
                text: "Auto-paused (silence)"
            )
        case .needsAPIKey:
            return Status(
                symbol: "key",
                help: "Add your Soniox API key in Settings",
                text: "Add your API key in Settings",
                isError: true
            )
        case .error(let message):
            return Status(
                symbol: "exclamationmark.triangle",
                help: message,
                text: message,
                isError: true
            )
        }
    }
}

/// Bottom edge of the caption content in scroll coordinates, used to detect
/// whether the user is scrolled to the latest captions.
private struct ContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Caption colors

/// Original speech vs. its translation are told apart by color, not size:
/// white for what was said, warm amber for the translation. Both were tuned
/// against the dark HUD glass (~45% black over blur) for contrast.
private enum CaptionPalette {
    static let original = Color.white.opacity(0.96)
    /// Amber rather than pure orange: less saturated on dark glass, still
    /// unmistakably "the other line".
    static let translation = Color(red: 1.0, green: 0.74, blue: 0.36)
}

// MARK: - One sentence block: original + its translation, kept together

private struct SegmentView: View {
    let segment: CaptionSegment
    let showTranslation: Bool
    let showSpeaker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showSpeaker, let speaker = segment.speaker {
                speakerChip(speaker)
            }

            // Original line: white, medium weight.
            (finalText(segment.originalFinal, size: 17, weight: .medium, color: CaptionPalette.original)
                + partialText(segment.originalPartial, size: 17, weight: .medium, color: CaptionPalette.original))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // Translation line: warm amber, semibold — reads as a distinct
            // layer from the original at a glance, without competing in size.
            if showTranslation && hasTranslation {
                Divider().opacity(0.2)
                (finalText(segment.translationFinal, size: 16, weight: .semibold, color: CaptionPalette.translation)
                    + partialText(segment.translationPartial, size: 16, weight: .semibold, color: CaptionPalette.translation))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        // History stays readable when scrolled back; the live block stands out.
        .opacity(segment.isClosed ? 0.78 : 1)
        .animation(.easeOut(duration: 0.15), value: segment)
    }

    private var hasTranslation: Bool {
        !segment.translationFinal.isEmpty || !segment.translationPartial.isEmpty
    }

    private func speakerChip(_ speaker: String) -> some View {
        Text("Speaker \(speaker)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.black.opacity(0.8))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(speakerColor(speaker)))
    }

    private func finalText(
        _ s: String, size: CGFloat, weight: Font.Weight, color: Color
    ) -> Text {
        Text(s)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
    }

    /// Provisional tokens render dimmer so updates feel fluid, not flickery.
    private func partialText(_ s: String, size: CGFloat, weight: Font.Weight, color: Color) -> Text {
        Text(s)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color.opacity(0.55))
    }

    private func speakerColor(_ speaker: String) -> Color {
        // No orange/yellow here: those are reserved for the translation line.
        let palette: [Color] = [.cyan, .mint, .green, .pink, .indigo, .purple]
        let idx = (Int(speaker) ?? abs(speaker.hashValue)) % palette.count
        return palette[abs(idx)]
    }
}
