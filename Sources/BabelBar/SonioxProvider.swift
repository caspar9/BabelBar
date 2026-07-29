import Foundation

/// Soniox real-time STT over WebSocket.
/// Docs: https://soniox.com/docs/stt/rt/real-time-transcription
/// All Soniox-specific wire formats stay inside this file; callers only see
/// provider-neutral `TranscriptEvent`s.
actor SonioxProvider: StreamingTranscriptionProvider {
    private static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private static let model = "stt-rt-v5"
    private static let maxReconnectAttempts = 5
    /// How long stop() waits for the server's `finished` acknowledgment.
    private static let drainTimeout: Duration = .seconds(3)

    /// Shared across sessions — URLSessions are expensive and must be
    /// explicitly invalidated if per-instance, so keep one for the app.
    private static let urlSession = URLSession(configuration: .default)

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var events: AsyncStream<TranscriptEvent>.Continuation?
    private var config: TranscriptionConfig?
    private var stopping = false
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastSpeaker: String?
    /// Incremented per start(); keeps stale timeout tasks from touching a new session.
    private var epoch = 0

    // MARK: StreamingTranscriptionProvider

    func start(config: TranscriptionConfig) async throws -> AsyncStream<TranscriptEvent> {
        self.config = config
        stopping = false
        finished = false
        lastSpeaker = nil
        epoch += 1

        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        events = continuation
        try await connect(config: config)
        return stream
    }

    func sendAudio(_ chunk: Data) async {
        guard let socket, !stopping else { return }
        do {
            try await socket.send(.data(chunk))
        } catch {
            // The receive loop sees the same failure and drives reconnection.
        }
    }

    func finalize() async {
        guard let socket else { return }
        try? await socket.send(.string(#"{"type": "finalize"}"#))
    }

    func stop() async {
        stopping = true
        if let socket {
            // Empty string signals end-of-audio; the server flushes remaining
            // tokens and replies with `finished` — wait for that (with a
            // timeout) instead of sleeping a fixed interval.
            try? await socket.send(.string(""))
            await waitForFinished(timeout: Self.drainTimeout)
        }
        teardown()
        events?.finish()
        events = nil
    }

    // MARK: Finished handshake

    private func waitForFinished(timeout: Duration) async {
        guard !finished else { return }
        let currentEpoch = epoch
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishWaiters.append(cont)
            Task {
                try? await Task.sleep(for: timeout)
                if self.epoch == currentEpoch {
                    Log.stt.warning("Timed out waiting for server drain")
                    self.signalFinished()
                }
            }
        }
    }

    private func signalFinished() {
        finished = true
        for waiter in finishWaiters {
            waiter.resume()
        }
        finishWaiters.removeAll()
    }

    // MARK: Connection

    private func connect(config: TranscriptionConfig) async throws {
        let socket = Self.urlSession.webSocketTask(with: Self.endpoint)
        socket.resume()
        self.socket = socket

        try await socket.send(.string(configJSON(for: config)))
        Log.stt.info("Connected to Soniox")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket)
        }
    }

    private func configJSON(for config: TranscriptionConfig) -> String {
        var dict: [String: Any] = [
            "api_key": config.apiKey,
            "model": Self.model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "enable_language_identification": true,
            "language_hints_strict": config.strictLanguageHints,
            "enable_speaker_diarization": config.speakerDiarization,
            "enable_endpoint_detection": config.endpointDetection,
        ]
        if !config.languageHints.isEmpty {
            dict["language_hints"] = config.languageHints
        }
        if let target = config.translationTarget {
            dict["translation"] = ["type": "one_way", "target_language": target]
        }
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func teardown() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    // MARK: Receive loop

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard self.socket === socket else { return }
                if case .string(let text) = message {
                    if handle(responseText: text) { return }  // finished/fatal
                }
            } catch {
                guard self.socket === socket else { return }
                if stopping {
                    // Connection dropped while draining — nothing more will
                    // arrive; unblock stop().
                    signalFinished()
                    return
                }
                Log.stt.warning("WebSocket receive failed: \(error.localizedDescription)")
                await reconnect()
                return
            }
        }
    }

    /// Returns true when the session is over and the loop should exit.
    private func handle(responseText: String) -> Bool {
        guard let data = responseText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        if let code = obj["error_code"] as? Int {
            let message = obj["error_message"] as? String ?? "Unknown Soniox error"
            Log.stt.error("Soniox error \(code): \(message)")
            events?.yield(.error(TranscriptionError(message: "Soniox error \(code): \(message)")))
            signalFinished()
            teardown()
            return true
        }

        if let rawTokens = obj["tokens"] as? [[String: Any]] {
            processTokens(rawTokens)
        }

        if obj["finished"] as? Bool == true {
            Log.stt.info("Server acknowledged end of session")
            events?.yield(.finished)
            signalFinished()
            teardown()
            return true
        }
        return false
    }

    private func processTokens(_ rawTokens: [[String: Any]]) {
        var finals: [TranscriptToken] = []
        var partials: [TranscriptToken] = []
        var sawEndpoint = false

        func flushFinals() {
            if !finals.isEmpty {
                events?.yield(.final(finals))
                finals.removeAll()
            }
        }

        for raw in rawTokens {
            guard let text = raw["text"] as? String else { continue }
            let isFinal = raw["is_final"] as? Bool ?? false

            // Control tokens are never rendered.
            if text == "<end>" {
                if isFinal {
                    flushFinals()
                    events?.yield(.utteranceEnd)
                    sawEndpoint = true
                }
                continue
            }
            if text == "<fin>" { continue }

            let speaker = (raw["speaker"]).flatMap { "\($0)" }
            let token = TranscriptToken(
                text: text,
                isFinal: isFinal,
                language: raw["language"] as? String,
                speaker: speaker,
                kind: (raw["translation_status"] as? String) == "translation"
                    ? .translation : .original
            )

            if isFinal {
                if let speaker, speaker != lastSpeaker {
                    if lastSpeaker != nil {
                        flushFinals()
                        events?.yield(.speakerChange(speaker))
                    }
                    lastSpeaker = speaker
                }
                finals.append(token)
            } else {
                partials.append(token)
            }
        }

        flushFinals()
        // Non-final tokens are a full replacement set on every message. After an
        // endpoint the remaining partials belong to the new utterance and will
        // arrive again in the next message, so skip them to avoid double-render.
        if !sawEndpoint {
            events?.yield(.partial(partials))
        }
    }

    // MARK: Reconnect with exponential backoff

    private func reconnect() async {
        teardown()
        guard let config else { return }

        for attempt in 1...Self.maxReconnectAttempts {
            guard !stopping else { return }
            events?.yield(.reconnecting(attempt: attempt))
            Log.stt.info("Reconnecting, attempt \(attempt)")
            let delay = min(16.0, pow(2.0, Double(attempt - 1)))  // 1, 2, 4, 8, 16 s
            try? await Task.sleep(for: .seconds(delay))
            guard !stopping else { return }
            do {
                try await connect(config: config)
                lastSpeaker = nil
                events?.yield(.connected)
                return
            } catch {
                continue
            }
        }
        Log.stt.error("Reconnect attempts exhausted")
        events?.yield(.error(TranscriptionError(
            message: "Connection lost — could not reconnect to the transcription service."
        )))
    }
}

// MARK: - Connection test (Settings → Account)

enum SonioxConnectionTest {
    /// Full short-lived handshake: connect, stream ~300 ms of silence, signal
    /// end-of-audio, and wait for the server's `finished` acknowledgment.
    /// (Sending end-of-audio with zero audio bytes makes the server reply
    /// "error 400: No audio received", so the silence burst is required.)
    static func run(apiKey: String) async -> Result<Void, TranscriptionError> {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(TranscriptionError(message: "Enter an API key first."))
        }
        let provider = SonioxProvider()
        let config = TranscriptionConfig(
            apiKey: apiKey, languageHints: ["en"], strictLanguageHints: false,
            speakerDiarization: false, endpointDetection: false, translationTarget: nil
        )
        do {
            let stream = try await provider.start(config: config)
            await provider.sendAudio(Data(count: 9_600))  // 300 ms of silence
            Task { await provider.stop() }  // end-of-audio, then teardown

            return await withTaskGroup(of: Result<Void, TranscriptionError>.self) { group in
                group.addTask {
                    for await event in stream {
                        switch event {
                        case .error(let err): return .failure(err)
                        case .finished: return .success(())
                        default: continue
                        }
                    }
                    // Clean close without an error still means the server
                    // accepted the key and config.
                    return .success(())
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return .failure(TranscriptionError(
                        message: "Timed out waiting for the server — check your network."
                    ))
                }
                defer { group.cancelAll() }
                return await group.next()
                    ?? .failure(TranscriptionError(message: "Connection closed unexpectedly."))
            }
        } catch {
            return .failure(TranscriptionError(message: error.localizedDescription))
        }
    }
}
