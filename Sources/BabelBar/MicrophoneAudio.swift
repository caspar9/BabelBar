import AVFoundation
import AppKit

/// Captures the default microphone via AVAudioEngine, converts to 16 kHz mono
/// s16le, and buffers samples for `MixedAudioSource` to pull. Not an
/// `AudioSource` itself — the microphone is only ever mixed into system audio.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!
    private var converter: AVAudioConverter?

    private let bufferQueue = DispatchQueue(label: "com.babelbar.app.mic")
    /// Confined to bufferQueue. Capped so clock drift between the mic and
    /// system audio can't grow the mix latency unboundedly.
    private var samples: [Int16] = []
    private let maxBuffered = 16_000  // 1 s

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriptionError(message: "No microphone input available.")
        }
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw TranscriptionError(message: "Unsupported microphone format.")
        }
        self.converter = converter

        // ~43 ms per tap buffer at 48 kHz; the tap runs on an audio thread,
        // conversion happens there, appending is serialized on bufferQueue.
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.convertAndBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
        Log.audio.info("Microphone capture started (\(format.sampleRate) Hz)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferQueue.sync { samples.removeAll() }
        Log.audio.info("Microphone capture stopped")
    }

    /// Pops up to `count` samples; fewer (or none) during engine warm-up.
    func popSamples(_ count: Int) -> [Int16] {
        bufferQueue.sync {
            let n = min(count, samples.count)
            defer { samples.removeFirst(n) }
            return Array(samples.prefix(n))
        }
    }

    private func convertAndBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0,
              let channel = output.int16ChannelData
        else { return }

        let converted = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        bufferQueue.async {
            self.samples.append(contentsOf: converted)
            if self.samples.count > self.maxBuffered {
                self.samples.removeFirst(self.samples.count - self.maxBuffered)
            }
        }
    }
}

/// System audio + microphone, mixed sample-by-sample with saturating
/// addition. The steady SCStream chunk cadence drives the mix; mic samples
/// are pulled from the capture buffer as each system chunk arrives.
final class MixedAudioSource: AudioSource {
    private let system = SystemAudioSource()
    private let microphone = MicrophoneCapture()

    func start() async throws -> AsyncThrowingStream<Data, Error> {
        let systemStream = try await system.start()
        do {
            try microphone.start()
        } catch {
            await system.stop()
            throw error
        }

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        Task { [system = systemStream, microphone] in
            do {
                for try await chunk in system {
                    continuation.yield(Self.mix(chunk, microphone: microphone))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    /// Ends the system stream first so the pump loop drains and finishes the
    /// downstream continuation naturally.
    func stop() async {
        microphone.stop()
        await system.stop()
    }

    private static func mix(_ systemChunk: Data, microphone: MicrophoneCapture) -> Data {
        var mixed = [Int16](repeating: 0, count: systemChunk.count / 2)
        _ = mixed.withUnsafeMutableBytes { systemChunk.copyBytes(to: $0) }

        let mic = microphone.popSamples(mixed.count)
        guard !mic.isEmpty else { return systemChunk }
        for i in 0..<min(mixed.count, mic.count) {
            mixed[i] = Int16(clamping: Int32(mixed[i]) + Int32(mic[i]))
        }
        return mixed.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Microphone permission

@MainActor
enum MicrophonePermission {
    /// True if mic capture is authorized. Requests on first use; if denied,
    /// explains and offers the privacy pane, then returns false so the
    /// caller can fall back to system-audio-only capture.
    static func ensure() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            let alert = NSAlert()
            alert.messageText = "Microphone Permission Needed"
            alert.informativeText = """
            Microphone capture is enabled in BabelBar's settings, but macOS \
            has denied microphone access.

            Enable BabelBar under Privacy & Security → Microphone, then start \
            captions again. Until then, captions run on system audio only.
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Continue Without Microphone")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                if let url = URL(string: pane) {
                    NSWorkspace.shared.open(url)
                }
            }
            return false
        }
    }
}
