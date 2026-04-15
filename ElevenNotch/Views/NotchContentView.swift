//
//  NotchContentView.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 27/03/2026.
//

import AppKit
import SwiftUI

private enum ELTone {
    static let panelFill = Color(red: 0.094, green: 0.091, blue: 0.082)
    static let border = Color.white.opacity(0.10)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textMuted = Color.white.opacity(0.30)

    static let accent = Color(red: 0.486, green: 0.435, blue: 0.969)
    static let accentDim = Color(red: 0.486, green: 0.435, blue: 0.969).opacity(0.12)

    static let recording = Color(red: 0.835, green: 0.361, blue: 0.361)
    static let denied = Color(red: 0.82,  green: 0.66,  blue: 0.48)
    static let idle = Color.white.opacity(0.28)
}

private struct ELPanelModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.gradient.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(ELTone.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

private extension View {
    func elPanel(radius: CGFloat) -> some View {
        modifier(ELPanelModifier(radius: radius))
    }
}

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        Group {
            if viewModel.contentType == .settings {
                APIKeysSettingsView(viewModel: viewModel)
            } else {
                HStack(spacing: 6) {
                    PipelineStatusView(viewModel: viewModel)
                    WaveformView(audioCapture: viewModel.audioCapture)
                }
            }
        }
    }
}

struct APIKeysSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel

    private var configuredCount: Int {
        [
            viewModel.mistralAPIKey,
            viewModel.turbopufferAPIKey,
            viewModel.elevenLabsAPIKey
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Runtime API Keys")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ELTone.textPrimary)

                Spacer(minLength: 0)

                Text("\(configuredCount)/3 set")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ELTone.textSecondary)
            }

            APIKeyRow(
                title: "Mistral",
                prompt: "Paste Mistral key",
                text: $viewModel.mistralAPIKey
            )
            APIKeyRow(
                title: "TurboPuffer",
                prompt: "Paste TurboPuffer key",
                text: $viewModel.turbopufferAPIKey
            )
            APIKeyRow(
                title: "ElevenLabs",
                prompt: "Paste ElevenLabs key",
                text: $viewModel.elevenLabsAPIKey
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: viewModel.notchOpenedSize.width - (viewModel.spacing * 2), height: 128, alignment: .topLeading)
        .elPanel(radius: 14)
    }
}

struct APIKeyRow: View {
    let title: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ELTone.textSecondary)
                .frame(width: 76, alignment: .leading)

            SecureField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(ELTone.textPrimary)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

struct PipelineStatusView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var audioCapture: AudioCaptureService
    @ObservedObject private var voicePipelineService: VoicePipelineService
    @State private var selectedURL: URL?

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        _audioCapture = ObservedObject(wrappedValue: viewModel.audioCapture)
        _voicePipelineService = ObservedObject(wrappedValue: viewModel.voicePipelineService)
    }

    private var shouldShowProjectPicker: Bool {
        switch viewModel.indexingService.state {
        case .failed:
            return true
        case .idle:
            return viewModel.indexedProjectPath.isEmpty && selectedURL == nil
        case .indexing, .ready:
            return false
        }
    }

    private var projectPickerTitle: String {
        switch viewModel.indexingService.state {
        case .failed:
            return "Index Failed"
        default:
            return "Choose Project"
        }
    }

    private var projectPickerSubtitle: String {
        switch viewModel.indexingService.state {
        case .failed(let message):
            return message
        default:
            return "Click to index a codebase"
        }
    }

    private var projectPickerActionTitle: String {
        switch viewModel.indexingService.state {
        case .failed:
            return "Try Another Folder"
        default:
            return "Open Folder"
        }
    }

    private var dotColor: Color {
        switch viewModel.pipelineState {
        case .idle:
            return Color.white.opacity(0.28)
        case .listening:
            return Color.white.opacity(0.90)
        case .thinking:
            return Color.white.opacity(0.55)
        case .speaking:
            return Color.white.opacity(0.90)
        case .failed:
            return ELTone.denied
        }
    }

    private var dotGlow: Bool {
        switch viewModel.pipelineState {
        case .listening, .speaking:
            return true
        default:
            return false
        }
    }

    private var title: String {
        switch viewModel.pipelineState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Speaking"
        case .failed:
            return "Pipeline Error"
        }
    }

    private var subtitle: String {
        switch viewModel.pipelineState {
        case .idle:
            return "Say something to begin"
        case .listening:
            return "Speak now..."
        case .thinking:
            return "Searching your codebase..."
        case .speaking:
            return "ElevenLabs TTS"
        case .failed(let message):
            return compactFailureMessage(message)
        }
    }

    private func compactFailureMessage(_ message: String) -> String {
        let condensed = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Something went wrong"

        if condensed.count > 72 {
            return String(condensed.prefix(69)) + "..."
        }

        return condensed.isEmpty ? "Something went wrong" : condensed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if shouldShowProjectPicker {
                projectPickerState
            } else {
                pipelineStateContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: 172, height: 128, alignment: .topLeading)
        .elPanel(radius: viewModel.cornerRadius)
        .contentShape(Rectangle())
        .onTapGesture {
            guard shouldShowProjectPicker else { return }
            startIndexing()
        }
        .onChange(of: viewModel.indexingService.state) { _, state in
            guard case .ready = state, let url = selectedURL else { return }
            viewModel.indexedProjectPath = url.path
            selectedURL = nil
        }
    }

    private var projectPickerState: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 7, height: 7)

                Text(projectPickerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ELTone.textPrimary)
            }

            Text(projectPickerSubtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ELTone.textSecondary)
                .padding(.top, 6)
                .lineLimit(2)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                Text(projectPickerActionTitle)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(ELTone.textPrimary.opacity(0.88))
            .frame(height: 16, alignment: .bottom)
        }
    }

    private var pipelineStateContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: dotGlow ? Color.white.opacity(0.50) : .clear,
                        radius: 4
                    )

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ELTone.textPrimary)
                    .animation(nil, value: title)

                Spacer(minLength: 0)

                if let startDate = viewModel.processingStartDate {
                    ProcessingDurationView(startDate: startDate)
                }
            }

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ELTone.textSecondary)
                .padding(.top, 6)
                .lineLimit(2)
                .animation(nil, value: subtitle)

            Spacer(minLength: 0)

            Group {
                switch viewModel.pipelineState {
                case .idle:
                    LevelBarView(level: audioCapture.inputLevel, active: false)
                case .listening:
                    LevelBarView(level: audioCapture.inputLevel, active: true)
                case .thinking:
                    ThinkingDotsView()
                case .speaking:
                    MiniWaveformView(voicePipelineService: voicePipelineService)
                case .failed:
                    FailureIndicatorView()
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
    }

    private func startIndexing() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index This Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedURL = url

        Task {
            await viewModel.indexingService.index(projectAt: url)
        }
    }
}

struct ProcessingDurationView: View {
    let startDate: Date

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 1)) { context in
            Text(formattedElapsed(since: startDate, now: context.date))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(ELTone.textSecondary)
                .frame(minWidth: 30, alignment: .trailing)
        }
    }

    private func formattedElapsed(since startDate: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startDate)))

        if elapsed < 60 {
            return "\(elapsed)s"
        }

        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct LevelBarView: View {
    let level: CGFloat
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 2)

                Capsule()
                    .fill(Color.white.opacity(active ? 0.82 : 0.20))
                    .frame(width: geo.size.width * max(0, min(1, level)), height: 2)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

struct ThinkingDotsView: View {
    @State private var phase = 0

    private let opacities: [[Double]] = [
        [1.0, 0.55, 0.25],
        [0.25, 1.0, 0.55],
        [0.55, 0.25, 1.0]
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(opacities[phase][index]))
                    .frame(width: 4, height: 4)
                    .animation(.easeInOut(duration: 0.35), value: phase)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}

struct FailureIndicatorView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Check services and try again")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(ELTone.denied.opacity(0.92))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct MiniWaveformView: View {
    @ObservedObject var voicePipelineService: VoicePipelineService

    private static let barCount = 18

    private var interpolatedSamples: [CGFloat] {
        let src = voicePipelineService.playbackWaveformSamples
        guard src.count >= 2 else {
            return Array(repeating: 0.15, count: Self.barCount)
        }
        guard src.count != Self.barCount else { return src }

        return (0..<Self.barCount).map { index in
            let t = CGFloat(index) / CGFloat(Self.barCount - 1)
            let srcPos = t * CGFloat(src.count - 1)
            let lo = Int(srcPos)
            let hi = min(lo + 1, src.count - 1)
            let frac = srcPos - CGFloat(lo)
            return src[lo] * (1 - frac) + src[hi] * frac
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(interpolatedSamples.enumerated()), id: \.offset) { index, sample in
                let mid = CGFloat(Self.barCount - 1) / 2
                let distance = abs(CGFloat(index) - mid) / mid
                let opacity = 0.22 + (1 - Double(distance)) * 0.72
                let centerBias = 0.82 + (1 - distance) * 0.40
                let voicedSample = CGFloat(pow(Double(max(sample, 0.08)), 0.82)) * centerBias
                let minHeight = 3 + (1 - distance) * 1.5
                let barHeight = min(18, max(minHeight, voicedSample * 14))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(opacity),
                                Color.white.opacity(opacity * 0.06)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2, height: barHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: voicePipelineService.playbackWaveformSamples)
    }
}

struct WaveformView: View {
    @ObservedObject var audioCapture: AudioCaptureService

    /// Target bar count — chosen to fill the panel width at bar:2 + gap:2
    private static let targetBarCount = 48

    /// Linearly interpolate whatever sample count arrives up to targetBarCount.
    /// With ~30 samples this upsamples; with more it downsamples gracefully.
    private var interpolatedSamples: [CGFloat] {
        let src = audioCapture.waveformSamples
        guard src.count >= 2 else {
            return Array(repeating: 0.08, count: Self.targetBarCount)
        }
        guard src.count != Self.targetBarCount else { return src }

        return (0..<Self.targetBarCount).map { i in
            let t      = CGFloat(i) / CGFloat(Self.targetBarCount - 1)
            let srcPos = t * CGFloat(src.count - 1)
            let lo     = Int(srcPos)
            let hi     = min(lo + 1, src.count - 1)
            let frac   = srcPos - CGFloat(lo)
            return src[lo] * (1 - frac) + src[hi] * frac
        }
    }

    private var statusColor: Color {
        if audioCapture.isRecording { return ELTone.recording }
        switch audioCapture.permissionState {
        case .granted:  return audioCapture.isMonitoring ? Color.white.opacity(0.88) : ELTone.idle
        case .denied:   return ELTone.denied
        case .unknown:  return ELTone.idle
        }
    }

    private var statusLabel: String {
        if audioCapture.isRecording                        { return "REC"  }
        if audioCapture.permissionState == .denied         { return "OFF"  }
        return audioCapture.isMonitoring ? "LIVE" : "IDLE"
    }

    private var transcriptDisplayText: String {
        let transcript = audioCapture.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? audioCapture.transcriptionStatusMessage : transcript
    }

    private var transcriptColor: Color {
        audioCapture.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ELTone.textMuted
            : ELTone.textPrimary
    }

    var body: some View {
        ZStack {
            if audioCapture.permissionState == .denied {
                deniedState
            } else {
                liveState
            }
        }
        .frame(height: 128)
        .elPanel(radius: 14)
    }

    private var deniedState: some View {
        VStack(spacing: 7) {
            Image(systemName: "mic.slash")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ELTone.textMuted)
            Text("Microphone access required")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ELTone.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
    }

    private var liveState: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header
            HStack(spacing: 5) {
                Text("Input")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ELTone.textPrimary)
                Spacer(minLength: 0)
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                Text(statusLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(ELTone.textSecondary)
            }

            // Bars
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(interpolatedSamples.enumerated()), id: \.offset) { index, sample in
                    WaveformBar(
                        sample: sample,
                        index: index,
                        total: Self.targetBarCount,
                        isRecording: audioCapture.isRecording
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.08), value: audioCapture.waveformSamples)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ELTone.textMuted)
                    .padding(.top, 1)

                SmoothTranscriptText(
                    text: transcriptDisplayText,
                    color: transcriptColor
                )
            }
            .frame(minHeight: 28, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct SmoothTranscriptText: View {
    let text: String
    let color: Color

    @State private var displayedText = ""
    @State private var previousText: String?
    @State private var currentOpacity = 1.0
    @State private var currentBlur: CGFloat = 0
    @State private var currentOffset: CGFloat = 0
    @State private var previousOpacity = 0.0
    @State private var previousBlur: CGFloat = 0
    @State private var previousOffset: CGFloat = 0
    @State private var transitionTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let previousText {
                transcriptLayer(previousText)
                    .opacity(previousOpacity)
                    .blur(radius: previousBlur)
                    .offset(y: previousOffset)
            }

            transcriptLayer(displayedText)
                .opacity(currentOpacity)
                .blur(radius: currentBlur)
                .offset(y: currentOffset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            displayedText = text
        }
        .onDisappear {
            transitionTask?.cancel()
        }
        .onChange(of: text) { _, newValue in
            transition(to: newValue)
        }
    }

    private func transcriptLayer(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isAppendUpdate(from currentText: String, to nextText: String) -> Bool {
        guard currentText.isEmpty == false, nextText.isEmpty == false else { return false }
        return nextText.hasPrefix(currentText)
    }

    private func resetVisualState() {
        previousText = nil
        currentOpacity = 1
        currentBlur = 0
        currentOffset = 0
        previousOpacity = 0
        previousBlur = 0
        previousOffset = 0
    }

    @MainActor
    private func transition(to newValue: String) {
        transitionTask?.cancel()

        guard displayedText.isEmpty == false, displayedText != newValue else {
            displayedText = newValue
            resetVisualState()
            return
        }

        let outgoingText = displayedText
        let isAppendTransition = isAppendUpdate(from: outgoingText, to: newValue)

        transitionTask = Task { @MainActor in
            previousText = outgoingText
            previousOpacity = 1
            previousBlur = 0
            previousOffset = 0

            displayedText = newValue
            currentOpacity = isAppendTransition ? 0.58 : 0.42
            currentBlur = isAppendTransition ? 0.55 : 1.05
            currentOffset = isAppendTransition ? 2.0 : 1.6

            withAnimation(.easeOut(duration: isAppendTransition ? 0.12 : 0.10)) {
                previousOpacity = isAppendTransition ? 0.05 : 0
                previousBlur = isAppendTransition ? 0.35 : 0.75
                previousOffset = isAppendTransition ? -0.2 : -0.6
            }

            withAnimation(
                .interactiveSpring(
                    response: isAppendTransition ? 0.26 : 0.22,
                    dampingFraction: isAppendTransition ? 0.95 : 0.98,
                    blendDuration: 0.10
                )
            ) {
                currentOpacity = 1
                currentBlur = 0
                currentOffset = 0
            }

            try? await Task.sleep(nanoseconds: isAppendTransition ? 220_000_000 : 170_000_000)
            guard Task.isCancelled == false else { return }

            previousText = nil
            previousOpacity = 0
            previousBlur = 0
            previousOffset = 0
        }
    }
}

struct WaveformBar: View {
    let sample: CGFloat
    let index: Int
    let total: Int
    let isRecording: Bool

    private var opacity: Double {
        let mid  = Double(total - 1) / 2.0
        let dist = abs(Double(index) - mid) / mid
        return 0.10 + (1.0 - dist) * 0.78
    }

    var body: some View {
        let height = max(8, sample * 80)
        let base   = isRecording ? ELTone.recording : Color.white

        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        base.opacity(opacity),
                        base.opacity(opacity * 0.66)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3, height: height)
    }
}

#Preview {
    ZStack {
        Color(red: 0.067, green: 0.063, blue: 0.059)
        NotchContentView(viewModel: NotchViewModel())
            .frame(width: 400)
    }
    .frame(width: 440, height: 160)
}
