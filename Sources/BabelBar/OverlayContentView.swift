import SwiftUI

/// SwiftUI content of the glass overlay: scrollable caption history (each
/// translated sentence directly under its original), hover controls (close /
/// record / settings), and an icon-only status footer for transient states.
struct OverlayContentView: View {
    @EnvironmentObject var session: TranscriptionSession
    @EnvironmentObject var captions: CaptionModel
    @EnvironmentObject var settings: SettingsStore

    @State private var hovering = false
    @State private var showSettingsPopover = false
    /// Auto-scroll follows new captions only while the user is at the bottom.
    @State private var stickToBottom = true

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                captionArea
                statusFooter
            }
            if hovering || showSettingsPopover {
                controlBar
                    .transition(.opacity)
            }
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
                        .padding(.top, 12)
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
                        .padding(10)
                    }
                }
            }
        }
    }

    private var visibleSegments: [CaptionSegment] {
        captions.segments.filter { !$0.isEmpty }
    }

    // MARK: Status footer — icon only; the tooltip carries the words

    @ViewBuilder
    private var statusFooter: some View {
        if let (symbol, help, pulsing) = footerContent {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing)
                .help(help)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    private var footerContent: (symbol: String, help: String, pulsing: Bool)? {
        switch captions.state {
        case .idle:
            return ("pause.circle", "Captions stopped", false)
        case .starting:
            return ("ellipsis.circle", "Starting…", true)
        case .running:
            return visibleSegments.isEmpty ? ("waveform", "Listening…", true) : nil
        case .reconnecting(let attempt):
            return ("wifi.exclamationmark", "Reconnecting… (attempt \(attempt))", true)
        case .restarting:
            return ("arrow.triangle.2.circlepath", "Restarting with new settings…", true)
        case .autoPaused:
            return ("moon.zzz", "Auto-paused after 30 s of silence", false)
        case .error(let message):
            return ("exclamationmark.triangle", message, false)
        }
    }

    // MARK: Hover controls

    private var controlBar: some View {
        HStack {
            Button {
                AppCoordinator.shared?.closeOverlay()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .help("Close overlay (stops captions)")

            Spacer()

            HStack(spacing: 8) {
                Button {
                    session.toggle()
                } label: {
                    Image(systemName: session.isRunning ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(session.isRunning ? Color.red : Color.white.opacity(0.7))
                }
                .help(session.isRunning ? "Stop captions" : "Start captions")

                Button {
                    showSettingsPopover.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Quick settings")
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    QuickSettingsView()
                        .environmentObject(settings)
                }
            }
        }
        .font(.system(size: 14))
        .buttonStyle(.borderless)
        .foregroundStyle(.white.opacity(0.7))
        .padding(8)
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

            if showTranslation && hasTranslation {
                Divider().opacity(0.2)
                (finalText(segment.translationFinal, size: 16, weight: .regular, opacity: 0.85)
                    + partialText(segment.translationPartial, size: 16, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
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
