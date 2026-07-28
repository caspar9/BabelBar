import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Captures macOS system audio (not the microphone) via ScreenCaptureKit and
/// emits 16 kHz mono s16le PCM in ~120 ms chunks.
final class SystemAudioSource: NSObject, AudioSource, SCStreamDelegate, SCStreamOutput {
    private let audioQueue = DispatchQueue(label: "com.babelbar.audio")
    private var stream: SCStream?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!
    private var converter: AVAudioConverter?
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
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video output is never attached; shrink it to the minimum anyway.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream

        audioQueue.sync {
            converter = nil
            pending.removeAll()
        }

        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        audioQueue.sync {
            if !pending.isEmpty {
                continuation?.yield(pending)
                pending.removeAll()
            }
        }
        continuation?.finish()
        continuation = nil
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else { return }

        try? sampleBuffer.withAudioBufferList { bufferList, _ in
            guard let input = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, bufferListNoCopy: bufferList.unsafePointer
            ) else { return }
            convertAndEmit(input, using: converter, sourceRate: sourceFormat.sampleRate)
        }
    }

    private func convertAndEmit(
        _ input: AVAudioPCMBuffer, using converter: AVAudioConverter, sourceRate: Double
    ) {
        let ratio = targetFormat.sampleRate / sourceRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0,
              let samples = output.int16ChannelData
        else { return }

        pending.append(Data(bytes: samples[0], count: Int(output.frameLength) * 2))
        while pending.count >= chunkBytes {
            continuation?.yield(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation?.finish(throwing: TranscriptionError(
            message: "Audio capture stopped: \(error.localizedDescription)",
            isRecoverable: true
        ))
        continuation = nil
        self.stream = nil
    }
}

// MARK: - Screen Recording permission

@MainActor
enum ScreenRecordingPermission {
    /// Returns true if capture is authorized. On first denial, explains why the
    /// permission is needed and offers to open System Settings.
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = """
        BabelBar uses macOS Screen Recording only to capture your Mac's \
        audio output (what you hear from Zoom, Teams, the browser, or a video \
        player) so it can transcribe and translate it live.

        No video is recorded and nothing is stored.

        Click "Open System Settings", enable BabelBar under \
        Privacy & Security → Screen & System Audio Recording, then start \
        captions again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            // Registers the app in the Screen Recording list and shows the system prompt.
            CGRequestScreenCaptureAccess()
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: pane) {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }
}
