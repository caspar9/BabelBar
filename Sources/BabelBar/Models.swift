import Foundation

// MARK: - Provider-neutral transcript model

enum TokenKind: Equatable, Sendable {
    case original
    case translation
}

struct TranscriptToken: Equatable, Sendable {
    var text: String
    var isFinal: Bool
    var language: String?
    var speaker: String?
    var kind: TokenKind
}

/// Provider-neutral events emitted by any streaming STT provider.
enum TranscriptEvent: Sendable {
    case connected
    /// Full replacement set of the current provisional (non-final) tokens.
    case partial([TranscriptToken])
    /// Newly committed tokens; append-only.
    case final([TranscriptToken])
    /// Endpoint detected — the current utterance is complete.
    case utteranceEnd
    case speakerChange(String)
    case reconnecting(attempt: Int)
    case finished
    case error(TranscriptionError)
}

struct TranscriptionError: Error, Equatable, Sendable {
    var message: String
    var isRecoverable: Bool = false
}

/// Provider-neutral session configuration.
struct TranscriptionConfig: Equatable, Sendable {
    var apiKey: String
    var languageHints: [String]
    var strictLanguageHints: Bool
    var speakerDiarization: Bool
    var endpointDetection: Bool
    /// Target language code when translation is enabled; nil disables translation.
    var translationTarget: String?
}

// MARK: - Layer protocols

/// A source of 16 kHz mono s16le PCM audio chunks (~120 ms each).
protocol AudioSource: AnyObject {
    func start() async throws -> AsyncThrowingStream<Data, Error>
    func stop() async
}

/// A swappable streaming STT vendor. All vendor-specific wire formats live
/// inside implementations; callers only see `TranscriptEvent`s.
protocol StreamingTranscriptionProvider: AnyObject {
    /// Connects and returns the event stream for this session.
    func start(config: TranscriptionConfig) async throws -> AsyncStream<TranscriptEvent>
    /// Streams one chunk of pcm_s16le audio. Dropped if not connected.
    func sendAudio(_ chunk: Data) async
    /// Asks the provider to force-finalize pending tokens.
    func finalize() async
    /// Gracefully ends the session (signals end-of-audio, waits briefly).
    func stop() async
}

// MARK: - Language catalog

struct Language: Identifiable, Equatable {
    let code: String
    let name: String
    var id: String { code }

    /// Choices offered as language-hint chips.
    static let hintOptions: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "zh", name: "Chinese"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "es", name: "Spanish"),
        Language(code: "de", name: "German"),
        Language(code: "fr", name: "French"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "ru", name: "Russian"),
        Language(code: "it", name: "Italian"),
    ]

    /// Choices offered as translation targets.
    static let translationTargets: [Language] = [
        Language(code: "zh", name: "Chinese (Simplified)"),
        Language(code: "en", name: "English"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "es", name: "Spanish"),
        Language(code: "de", name: "German"),
        Language(code: "fr", name: "French"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "ru", name: "Russian"),
        Language(code: "it", name: "Italian"),
    ]
}
