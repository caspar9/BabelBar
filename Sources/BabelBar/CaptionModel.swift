import SwiftUI

/// One sentence block shown in the overlay: an original sentence and its
/// translation, kept together so scrolling back always shows the pair.
struct CaptionSegment: Identifiable, Equatable {
    let id: UUID
    var originalFinal = ""
    var originalPartial = ""
    var translationFinal = ""
    var translationPartial = ""
    var speaker: String?
    /// An utterance boundary passed — the original text is complete, but the
    /// block may stay open a little longer for its trailing translation.
    var originalSealed = false
    /// Fully complete (original + translation); receives no further tokens.
    var isClosed = false

    init(id: UUID = UUID()) { self.id = id }

    var isEmpty: Bool {
        originalFinal.isEmpty && originalPartial.isEmpty
            && translationFinal.isEmpty && translationPartial.isEmpty
    }
}

/// Turns transcript events into renderable caption blocks. Owns only caption
/// content — session state lives on `TranscriptionSession`.
///
/// Blocks are split per sentence so each translated sentence sits directly
/// under its original. Translation tokens trail the original by up to a couple
/// of seconds, so a block whose original is complete stays open until its
/// translation is complete too; original tokens for the next sentence open a
/// new block in the meantime. Because translations can also trail an utterance
/// endpoint, `<end>` only *seals* open blocks (no more original text) — they
/// close when their translation completes, or at the latest at the next
/// endpoint. Final text is committed and immutable; partial text is replaced
/// wholesale on every event.
@MainActor
final class CaptionModel: ObservableObject {
    /// Scrollback history plus open blocks; the last element is the live block.
    @Published private(set) var segments = [CaptionSegment()]

    /// Set by the session when translation is on, so a block waits for its
    /// translation before closing.
    var expectsTranslation = false

    private let maxSegments = 50

    var liveIndex: Int { segments.count - 1 }

    func reset() {
        segments = [CaptionSegment()]
    }

    func apply(_ event: TranscriptEvent) {
        switch event {
        case .partial(let tokens):
            applyPartials(tokens)
        case .final(let tokens):
            applyFinals(tokens)
        case .utteranceEnd:
            handleUtteranceEnd()
        case .speakerChange(let speaker):
            handleUtteranceEnd()
            segments[liveIndex].speaker = speaker
        case .reconnecting:
            // Provisional tokens from the dead connection will never finalize.
            clearPartials()
        case .finished:
            forceCloseAll()
        case .connected, .error:
            break  // session-state events; handled by TranscriptionSession
        }
    }

    // MARK: Token routing

    private func applyFinals(_ tokens: [TranscriptToken]) {
        for token in tokens {
            switch token.kind {
            case .original:
                // A block whose original sentence is done (sealed, or ended
                // with terminal punctuation) takes no more original text —
                // the next sentence opens a new block.
                if segments[liveIndex].originalSealed
                    || Self.endsSentence(segments[liveIndex].originalFinal) {
                    segments[liveIndex].originalPartial = ""
                    segments.append(CaptionSegment())
                }
                segments[liveIndex].originalFinal += token.text
                if segments[liveIndex].speaker == nil, let sp = token.speaker {
                    segments[liveIndex].speaker = sp
                }

            case .translation:
                let idx = translationTargetIndex()
                segments[idx].translationFinal += token.text
            }
        }
        closeCompletedBlocks()
        trimHistory()
    }

    private func applyPartials(_ tokens: [TranscriptToken]) {
        let original = tokens.filter { $0.kind == .original }.map(\.text).joined()
        let translation = tokens.filter { $0.kind == .translation }.map(\.text).joined()

        clearPartials()
        segments[liveIndex].originalPartial = original
        segments[translationTargetIndex()].translationPartial = translation

        if segments[liveIndex].speaker == nil,
           let sp = tokens.compactMap(\.speaker).first {
            segments[liveIndex].speaker = sp
        }
    }

    /// Translation trails the original, so it belongs to the oldest open block
    /// that has original text and whose translation is still incomplete.
    private func translationTargetIndex() -> Int {
        for (idx, seg) in segments.enumerated()
        where !seg.isClosed && !seg.originalFinal.isEmpty
            && !Self.endsSentence(seg.translationFinal) {
            return idx
        }
        return liveIndex
    }

    // MARK: Block lifecycle

    /// A block closes when its original is done (terminal punctuation or
    /// sealed by an endpoint) and — if translation is expected — the
    /// translation is complete as well.
    private func closeCompletedBlocks() {
        for idx in segments.indices {
            let seg = segments[idx]
            guard !seg.isClosed, !seg.originalFinal.isEmpty else { continue }
            let originalDone = seg.originalSealed || Self.endsSentence(seg.originalFinal)
            let translationDone = !expectsTranslation || Self.endsSentence(seg.translationFinal)
            if originalDone && translationDone {
                segments[idx].isClosed = true
                segments[idx].originalPartial = ""
                segments[idx].translationPartial = ""
            }
        }
        ensureOpenLive()
    }

    /// Endpoint boundary. Blocks sealed at an *earlier* endpoint have had a
    /// full utterance of time for their translation to arrive — close them
    /// as-is so nothing can stay stuck open. Blocks from the utterance that
    /// just ended are sealed but stay open for their trailing translation.
    private func handleUtteranceEnd() {
        clearPartials()
        for idx in segments.indices where !segments[idx].isClosed && !segments[idx].isEmpty {
            if segments[idx].originalSealed {
                segments[idx].isClosed = true
            } else {
                segments[idx].originalSealed = true
            }
        }
        closeCompletedBlocks()
        trimHistory()
    }

    /// Session over — nothing more will arrive; close everything.
    private func forceCloseAll() {
        clearPartials()
        for idx in segments.indices where !segments[idx].isEmpty {
            segments[idx].isClosed = true
        }
        ensureOpenLive()
    }

    private func ensureOpenLive() {
        if segments.isEmpty || segments[liveIndex].isClosed || segments[liveIndex].originalSealed {
            segments.append(CaptionSegment())
        }
    }

    private func clearPartials() {
        for idx in segments.indices {
            segments[idx].originalPartial = ""
            segments[idx].translationPartial = ""
        }
    }

    private func trimHistory() {
        let overflow = segments.count - maxSegments
        guard overflow > 0 else { return }
        // Only drop closed history; open blocks still receive tokens.
        let removable = min(overflow, segments.prefix(while: \.isClosed).count)
        segments.removeFirst(removable)
    }

    // MARK: Sentence detection

    private static let terminals = CharacterSet(charactersIn: ".!?。！？…؟")
    private static let closers = CharacterSet(charactersIn: "\"'”’»」』）)]〉>")

    /// True when the text ends a sentence (ignoring trailing quotes/brackets).
    static func endsSentence(_ text: String) -> Bool {
        for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.reversed() {
            if closers.contains(scalar) { continue }
            return terminals.contains(scalar)
        }
        return false
    }
}
