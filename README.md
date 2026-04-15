# ElevenNotch

ElevenNotch is a macOS notch-style brainstorming assistant for local codebases.

It lets you choose a project folder, index the code, ask a question, retrieve relevant code chunks, generate a concise answer, and hear that answer spoken back inside a compact notch UI.

## Features

- Notch-style always-on-top macOS UI
- Click-to-index project selection
- Real-time speech-to-text while the notch is expanded
- Retrieval over indexed code chunks with TurboPuffer
- Answer synthesis with Mistral
- Spoken responses with ElevenLabs TTS
- Runtime API key entry from the header ellipsis menu

## Pipeline

```text
Speech framework (live STT)
        ->
full transcript
        ->
codestral-embed-2505
        ->
TurboPuffer vector query
        ->
top code chunks
        ->
Mistral chat completion
        ->
answer text
        ->
ElevenLabs TTS
        ->
spoken audio
```

## Requirements

- macOS 15.6+
- Xcode with SwiftUI/macOS support
- Microphone permission
- Speech recognition permission
- API keys for:
  - Mistral
  - TurboPuffer
  - ElevenLabs

## Setup

1. Open `ElevenNotch.xcodeproj` in Xcode.
2. Build and run the `ElevenNotch` scheme.
3. Expand the notch.
4. Click the ellipsis in the header.
5. Enter your Mistral, TurboPuffer, and ElevenLabs API keys.
6. Close settings.
7. Choose a project folder from the left panel.
8. Ask a question out loud.

## Runtime Behavior

- The microphone only activates while the notch is expanded.
- The app indexes the selected project before retrieval is available.
- The left panel reflects pipeline state: idle, listening, thinking, speaking, and failure.
- While processing is active, the left panel shows elapsed time.
- On newer systems, the app uses the modern Apple speech path when available and falls back automatically on older supported macOS versions.

## Project Structure

- `ElevenNotch/View Model/NotchViewModel.swift`
  - notch state, pipeline state, timers, runtime API key plumbing
- `ElevenNotch/AudioCaptureService.swift`
  - microphone capture, waveform metering, live transcript binding
- `ElevenNotch/SpeechTranscriptionService.swift`
  - real-time STT with modern/legacy Apple speech support
- `ElevenNotch/CodebaseIndexingService.swift`
  - file scanning, chunking, embeddings, TurboPuffer indexing/querying
- `ElevenNotch/VoicePipelineService.swift`
  - retrieval, answer generation, ElevenLabs playback, speaking waveform metering
- `ElevenNotch/Views/`
  - notch UI, header, settings, waveform, and pipeline panels

## Notes

- API keys are currently persisted through the app's local persistence layer, not Keychain.
- The speaking waveform is based on ElevenLabs playback metering, not microphone input.
- Speech recognition and network-backed AI services can fail independently; failures are surfaced in the left panel.

## Build

```bash
xcodebuild -project ElevenNotch.xcodeproj -scheme ElevenNotch -configuration Debug -derivedDataPath /tmp/ElevenNotchDerived CODE_SIGNING_ALLOWED=NO build
```
