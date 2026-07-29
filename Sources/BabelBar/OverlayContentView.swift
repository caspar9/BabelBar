import SwiftUI

/// SwiftUI content of the glass overlay: a reserved top control row (never
/// overlapping captions), scrollable caption history with each translated
/// sentence directly under its original, and a status row that is icon-only
/// except for errors, which show their text.
struct OverlayContentView: View {
    let model: AppModel

    @EnvironmentObject var session: TranscriptionSession
    @EnvironmentObject var captions: CaptionModel
    @EnvironmentObject var settings: SettingsStore

    @State private var hovering = false
    @State private var showSettingsPopover = false
    /// Auto-scroll follows new captions only while the user is at the bottom.
    @State private var stickToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            controlRow
                .frame(height: 30)
            captionArea
            statusRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
        // The panel's rounded shape comes from the effect view's maskImage,
        // which only masks the blur material — clip the SwiftUI layer to the
        // same radius so the tint and content match it.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.15)) { hovering = inside }
        }
    }

    // MARK: Control row (reserved space; buttons fade in on hover)

    private var controlRow: some View {
        HStack {
            Button {
                model.closeOverlayKeepingSession()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .help("Hide overlay (captions keep running)")
            .accessibilityLabel("Hide overlay")

            Spacer()

            HStack(spacing: 8) {
                Button {
                    session.toggle()
                } label: {
                    Image(systemName: session.isRunning ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(session.isRunning ? Color.red : Color.white.opacity(0.7))
                }
                .help(session.isRunning ? "Stop captions" : "Start captions")
                .accessibilityLabel(session.isRunning ? "Stop captions" : "Start captions")

                Button {
                    showSettingsPopover.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Quick settings")
                .accessibilityLabel("Quick settings")
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    QuickSettingsView()
                        .environmentObject(settings)
                }
            }
        }
        .font(.system(size: 14))
        .buttonStyle(.borderless)
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 10)
        .opacity(hovering || showSettingsPopover ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: hovering)
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

            // Original line
            (finalText(segment.originalFinal, size: 17, weight: .medium)
                + partialText(segment.originalPartial, size: 17, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if showTranslation && hasTranslation {
                Divider().opacity(0.2)
                (finalText(segment.translationFinal, size: 16, weight: .regular, opacity: 0.85)
                    + partialText(segment.translationPartial, size: 16, weight: .regular))
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
        _ s: String, size: CGFloat, weight: Font.Weight, opacity: Double = 1
    ) -> Text {
        Text(s)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white.opacity(opacity))
    }

    /// Provisional tokens render dimmer so updates feel fluid, not flickery.
    private func partialText(_ s: String, size: CGFloat, weight: Font.Weight) -> Text {
        Text(s)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white.opacity(0.55))
    }

    private func speakerColor(_ speaker: String) -> Color {
        let palette: [Color] = [.cyan, .orange, .green, .pink, .yellow, .purple]
        let idx = (Int(speaker) ?? abs(speaker.hashValue)) % palette.count
        return palette[abs(idx)]
    }
}
