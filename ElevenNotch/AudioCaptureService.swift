//
//  AudioCaptureService.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 12/04/2026.
//

import AppKit
import AVFoundation
import Foundation
import Combine
internal import UniformTypeIdentifiers

@MainActor
final class AudioCaptureService: NSObject, ObservableObject {
    enum PermissionState {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var permissionState: PermissionState = .unknown
    @Published private(set) var waveformSamples: [CGFloat]
    @Published private(set) var inputLevel: CGFloat = 0
    @Published private(set) var isMonitoring = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage: String = "Microphone idle"
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var fullTranscriptText: String = ""
    @Published private(set) var transcriptText: String = ""
    @Published private(set) var transcriptionStatusMessage: String = "Live transcription idle"
    @Published private(set) var isTranscribing = false

    nonisolated(unsafe) private let engine = AVAudioEngine()
    private let speechTranscription = SpeechTranscriptionService()
    nonisolated(unsafe) private var speechProcessor: SpeechTranscriptionService?
    private let meterSampleCount = 24
    private let meterUpdateInterval: TimeInterval = 1.0 / 30.0
    private let silenceFloor: CGFloat = 0.02
    private let attackSmoothing: CGFloat = 0.42
    private let decaySmoothing: CGFloat = 0.16
    private let preferredPanelDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
    private let scratchDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ElevenNotch", isDirectory: true)

    nonisolated(unsafe) private var tapInstalled = false
    private let recordingLock = NSLock()
    nonisolated(unsafe) private var recordingFile: AVAudioFile?
    private var temporaryRecordingURL: URL?
    private var meterTimer: Timer?
    private var targetLevel: CGFloat = 0
    private var smoothedLevel: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()

    override init() {
        waveformSamples = Array(repeating: 0.04, count: meterSampleCount)
        targetLevel = 0.04
        smoothedLevel = 0.04
        super.init()
        speechProcessor = speechTranscription
        bindSpeechTranscription()
    }

    func activateMicrophone() {
        switch currentPermissionState() {
        case .granted:
            permissionState = .granted
            startMonitoringIfNeeded()
        case .denied:
            permissionState = .denied
            statusMessage = "Microphone access is disabled"
        case .unknown:
            statusMessage = "Requesting microphone access"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [service = self] in
                    service?.applyMicrophonePermission(granted)
                }
            }
        }
    }

    func toggleRecording() {
        isRecording ? stopRecordingAndSave() : startRecording()
    }

    func suspendTranscription() {
        speechTranscription.stop()
    }

    func resumeTranscriptionIfPossible() {
        guard permissionState == .granted, isMonitoring else { return }

        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }

        speechTranscription.activate(with: format)
    }

    func stop() {
        finishRecording(shouldSave: false)
        stopMeterTimer()
        resetMeters()
        speechTranscription.stop()

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        if engine.isRunning {
            engine.stop()
        }

        isMonitoring = false
        if permissionState == .granted {
            statusMessage = "Microphone idle"
        }
    }

    private func currentPermissionState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private func applyMicrophonePermission(_ granted: Bool) {
        permissionState = granted ? .granted : .denied
        if granted {
            startMonitoringIfNeeded()
        } else {
            statusMessage = "Microphone access is disabled"
        }
    }

    private func startMonitoringIfNeeded() {
        guard !engine.isRunning else {
            isMonitoring = true
            startMeterTimerIfNeeded()
            speechTranscription.activate(with: engine.inputNode.inputFormat(forBus: 0))
            if !isRecording {
                statusMessage = "Listening to microphone"
            }
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        guard format.channelCount > 0 else {
            statusMessage = "No microphone input is available"
            return
        }

        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        tapInstalled = true

        do {
            try engine.start()
            startMeterTimerIfNeeded()
            isMonitoring = true
            speechTranscription.activate(with: format)
            statusMessage = isRecording ? "Recording in progress" : "Listening to microphone"
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            statusMessage = "Unable to start microphone input"
        }
    }

    nonisolated private func handle(buffer: AVAudioPCMBuffer) {
        let level = normalizedLevel(from: buffer)

        recordingLock.lock()
        let activeRecordingFile = recordingFile
        recordingLock.unlock()

        if let activeRecordingFile {
            do {
                try activeRecordingFile.write(from: buffer)
            } catch {
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Recording stopped because the file could not be written"
                    self?.finishRecording(shouldSave: false)
                }
            }
        }

        speechProcessor?.process(buffer: buffer)

        Task { @MainActor [weak self, level] in
            guard let self else { return }
            self.targetLevel = level
        }
    }

    private func startMeterTimerIfNeeded() {
        guard meterTimer == nil else { return }

        let timer = Timer(timeInterval: meterUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickMeter()
            }
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func tickMeter() {
        let smoothing = targetLevel > smoothedLevel ? attackSmoothing : decaySmoothing
        smoothedLevel += (targetLevel - smoothedLevel) * smoothing

        let displayedLevel = min(max(smoothedLevel, silenceFloor), 1)
        inputLevel = displayedLevel
        waveformSamples.removeFirst()
        waveformSamples.append(displayedLevel)
    }

    nonisolated private func normalizedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData else {
            return silenceFloor
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else {
            return silenceFloor
        }

        var sum: Float = 0
        for channelIndex in 0..<channelCount {
            let channel = channelData[channelIndex]
            for sampleIndex in 0..<frameLength {
                let sample = channel[sampleIndex]
                sum += sample * sample
            }
        }

        let meanSquare = sum / Float(frameLength * channelCount)
        let rms = sqrt(meanSquare)
        let boostedLevel = pow(CGFloat(rms), 0.6) * 1.8
        return min(max(boostedLevel, silenceFloor), 1)
    }

    private func startRecording() {
        activateMicrophone()
        guard permissionState == .granted else { return }
        guard engine.inputNode.inputFormat(forBus: 0).channelCount > 0 else {
            statusMessage = "No microphone input is available"
            return
        }

        if !engine.isRunning {
            startMonitoringIfNeeded()
        }

        let recordingURL = temporaryRecordingURLForNewSession()

        do {
            let file = try AVAudioFile(
                forWriting: recordingURL,
                settings: engine.inputNode.inputFormat(forBus: 0).settings,
                commonFormat: engine.inputNode.inputFormat(forBus: 0).commonFormat,
                interleaved: engine.inputNode.inputFormat(forBus: 0).isInterleaved
            )
            recordingLock.lock()
            recordingFile = file
            recordingLock.unlock()
            temporaryRecordingURL = recordingURL
            isRecording = true
            statusMessage = "Recording in progress"
        } catch {
            statusMessage = "Unable to start recording"
            recordingLock.lock()
            recordingFile = nil
            recordingLock.unlock()
            temporaryRecordingURL = nil
        }
    }

    private func stopRecordingAndSave() {
        finishRecording(shouldSave: true)
    }

    private func finishRecording(shouldSave: Bool) {
        let recordedFileURL = temporaryRecordingURL

        recordingLock.lock()
        recordingFile = nil
        recordingLock.unlock()
        temporaryRecordingURL = nil

        guard isRecording else { return }
        isRecording = false

        if shouldSave, let recordedFileURL {
            presentSavePanel(for: recordedFileURL)
        } else {
            if let recordedFileURL {
                try? FileManager.default.removeItem(at: recordedFileURL)
            }
            statusMessage = isMonitoring ? "Listening to microphone" : "Microphone idle"
        }
    }

    private func presentSavePanel(for sourceURL: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "caf") ?? .audio]
        panel.canCreateDirectories = true
        panel.directoryURL = preferredPanelDirectory
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.title = "Save Recording"
        panel.message = "Choose where to save your recording in Documents."

        let response = panel.runModal()
        guard response == .OK, let destinationURL = panel.url else {
            try? FileManager.default.removeItem(at: sourceURL)
            statusMessage = "Recording discarded"
            return
        }

        let finalURL = destinationURL.pathExtension.isEmpty
            ? destinationURL.appendingPathExtension("caf")
            : destinationURL

        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: finalURL)
            try FileManager.default.removeItem(at: sourceURL)
            lastSavedURL = finalURL
            statusMessage = "Saved to \(finalURL.lastPathComponent)"
        } catch {
            statusMessage = "Recording could not be saved"
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }

    private func temporaryRecordingURLForNewSession() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "NotchRecording-\(formatter.string(from: .now)).caf"
        try? FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return scratchDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private func resetMeters() {
        waveformSamples = Array(repeating: 0.04, count: meterSampleCount)
        inputLevel = 0
        targetLevel = 0.04
        smoothedLevel = 0.04
    }

    private func bindSpeechTranscription() {
        speechTranscription.$fullTranscriptText
            .sink { [weak self] fullTranscriptText in
                self?.fullTranscriptText = fullTranscriptText
            }
            .store(in: &cancellables)

        speechTranscription.$transcriptText
            .sink { [weak self] transcriptText in
                self?.transcriptText = transcriptText
            }
            .store(in: &cancellables)

        speechTranscription.$statusMessage
            .sink { [weak self] statusMessage in
                self?.transcriptionStatusMessage = statusMessage
            }
            .store(in: &cancellables)

        speechTranscription.$isTranscribing
            .sink { [weak self] isTranscribing in
                self?.isTranscribing = isTranscribing
            }
            .store(in: &cancellables)
    }
}
