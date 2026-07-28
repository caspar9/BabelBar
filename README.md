# BabelBar

A macOS menu-bar app (macOS 14+) that live-transcribes and translates whatever
is playing on your Mac — Zoom, Teams, browser, video player — onto a floating
glass caption overlay. Speech-to-text and translation are powered by the
[Soniox real-time WebSocket API](https://soniox.com/docs/stt/rt/real-time-transcription).

## Build & run

```sh
make build     # release build → signed dist/BabelBar.app
make run       # build + open the app
make install   # copy to /Applications
make clean
```

No third-party dependencies; plain Swift Package Manager.

## First-time setup

1. Launch the app — a `captions.bubble` icon appears in the menu bar (no Dock icon).
2. Menu bar → **Settings… → Account**: paste your Soniox API key and hit
   **Test Connection**.
3. Menu bar → **Start Captions**. On first start macOS asks for **Screen
   Recording** permission (needed for system-audio capture; no video is
   recorded). Enable BabelBar under *Privacy & Security → Screen & System
   Audio Recording*, then start again.

## Usage

- **Overlay**: always stays on top (incl. full-screen apps); drag anywhere by
  its background; resize from edges; position is remembered. Hover to reveal
  the close, record, and gear (quick session settings) buttons.
- **Captions**: original speech on top, translation below (default target:
  Chinese `zh`). Dimmer text is provisional and firms up as the recognizer
  finalizes it. With diarization on, each block gets a colored speaker chip.
- **Global hotkeys** (configurable in Settings → Shortcuts):
  - ⌥⌘L — toggle app: show overlay + start captions / hide everything
  - ⌥⌘R — start/stop transcription only
- Changing session options (languages, diarization, endpointing, translation)
  while running restarts the stream automatically.

## Architecture

```
SystemAudioSource (ScreenCaptureKit → AVAudioConverter → 16 kHz mono s16le)
        │  AsyncThrowingStream<Data>            [AudioSource protocol]
        ▼
TranscriptionSession (coordinator: lifecycle, restarts on settings change)
        │  AsyncStream<TranscriptEvent>         [StreamingTranscriptionProvider]
        ▼
SonioxProvider (WebSocket, token protocol, reconnect w/ backoff — all
                vendor-specific JSON stays in this one file)
        ▼
CaptionModel (final vs. provisional buffers → CaptionSegments)
        ▼
OverlayPanelController (non-activating NSPanel + HUD glass + SwiftUI)
```

Swapping STT vendors means writing one new `StreamingTranscriptionProvider`.
