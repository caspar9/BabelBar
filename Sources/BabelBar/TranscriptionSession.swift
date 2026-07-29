import Foundation
import Combine

/// Coordinator: pumps `AudioSource` audio into a `StreamingTranscriptionProvider`
/// and provider events into the `CaptionModel`. Owns the session lifecycle and
/// the single `state` value every UI surface derives from. Knows nothing about
/// windows or views.
@MainActor
final class TranscriptionSession: ObservableObject {
    let captions = CaptionModel()

    @Published private(set) var state: SessionState = .idle

    var isRunning: Bool { state.isActive }

    private let settings: SettingsStore
    private let makeAudioSource: () -> AudioSource
    private let makeProvider: () -> StreamingTranscriptionProvider

    private var audioSource: AudioSource?
    private var provider: StreamingTranscriptionProvider?
    private var pumpTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var silenceWatchdog: Task<Void, Never>?
    private var restartDebounce: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var generation = 0

    /// Auto-pause: peak s16 amplitude above this counts as sound (~ -40 dBFS).
    private static let audibleThreshold: Int16 = 330
    private static let silenceLimit: Duration = .seconds(30)
    /// Monotonic clock — wall-clock Date would jump across system sleep and
    /// fire a spurious auto-pause on wake.
    private let clock = ContinuousClock()
    private var lastAudibleAt: ContinuousClock.Instant

    init(
        settings: SettingsStore,
        makeAudioSource: @escaping () -> AudioSource = { SystemAudioSource() },
        makeProvider: @escaping () -> StreamingTranscriptionProvider = { SonioxProvider() }
    ) {
        self.settings = settings
        self.makeAudioSource = makeAudioSource
        self.makeProvider = makeProvider
        self.lastAudibleAt = clock.now
        observeSettings()
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        guard !settings.apiKey.isEmpty else {
            state = .needsAPIKey
            return
        }
        guard ScreenRecordingPermission.ensure() else { return }
        Task { await startSession() }
    }

    func stop() {
        guard isRunning else { return }
        Task { await stopSession(finalState: .idle) }
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    private func startSession() async {
        generation += 1
        let gen = generation
        captions.reset()
        captions.expectsTranslation = settings.transcriptionConfig.translationTarget != nil
        state = .starting
        Log.session.info("Starting session")

        let audioSource = makeAudioSource()
        let provider = makeProvider()
        self.audioSource = audioSource
        self.provider = provider

        do {
            let eventStream = try await provider.start(config: settings.transcriptionConfig)
            let audioStream = try await audioSource.start()
            guard gen == generation else { return }

            state = .running

            eventTask = Task { [weak self] in
                for await event in eventStream {
                    guard let self, self.generation == gen else { return }
                    self.handle(event)
                }
            }

            pumpTask = Task { [weak self] in
                do {
                    for try await chunk in audioStream {
                        guard let self, self.generation == gen else { return }
                        if chunk.peakSampleS16() > Self.audibleThreshold {
                            self.lastAudibleAt = self.clock.now
                        }
                        await provider.sendAudio(chunk)
                    }
                } catch {
                    guard let self, self.generation == gen else { return }
                    await self.stopSession(finalState: .error(
                        "Audio capture failed: \(error.localizedDescription)"
                    ))
                }
            }

            lastAudibleAt = clock.now
            silenceWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.generation == gen else { return }
                    if self.settings.autoPauseEnabled,
                       self.clock.now - self.lastAudibleAt > Self.silenceLimit {
                        Log.session.info("Auto-pausing after silence")
                        await self.stopSession(finalState: .autoPaused)
                        return
                    }
                }
            }
        } catch {
            guard gen == generation else { return }
            Log.session.error("Session start failed: \(error.localizedDescription)")
            await stopSession(finalState: .error(
                "Could not start: \(error.localizedDescription)"
            ))
        }
    }

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .connected:
            state = .running
        case .reconnecting(let attempt):
            state = .reconnecting(attempt: attempt)
        case .error(let err):
            state = .error(err.message)
        default:
            break
        }
        captions.apply(event)
    }

    private func stopSession(finalState: SessionState) async {
        generation += 1
        pumpTask?.cancel()
        eventTask?.cancel()
        silenceWatchdog?.cancel()
        pumpTask = nil
        eventTask = nil
        silenceWatchdog = nil

        if let audioSource { await audioSource.stop() }
        if let provider { await provider.stop() }
        audioSource = nil
        provider = nil

        state = finalState
        Log.session.info("Session stopped")
    }

    // MARK: Settings-change restart

    private func observeSettings() {
        let s = settings
        // dropFirst() per publisher skips each one's initial replay without
        // depending on how many publishers are merged here.
        let changes: [AnyPublisher<Void, Never>] = [
            s.$languageHints.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            s.$strictLanguageHints.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            s.$speakerDiarization.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            s.$endpointDetection.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            s.$translationEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            s.$targetLanguage.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .sink { [weak self] in self?.scheduleRestart() }
            .store(in: &cancellables)
    }

    /// Debounced so toggling several options at once restarts a single time.
    private func scheduleRestart() {
        guard isRunning else { return }
        state = .restarting
        restartDebounce?.cancel()
        restartDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            await self.stopSession(finalState: .restarting)
            await self.startSession()
        }
    }
}

private extension Data {
    /// Peak absolute amplitude of pcm_s16le audio, for silence detection.
    func peakSampleS16() -> Int16 {
        withUnsafeBytes { raw in
            var peak: Int16 = 0
            for sample in raw.bindMemory(to: Int16.self) {
                let magnitude = sample == .min ? .max : abs(sample)
                if magnitude > peak { peak = magnitude }
            }
            return peak
        }
    }
}
