# BabelBar

A macOS app (macOS 14+) that live-transcribes and translates whatever is
playing on your Mac — Zoom, Teams, browser, video player — into a floating
glass caption window. Optionally mixes in your microphone so your own speech
is captioned too. Speech-to-text and translation are powered by the
[Soniox real-time WebSocket API](https://soniox.com/docs/stt/rt/real-time-transcription).

## Build & run

Requires a full **Xcode** install (not just Command Line Tools — the SwiftUI
macros the app uses ship only with Xcode). Point the toolchain at it once:

```sh
sudo xcode-select -s /Applications/Xcode.app
```

Then:

```sh
make cert      # one-time: create a local self-signed signing identity (see below)
make build     # release build → signed dist/BabelBar.app
make run       # build + open the app
make install   # copy to /Applications
make dmg       # drag-to-install disk image → dist/BabelBar-<version>.dmg
make icon      # re-render Resources/AppIcon.icns from Resources/icon/make-icon.swift
make clean
swift test     # unit tests (CaptionModel)
```

To install on another Mac, open the DMG and drag BabelBar to Applications. These
builds are not notarized, so the first launch there needs right-click →
**Open** (or `xattr -d com.apple.quarantine /Applications/BabelBar.app`).

No third-party dependencies; plain Swift Package Manager.

### Signing — run `make cert` once

macOS remembers permission grants (Screen Recording, Microphone) by the app's
code-signing *designated requirement*. Without a
certificate, `codesign` signs ad hoc and that requirement is the binary's own
hash — so **every rebuild invalidates every permission you granted**, and the
Screen Recording prompt comes back each time.

`make cert` creates a self-signed code-signing certificate ("BabelBar Dev") in
your login keychain (macOS may ask for your password once to trust it). The
Makefile picks it up automatically; the requirement becomes *bundle ID +
certificate*, which is stable across rebuilds. If you already granted Screen
Recording to an ad-hoc build, clear the stale entry so the system prompts
cleanly for the new signature:

```sh
tccutil reset ScreenCapture com.babelbar.app
```

To sign with a real Developer ID instead: `make SIGN_ID="Developer ID Application: …"`.

## First-time setup

1. Launch the app. The caption window opens; BabelBar is a regular app with a
   Dock icon and main menu.
2. Open **Settings** (⌘, or the gear on the caption window → **All Settings…**)
   → **Account**: paste your Soniox API key and hit **Test Connection**. The key
   is stored with the app's other settings (in its preferences file, not the
   Keychain — simpler, though not encrypted).
3. Press the record button on the caption window (or **Start Captions** in the
   View menu). On first start macOS asks for **Screen Recording** permission —
   needed for system-audio capture; no video is recorded. Enable BabelBar under
   *Privacy & Security → Screen & System Audio Recording*, then start again.
4. If you enable **Also capture microphone**, macOS asks for Microphone access
   the first time. If denied, captions fall back to system audio only.

## Usage

### The caption window

Hover to reveal a compact glass control bar in the top-right corner:
**record/stop**, **pin**, and **gear** (session options popover). Drag the window by its background, resize
from any edge; position and size are remembered. Captions are selectable text.

The window has two modes, toggled with the pin button or ⇧⌘P:

- **Pinned** (default): borderless, floats above everything including
  full-screen apps, on every Space, and never steals focus from the meeting or
  video app you click through to.
- **Normal**: a regular titled window with traffic lights that stacks with
  other windows and appears in Mission Control.

Closing the window (⇧⌘0, ⌘W, or the red light) stops transcription — *window
visible = transcribing*. Reopen it from the Dock icon or the hotkey.

### Captions

Original speech in white on top, translation in amber directly beneath each
sentence (default target: Chinese `zh`). Dimmer text is provisional and firms up as the
recognizer finalizes it. With diarization on, each block gets a colored speaker
chip. History scrolls back up to 50 sentences; a chevron appears when you've
scrolled away from the live caption.

### Session options

Available from the gear popover or Settings → Transcription. Changing any of
these while running restarts the stream automatically:

- Language hints (multi-select chips) and strict-hint mode
- Speaker diarization, endpoint detection
- Also capture microphone
- Auto-pause after 30 s of silence (saves API minutes when nothing is playing)
- Translation on/off and target language

### Global hotkeys

Configurable in Settings → Shortcuts; they work while other apps are focused.

- ⌥⌘L — toggle app: show the window + start captions / stop and hide
- ⌥⌘R — start/stop transcription only

## Architecture

```
SystemAudioSource (ScreenCaptureKit, resampled by SCK → 16 kHz mono s16le)
        │  ┐
MicrophoneCapture (AVAudioEngine → 16 kHz mono s16le)   optional
        │  ┘  MixedAudioSource: saturating sample-wise mix
        │  AsyncThrowingStream<Data>, ~120 ms chunks   [AudioSource protocol]
        ▼
TranscriptionSession (coordinator: lifecycle + single SessionState,
                      settings-change restart, silence auto-pause)
        │  AsyncStream<TranscriptEvent>         [StreamingTranscriptionProvider]
        ▼
SonioxProvider (actor: WebSocket, token protocol, reconnect w/ backoff,
                graceful drain — all vendor-specific JSON stays in this file)
        ▼
CaptionModel (final vs. provisional buffers → per-sentence CaptionSegments,
              translation paired under its original)
        ▼
CaptionWindowController (one NSPanel, pinned/normal modes switched in place,
                         HUD glass + SwiftUI OverlayContentView)
```

Layers depend downward only: audio, provider, and session know nothing about
windows. Swapping STT vendors means writing one new
`StreamingTranscriptionProvider`; the UI and caption logic are untouched.

All settings, the API key included, persist in UserDefaults
(`~/Library/Preferences/com.babelbar.app.plist`). Logs go to the unified log under subsystem `com.babelbar.app`:

```sh
log stream --predicate 'subsystem == "com.babelbar.app"'
```
