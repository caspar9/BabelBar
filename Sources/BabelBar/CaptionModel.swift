import SwiftUI

/// One sentence/utterance block shown in the overlay: an original sentence and
/// its translation, kept together so scrolling back always shows the pair.
struct CaptionSegment: Identifiable, Equatable {
    let id: UUID
    var originalFinal: String = ""
    var originalPartial: String = ""
    var translationFinal: String = ""
    var translationPartial: String = ""
    var speaker: String?
    /// Closed blocks receive no further tokens.
    var isClosed: Bool = false

    init(id: UUID = UUID()) { self.id = id }

    var isEmpty: Bool {
        originalFinal.isEmpty && originalPartial.isEmpty
            && translationFinal.isEmpty && translationPartial.isEmpty
    }
}

enum SessionState: Equatable {
    case idle
    case starting
    case running
    case reconnecting(attempt: Int)
    case restarting
    case autoPaused
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle, .autoPaused, .error: return false
        default: return true
        }
    }
}

/// Turns provider-neutral `TranscriptEvent`s into renderable caption blocks.
///
/// Blocks are split per sentence so each translated sentence sits directly
/// under its original. Because translation tokens trail the original by a few
/// hundred ms, a block whose original sentence is complete stays open until its
/// translation is complete too; original tokens for the next sentence open a
/// new block in the meantime. Final text is committed and immutable; partial
/// text is replaced wholesale on every event.
@MainActor
final class CaptionModel: ObservableObject {
    /// Scrollback history plus open blocks; the last element is the live block.
    @Published private(set) var segments: [CaptionSegment] = [CaptionSegment()]
    @Published var state: SessionState = .idle

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
        case .connected:
            state = .running

        case .partial(let tokens):
            applyPartials(tokens)

        case .final(let tokens):
            applyFinals(tokens)

        case .utteranceEnd:
            closeAllOpenBlocks()

        case .speakerChange(let speaker):
            closeAllOpenBlocks()
            segments[liveIndex].speaker = speaker

        case .reconnecting(let attempt):
            state = .reconnecting(attempt: attempt)

        case .finished:
            clearPartials()
            closeAllOpenBlocks()

        case .error(let err):
            state = .error(err.message)
        }
    }

    // MARK: Token routing

    private func applyFinals(_ tokens: [TranscriptToken]) {
        for token in tokens {
            switch token.kind {
            case .original:
                // A finished sentence means new original text starts a new block;
                // the old one may still be waiting for its translation.
                if !segments[liveIndex].isEmpty,
                   Self.endsSentence(segments[liveIndex].originalFinal) {
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
    /// that already has original text.
    private func translationTargetIndex() -> Int {
        for (idx, seg) in segments.enumerated() {
            if !seg.isClosed && !seg.originalFinal.isEmpty
                && !Self.endsSentence(seg.translationFinal) {
                return idx
            }
        }
        return liveIndex
    }

    // MARK: Block lifecycle

    /// A block is done when its original sentence is complete and — if
    /// translation is expected — the translation is complete as well.
    private func closeCompletedBlocks() {
        for idx in segments.indices {
            let seg = segments[idx]
            guard !seg.isClosed, !seg.originalFinal.isEmpty else { continue }
            let originalDone = Self.endsSentence(seg.originalFinal)
            let translationDone = !expectsTranslation || Self.endsSentence(seg.translationFinal)
            if originalDone && translationDone {
                segments[idx].isClosed = true
                segments[idx].originalPartial = ""
                segments[idx].translationPartial = ""
            }
        }
        if segments[liveIndex].isClosed {
            segments.append(CaptionSegment())
        }
    }

    /// Forced boundary (endpoint `<end>`, speaker change, session end): the
    /// provider has already finalized pending tokens, so stale partials are
    /// dropped and every open block is sealed as-is.
    private func closeAllOpenBlocks() {
        clearPartials()
        for idx in segments.indices where !segments[idx].isClosed {
            if segments[idx].isEmpty {
                segments.remove(at: idx)
                break  // only the live block can be empty
            }
            segments[idx].isClosed = true
        }
        segments.append(CaptionSegment())
        trimHistory()
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
        // Never drop open blocks; they are always at the tail.
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
