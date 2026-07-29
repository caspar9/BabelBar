import AppKit
import CoreMedia
import ScreenCaptureKit

/// Captures macOS system audio (not the microphone) via ScreenCaptureKit and
/// emits 16 kHz mono s16le PCM in ~120 ms chunks.
///
/// Concurrency: every mutable field is confined to `audioQueue` — the SCStream
/// callback already runs there, and `start()`/`stop()` hop onto it — so there
/// are no cross-thread races on the continuation or chunk buffer.
final class SystemAudioSource: NSObject, AudioSource, SCStreamDelegate, SCStreamOutput {
    private let audioQueue = DispatchQueue(label: "com.babelbar.app.audio")

    // Confined to audioQueue.
    private var stream: SCStream?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var pending = Data()

    /// 16 000 samples/s × 2 bytes × 0.12 s
    private let chunkBytes = 3_840

    func start() async throws -> AsyncThrowingStream<Data, Error> {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw TranscriptionError(message: "No display found for audio capture.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // ScreenCaptureKit resamples and downmixes for us; only the
        // float32 → int16 sample-format conversion is left to do.
        config.sampleRate = 16_000
        config.channelCount = 1
        // Video output is never attached; shrink it to the minimum anyway.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        let (dataStream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        audioQueue.sync {
            self.stream = stream
            self.continuation = continuation
            self.pending.removeAll()
        }

        do {
            try await stream.startCapture()
        } catch {
            audioQueue.sync {
                self.stream = nil
                self.continuation = nil
            }
            throw error
        }
        Log.audio.info("System audio capture started")
        return dataStream
    }

    func stop() async {
        let stream = audioQueue.sync { self.stream }
        if let stream {
            try? await stream.stopCapture()
        }
        audioQueue.sync {
            if !pending.isEmpty {
                continuation?.yield(pending)
                pending.removeAll()
            }
            continuation?.finish()
            continuation = nil
            self.stream = nil
        }
        Log.audio.info("System audio capture stopped")
    }

    // MARK: SCStreamOutput (runs on audioQueue)

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, continuation != nil else { return }
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription
        else { return }

        try? sampleBuffer.withAudioBufferList { bufferList, _ in
            let buffers = bufferList.unsafePointer.pointee.mBuffers
            guard let base = buffers.mData else { return }
            let byteCount = Int(buffers.mDataByteSize)

            if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                appendConverted(
                    floats: base.bindMemory(to: Float32.self, capacity: byteCount / 4),
                    count: byteCount / 4
                )
            } else if asbd.mBitsPerChannel == 16 {
                pending.append(Data(bytes: base, count: byteCount))
            } else {
                Log.audio.warning("Unexpected audio format: \(asbd.mFormatID) \(asbd.mBitsPerChannel)-bit")
                return
            }
            emitChunks()
        }
    }

    private func appendConverted(floats: UnsafePointer<Float32>, count: Int) {
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let clamped = max(-1.0, min(1.0, floats[i]))
            samples[i] = Int16(clamped * Float32(Int16.max))
        }
        samples.withUnsafeBytes { pending.append(contentsOf: $0) }
    }

    private func emitChunks() {
        while pending.count >= chunkBytes {
            continuation?.yield(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.audio.error("Capture stopped with error: \(error.localizedDescription)")
        audioQueue.async {
            self.continuation?.finish(throwing: TranscriptionError(
                message: "Audio capture stopped: \(error.localizedDescription)",
                isRecoverable: true
            ))
            self.continuation = nil
            self.stream = nil
        }
    }
}

// MARK: - Screen Recording permission

@MainActor
enum ScreenRecordingPermission {
    /// Returns true if capture is authorized. Otherwise explains why the
    /// permission is needed, then triggers exactly one system surface: the
    /// one-time system prompt on first request, or the privacy pane after.
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = """
        BabelBar uses macOS Screen Recording only to capture your Mac's \
        audio output (what you hear from Zoom, Teams, the browser, or a video \
        player) so it can transcribe and translate it live.

        No video is recorded and nothing is stored.

        Enable BabelBar under Privacy & Security → Screen & System Audio \
        Recording, then start captions again.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        // The system's own permission prompt appears at most once per app;
        // after that the only path is the privacy pane.
        let requestedKey = "requestedScreenCapture"
        if !UserDefaults.standard.bool(forKey: requestedKey) {
            UserDefaults.standard.set(true, forKey: requestedKey)
            CGRequestScreenCaptureAccess()
        } else {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: pane) {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }
}
