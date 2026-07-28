import Foundation
import Combine

/// Coordinator: pumps `AudioSource` audio into a `StreamingTranscriptionProvider`
/// and provider events into the `CaptionModel`. Owns session lifecycle,
/// including graceful restarts when settings change mid-session.
@MainActor
final class TranscriptionSession: ObservableObject {
    let captions = CaptionModel()

    @Published private(set) var isRunning = false

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
    private static let silenceLimit: TimeInterval = 30
    private var lastAudibleAt = Date()

    init(
        settings: SettingsStore,
        makeAudioSource: @escaping () -> AudioSource = { SystemAudioSource() },
        makeProvider: @escaping () -> StreamingTranscriptionProvider = { SonioxProvider() }
    ) {
        self.settings = settings
        self.makeAudioSource = makeAudioSource
        self.makeProvider = makeProvider
        observeSettings()
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        guard !settings.apiKey.isEmpty else {
            captions.state = .error("Add your Soniox API key in Settings first.")
            AppCoordinator.shared?.openSettingsWindow()
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
        isRunning = true
        captions.reset()
        captions.expectsTranslation = settings.transcriptionConfig.translationTarget != nil
        captions.state = .starting

        let audioSource = makeAudioSource()
        let provider = makeProvider()
        self.audioSource = audioSource
        self.provider = provider

        do {
            let eventStream = try await provider.start(config: settings.transcriptionConfig)
            let audioStream = try await audioSource.start()
            guard gen == generation else { return }

            captions.state = .running

            eventTask = Task { [weak self] in
                for await event in eventStream {
                    guard let self, self.generation == gen else { return }
                    self.captions.apply(event)
                }
            }

            pumpTask = Task { [weak self] in
                do {
                    for try await chunk in audioStream {
                        guard let self, self.generation == gen else { return }
                        if chunk.peakSampleS16() > Self.audibleThreshold {
                            self.lastAudibleAt = Date()
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

            lastAudibleAt = Date()
            silenceWatchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, self.generation == gen else { return }
                    if self.settings.autoPauseEnabled,
                       Date().timeIntervalSince(self.lastAudibleAt) > Self.silenceLimit {
                        await self.stopSession(finalState: .autoPaused)
                        return
                    }
                }
            }
        } catch {
            guard gen == generation else { return }
            await stopSession(finalState: .error(
                "Could not start: \(error.localizedDescription)"
            ))
        }
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

        isRunning = false
        captions.state = finalState
    }

    // MARK: Settings-change restart

    private func observeSettings() {
        let s = settings
        Publishers.MergeMany(
            s.$languageHints.map { _ in () }.eraseToAnyPublisher(),
            s.$strictLanguageHints.map { _ in () }.eraseToAnyPublisher(),
            s.$speakerDiarization.map { _ in () }.eraseToAnyPublisher(),
            s.$endpointDetection.map { _ in () }.eraseToAnyPublisher(),
            s.$translationEnabled.map { _ in () }.eraseToAnyPublisher(),
            s.$targetLanguage.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(6)  // skip the initial replay of each publisher
        .sink { [weak self] in self?.scheduleRestart() }
        .store(in: &cancellables)
    }

    /// Debounced so toggling several options at once restarts a single time.
    private func scheduleRestart() {
        guard isRunning else { return }
        captions.state = .restarting
        restartDebounce?.cancel()
        restartDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
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
