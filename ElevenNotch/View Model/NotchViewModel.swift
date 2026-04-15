//
//  NotchViewModel.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 26/03/2026.
//

import Cocoa
import Combine
import Foundation
import SwiftUI

final class NotchViewModel: NSObject, ObservableObject {
    private enum APIKeys {
        static let elevenLabs = ""
        static let mistral = ""
        static let turbopuffer = ""
    }

    var cancellables: Set<AnyCancellable> = []
    let inset: CGFloat
    let audioCapture = AudioCaptureService()

    @PublishedPersist(key: "indexedProjectPath", defaultValue: "")
    var indexedProjectPath: String

    @PublishedPersist(key: "mistralAPIKey", defaultValue: APIKeys.mistral)
    var mistralAPIKey: String

    @PublishedPersist(key: "turbopufferAPIKey", defaultValue: APIKeys.turbopuffer)
    var turbopufferAPIKey: String

    @PublishedPersist(key: "elevenLabsAPIKey", defaultValue: APIKeys.elevenLabs)
    var elevenLabsAPIKey: String

    lazy var indexingService = CodebaseIndexingService(
        mistralAPIKey: mistralAPIKey,
        turbopufferAPIKey: turbopufferAPIKey
    )
    lazy var voicePipelineService = VoicePipelineService(
        indexingService: indexingService,
        mistralAPIKey: mistralAPIKey,
        elevenLabsAPIKey: elevenLabsAPIKey
    )

    let animation: Animation = .interactiveSpring(duration: 0.5, extraBounce: 0.25, blendDuration: 0.125)
    let notchOpenedSize: CGSize = .init(width: 500, height: 204)
    let dropDetectorRange: CGFloat = 32

    @Published private(set) var status: Status = .closed
    @Published var openReason: OpenReason = .unknown
    @Published var contentType: ContentType = .normal

    @Published var spacing: CGFloat = 16
    @Published var cornerRadius: CGFloat = 16
    @Published var deviceNotchRect: CGRect = .zero
    @Published var screenRect: CGRect = .zero
    @Published var commandKeyPressed: Bool = false
    @Published var notchVisible: Bool = true
    @Published private(set) var pipelineState: PipelineState = .idle
    @Published private(set) var processingStartDate: Date?


    @PublishedPersist(key: "hapticFeedback", defaultValue: true)
    var hapticFeedback: Bool

    let hapticSender = PassthroughSubject<Void, Never>()
    private var pendingUtteranceCommitTask: Task<Void, Never>?
    private var lastSpeechActivityAt: Date = .distantPast
    private var lastTranscriptUpdateAt: Date = .distantPast
    private var lastProcessedTranscript = ""


    init(inset: CGFloat = -4) {
        self.inset = inset
        super.init()
        setupCancellables()
        if !indexedProjectPath.isEmpty {
            let url = URL(fileURLWithPath: indexedProjectPath)
            Task {
                await indexingService.index(projectAt: url)
            }
        }
    }

    deinit {
        destroy()
    }

    enum Status: String, Codable, Hashable, Equatable {
        case closed
        case opened
        case popping
    }

    enum OpenReason: String, Codable, Hashable, Equatable {
        case click
        case drag
        case boot
        case unknown
    }

    enum ContentType: Int, Codable, Hashable, Equatable {
        case normal
        case menu
        case settings
    }

    enum PipelineState: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case failed(String)
    }

    private var listeningLevelThreshold: CGFloat {
        0.08
    }

    var notchOpenedRect: CGRect {
        .init(
            x: screenRect.origin.x + (screenRect.width - notchOpenedSize.width) / 2,
            y: screenRect.origin.y + screenRect.height - notchOpenedSize.height,
            width: notchOpenedSize.width,
            height: notchOpenedSize.height
        )
    }

    var headlineOpenedRect: CGRect {
        .init(
            x: screenRect.origin.x + (screenRect.width - notchOpenedSize.width) / 2,
            y: screenRect.origin.y + screenRect.height - deviceNotchRect.height,
            width: notchOpenedSize.width,
            height: deviceNotchRect.height
        )
    }

    func openNotch(_ reason: OpenReason) {
        openReason = reason
        status = .opened
        contentType = .normal
        NSApp.activate(ignoringOtherApps: true)
    }

    func notchClose() {
        openReason = .unknown
        status = .closed
        contentType = .normal
    }

    func showSettings() {
        contentType = .settings
    }

    func toggleSettings() {
        contentType = contentType == .settings ? .normal : .settings
    }

    func notchPop() {
        openReason = .unknown
        status = .popping
    }
}

extension NotchViewModel {
    func setupCancellables() {
        let events = EventMonitors.shared
        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let mouseLocation: NSPoint = NSEvent.mouseLocation

                switch status {
                case .opened:
                    if !notchOpenedRect.contains(mouseLocation) {
                        notchClose()
                    } else if deviceNotchRect.insetBy(dx: inset, dy: inset).contains(mouseLocation) {
                        notchClose()
                    }
                case .closed, .popping:
                    if deviceNotchRect.insetBy(dx: inset, dy: inset).contains(mouseLocation) {
                        openNotch(.click)
                    }
                }
            }
            .store(in: &cancellables)

        events.commandKeyPress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] input in
                guard let self = self else { return }
                commandKeyPressed = input
            }
            .store(in: &cancellables)

        events.mouseLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mouseLocation in
                guard let self = self else { return }
                let mouseLocation: NSPoint = NSEvent.mouseLocation
                let aboutToOpen = deviceNotchRect.insetBy(dx: inset, dy: inset).contains(mouseLocation)
                if status == .closed, aboutToOpen {
                    notchPop()
                }

                if status == .popping, !aboutToOpen {
                    notchClose()
                }
            }
            .store(in: &cancellables)

        $status
            .filter { $0 != .closed }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                withAnimation { self?.notchVisible = true }
            }
            .store(in: &cancellables)

        $status
            .filter { $0 == .popping }
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] _ in
                guard NSEvent.pressedMouseButtons == 0 else { return }
                self?.hapticSender.send()
            }
            .store(in: &cancellables)


        hapticSender
            .throttle(for: .seconds(0.5), scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] _ in
                guard self?.hapticFeedback ?? false else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            $mistralAPIKey.removeDuplicates(),
            $turbopufferAPIKey.removeDuplicates(),
            $elevenLabsAPIKey.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] mistral, turbopuffer, elevenLabs in
            self?.applyAPIKeys(
                mistral: mistral,
                turbopuffer: turbopuffer,
                elevenLabs: elevenLabs
            )
        }
        .store(in: &cancellables)

        $status
            .debounce(for: 0.5, scheduler: DispatchQueue.global())
            .filter { $0 == .closed }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                withAnimation {
                    self?.notchVisible = false
                }
            }
            .store(in: &cancellables)

        $status
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.syncAudioCapture(with: status)
            }
            .store(in: &cancellables)

        audioCapture.$inputLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.handleInputLevelChange(level)
            }
            .store(in: &cancellables)

        let pipelinePublishers: [AnyPublisher<Void, Never>] = [
            audioCapture.$inputLevel.map { _ in () }.eraseToAnyPublisher(),
            audioCapture.$permissionState.map { _ in () }.eraseToAnyPublisher(),
            audioCapture.$isMonitoring.map { _ in () }.eraseToAnyPublisher(),
            indexingService.$state.map { _ in () }.eraseToAnyPublisher(),
            voicePipelineService.$state.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(pipelinePublishers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.refreshPipelineState()
            }
            .store(in: &cancellables)

        audioCapture.$fullTranscriptText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.handleTranscriptChange(transcript)
            }
            .store(in: &cancellables)

        refreshPipelineState()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        pendingUtteranceCommitTask?.cancel()
        pendingUtteranceCommitTask = nil
        voicePipelineService.stop()
        audioCapture.stop()
    }

    private func refreshPipelineState() {
        syncProcessingStartDate()
        pipelineState = resolvedPipelineState()
    }

    private func syncProcessingStartDate() {
        let isProcessingActive = indexingService.state.isIndexing || voicePipelineService.state.isProcessing

        if isProcessingActive {
            if processingStartDate == nil {
                processingStartDate = Date()
            }
        } else {
            processingStartDate = nil
        }
    }

    private func applyAPIKeys(mistral: String, turbopuffer: String, elevenLabs: String) {
        let normalizedMistral = mistral.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTurbopuffer = turbopuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedElevenLabs = elevenLabs.trimmingCharacters(in: .whitespacesAndNewlines)

        indexingService.updateAPIKeys(
            mistralAPIKey: normalizedMistral,
            turbopufferAPIKey: normalizedTurbopuffer
        )
        voicePipelineService.updateAPIKeys(
            mistralAPIKey: normalizedMistral,
            elevenLabsAPIKey: normalizedElevenLabs
        )
        refreshPipelineState()
    }

    private func syncAudioCapture(with status: Status) {
        switch status {
        case .opened:
            audioCapture.activateMicrophone()
        case .closed, .popping:
            pendingUtteranceCommitTask?.cancel()
            pendingUtteranceCommitTask = nil
            lastSpeechActivityAt = .distantPast
            lastTranscriptUpdateAt = .distantPast
            lastProcessedTranscript = ""
            audioCapture.stop()
        }
    }

    private func resolvedPipelineState() -> PipelineState {
        switch voicePipelineService.state {
        case .speaking:
            return .speaking
        case .retrieving, .thinking:
            return .thinking
        case .idle:
            break
        case .failed(let message):
            if audioCapture.permissionState == .granted,
               audioCapture.isMonitoring,
               audioCapture.inputLevel >= listeningLevelThreshold {
                return .listening
            }
            return .failed(message)
        }

        if indexingService.state.isIndexing {
            return .thinking
        }

        if audioCapture.permissionState == .granted,
           audioCapture.isMonitoring,
           audioCapture.inputLevel >= listeningLevelThreshold {
            return .listening
        }

        return .idle
    }

    private func handleInputLevelChange(_ level: CGFloat) {
        if level >= listeningLevelThreshold {
            lastSpeechActivityAt = Date()
            pendingUtteranceCommitTask?.cancel()
            pendingUtteranceCommitTask = nil
            return
        }

        let transcript = audioCapture.fullTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.isEmpty == false,
              pendingUtteranceCommitTask == nil,
              voicePipelineService.state.isProcessing == false else {
            return
        }

        scheduleUtteranceCommit(for: transcript)
    }

    private func handleTranscriptChange(_ transcript: String) {
        lastTranscriptUpdateAt = Date()

        guard transcript.isEmpty == false else {
            pendingUtteranceCommitTask?.cancel()
            pendingUtteranceCommitTask = nil
            lastProcessedTranscript = ""
            return
        }

        guard voicePipelineService.state.isProcessing == false else { return }
        scheduleUtteranceCommit(for: transcript)
    }

    private func scheduleUtteranceCommit(for transcript: String) {
        pendingUtteranceCommitTask?.cancel()

        let delay = utteranceCommitDelay(for: transcript)
        pendingUtteranceCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.attemptUtteranceCommit(expected: transcript)
            }
        }
    }

    private func attemptUtteranceCommit(expected transcript: String) {
        let currentTranscript = audioCapture.fullTranscriptText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard currentTranscript == transcript else { return }
        guard transcript.isEmpty == false else { return }
        guard transcript != lastProcessedTranscript else { return }
        guard indexingService.state.isReady else { return }
        guard voicePipelineService.state.isProcessing == false else { return }
        guard audioCapture.inputLevel < listeningLevelThreshold else { return }

        let now = Date()
        let requiredSilence = utteranceCommitDelay(for: transcript)
        if now.timeIntervalSince(lastSpeechActivityAt) < requiredSilence {
            scheduleUtteranceCommit(for: transcript)
            return
        }

        if now.timeIntervalSince(lastTranscriptUpdateAt) < transcriptStabilityDelay(for: transcript) {
            scheduleUtteranceCommit(for: transcript)
            return
        }

        pendingUtteranceCommitTask = nil
        lastProcessedTranscript = transcript

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioCapture.suspendTranscription()
            await self.voicePipelineService.process(transcript: transcript)
            self.audioCapture.resumeTranscriptionIfPossible()
        }
    }

    private func utteranceCommitDelay(for transcript: String) -> TimeInterval {
        let wordCount = transcript.split(whereSeparator: \.isWhitespace).count

        if transcriptEndsWithBoundary(transcript) {
            return 0.85
        }

        switch wordCount {
        case 0...3:
            return 1.8
        case 4...8:
            return 1.45
        default:
            return 1.2
        }
    }

    private func transcriptStabilityDelay(for transcript: String) -> TimeInterval {
        transcriptEndsWithBoundary(transcript) ? 0.25 : 0.55
    }

    private func transcriptEndsWithBoundary(_ transcript: String) -> Bool {
        guard let lastCharacter = transcript.last else { return false }
        return ".!?".contains(lastCharacter)
    }
}
