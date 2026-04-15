//
//  SpeechTranscriptionService.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 12/04/2026.
//

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechTranscriptionService: ObservableObject {
    enum AuthorizationState {
        case unknown
        case granted
        case denied
        case unsupported
    }

    @Published private(set) var authorizationState: AuthorizationState = .unknown
    @Published private(set) var fullTranscriptText: String = ""
    @Published private(set) var transcriptText: String = ""
    @Published private(set) var statusMessage: String = "Live transcription idle"
    @Published private(set) var isTranscribing = false

    private let rollingTranscriptWordLimit = 12
    private let rollingTranscriptCharacterLimit = 72
    private let transcriptDebounceInterval: TimeInterval = 0.18
    private let transcriptBoundaryInterval: TimeInterval = 0.10
    private let transcriptRevisionInterval: TimeInterval = 0.26
    private var pendingAudioFormat: AVAudioFormat?
    private var pendingTranscriptText: String?
    private var transcriptCommitTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupToken = UUID()
    nonisolated(unsafe) private var processBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    nonisolated(unsafe) private var stopSessionHandler: (() -> Void)?

    func activate(with audioFormat: AVAudioFormat) {
        pendingAudioFormat = audioFormat

        guard !hasActiveSession else {
            if transcriptText.isEmpty {
                statusMessage = "Listening for speech"
            }
            return
        }

        guard startupTask == nil else { return }

        let token = UUID()
        startupToken = token
        statusMessage = "Preparing live transcription"
        startupTask = Task { [weak self] in
            await self?.authorizeAndStartSession(token: token)
        }
    }

    func stop() {
        startupToken = UUID()
        startupTask?.cancel()
        startupTask = nil
        clearSessionHandlers()

        fullTranscriptText = ""
        pendingTranscriptText = nil
        transcriptCommitTask?.cancel()
        transcriptCommitTask = nil
        transcriptText = ""
        isTranscribing = false

        switch authorizationState {
        case .granted, .unknown:
            statusMessage = "Live transcription idle"
        case .denied:
            statusMessage = "Speech recognition access is disabled"
        case .unsupported:
            statusMessage = "Speech recognition is unavailable"
        }
    }

    nonisolated func process(buffer: AVAudioPCMBuffer) {
        processBufferHandler?(buffer)
    }

    private var hasActiveSession: Bool {
        processBufferHandler != nil
    }

    private func clearSessionHandlers() {
        stopSessionHandler?()
        processBufferHandler = nil
        stopSessionHandler = nil
    }

    private func authorizeAndStartSession(token: UUID) async {
        defer {
            if startupToken == token {
                startupTask = nil
            }
        }

        guard startupToken == token else { return }

        let authorizationStatus = await resolvedAuthorizationStatus()

        guard startupToken == token else { return }

        switch authorizationStatus {
        case .authorized:
            authorizationState = .granted
        case .denied, .restricted:
            authorizationState = .denied
            fullTranscriptText = ""
            transcriptText = ""
            isTranscribing = false
            statusMessage = "Speech recognition access is disabled"
            return
        case .notDetermined:
            authorizationState = .unknown
            fullTranscriptText = ""
            transcriptText = ""
            isTranscribing = false
            statusMessage = "Speech recognition permission is pending"
            return
        @unknown default:
            authorizationState = .unknown
            fullTranscriptText = ""
            transcriptText = ""
            isTranscribing = false
            statusMessage = "Speech recognition is unavailable"
            return
        }

        guard pendingAudioFormat != nil else {
            statusMessage = "No audio input is available for transcription"
            return
        }

        fullTranscriptText = ""
        transcriptText = ""

        if #available(macOS 26.0, *) {
            await startModernSession()
        } else {
            startLegacySession()
        }
    }

    private func resolvedAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentStatus == .notDetermined else { return currentStatus }

        statusMessage = "Requesting speech recognition access"

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    @available(macOS 26.0, *)
    private func startModernSession() async {
        guard let audioFormat = pendingAudioFormat else {
            statusMessage = "No audio input is available for transcription"
            return
        }

        guard SpeechTranscriber.isAvailable else {
            authorizationState = .unsupported
            isTranscribing = false
            statusMessage = "Speech transcription is unavailable on this Mac"
            return
        }

        guard let locale = await ModernSpeechTranscriptionSession.preferredLocale() else {
            authorizationState = .unsupported
            isTranscribing = false
            statusMessage = "No supported speech locale is available"
            return
        }

        let session = ModernSpeechTranscriptionSession(locale: locale, audioFormat: audioFormat) { [weak self] update in
            guard let self else { return }
            self.apply(update: update)
        }
        processBufferHandler = { buffer in
            let input = AnalyzerInput(buffer: buffer)
            Task {
                await session.append(input)
            }
        }
        stopSessionHandler = {
            Task {
                await session.stop()
            }
        }
        await session.start()
    }

    private func startLegacySession() {
        guard let session = LegacySpeechTranscriptionSession(
            locale: .autoupdatingCurrent,
            updateHandler: { [weak self] update in
                guard let self else { return }
                self.apply(update: update)
            }
        ) else {
            authorizationState = .unsupported
            isTranscribing = false
            statusMessage = "No supported speech locale is available"
            return
        }

        guard session.start() else {
            authorizationState = .unsupported
            return
        }

        processBufferHandler = { buffer in
            session.append(buffer)
        }
        stopSessionHandler = {
            session.stop()
        }
    }

    private func apply(update: SpeechTranscriptionUpdate) {
        fullTranscriptText = update.transcriptText
        statusMessage = update.statusMessage
        isTranscribing = update.isTranscribing
        stageTranscriptUpdate(
            rollingTranscript(from: update.transcriptText),
            immediate: update.isTranscribing == false || update.transcriptText.isEmpty
        )
    }

    private func rollingTranscript(from transcript: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTranscript.isEmpty == false else { return "" }

        let words = trimmedTranscript.split(whereSeparator: \.isWhitespace)
        var displayText = trimmedTranscript
        var wasTrimmed = false

        if words.count > rollingTranscriptWordLimit {
            displayText = words
                .suffix(rollingTranscriptWordLimit)
                .joined(separator: " ")
            wasTrimmed = true
        }

        if displayText.count > rollingTranscriptCharacterLimit {
            let suffixStart = displayText.index(
                displayText.endIndex,
                offsetBy: -rollingTranscriptCharacterLimit
            )
            var condensedText = String(displayText[suffixStart...])

            if let firstSpaceIndex = condensedText.firstIndex(of: " ") {
                condensedText = String(condensedText[condensedText.index(after: firstSpaceIndex)...])
            }

            if condensedText.isEmpty == false {
                displayText = condensedText
                wasTrimmed = true
            }
        }

        return wasTrimmed ? "…" + displayText : displayText
    }

    private func stageTranscriptUpdate(_ nextTranscript: String, immediate: Bool) {
        transcriptCommitTask?.cancel()

        guard nextTranscript != transcriptText else {
            pendingTranscriptText = nil
            return
        }

        let referenceTranscript = pendingTranscriptText ?? transcriptText
        pendingTranscriptText = nextTranscript

        let delay = immediate ? 0 : preferredTranscriptDelay(
            for: nextTranscript,
            comparedTo: referenceTranscript
        )
        guard delay > 0 else {
            transcriptText = nextTranscript
            pendingTranscriptText = nil
            return
        }

        transcriptCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self, self.pendingTranscriptText == nextTranscript else { return }
                self.transcriptText = nextTranscript
                self.pendingTranscriptText = nil
            }
        }
    }

    private func preferredTranscriptDelay(
        for transcript: String,
        comparedTo referenceTranscript: String
    ) -> TimeInterval {
        guard let lastCharacter = transcript.last else {
            return transcriptDebounceInterval
        }

        if ".!?,".contains(lastCharacter) {
            return transcriptBoundaryInterval
        }

        if isMinorTranscriptRevision(from: referenceTranscript, to: transcript) {
            return transcriptRevisionInterval
        }

        return transcriptDebounceInterval
    }

    private func isMinorTranscriptRevision(from referenceTranscript: String, to transcript: String) -> Bool {
        let referenceWords = referenceTranscript.split(whereSeparator: \.isWhitespace)
        let nextWords = transcript.split(whereSeparator: \.isWhitespace)

        guard referenceWords.isEmpty == false, nextWords.isEmpty == false else {
            return false
        }

        if transcript.hasPrefix(referenceTranscript) {
            return false
        }

        if referenceTranscript.hasPrefix(transcript) {
            return true
        }

        let sharedPrefixCount = zip(referenceWords, nextWords)
            .prefix { $0 == $1 }
            .count
        let comparableWordCount = min(referenceWords.count, nextWords.count)

        return comparableWordCount - sharedPrefixCount <= 1
    }
}

private struct SpeechTranscriptionUpdate: Sendable {
    let transcriptText: String
    let statusMessage: String
    let isTranscribing: Bool
}

private final class LegacySpeechTranscriptionSession {
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let updateHandler: @MainActor @Sendable (SpeechTranscriptionUpdate) -> Void

    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscriptText = ""
    private var hasStopped = false

    init?(
        locale: Locale,
        updateHandler: @escaping @MainActor @Sendable (SpeechTranscriptionUpdate) -> Void
    ) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            return nil
        }

        self.recognizer = recognizer
        self.updateHandler = updateHandler

        recognizer.defaultTaskHint = .dictation
        recognizer.queue = .main

        request.taskHint = .dictation
        request.shouldReportPartialResults = true

        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
    }

    func start() -> Bool {
        guard recognizer.isAvailable else {
            publish(
                SpeechTranscriptionUpdate(
                    transcriptText: "",
                    statusMessage: "Speech recognition service is unavailable",
                    isTranscribing: false
                )
            )
            return false
        }

        publish(
            SpeechTranscriptionUpdate(
                transcriptText: "",
                statusMessage: "Listening for speech",
                isTranscribing: true
            )
        )

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        return true
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard hasStopped == false else { return }
        request.append(buffer)
    }

    func stop() {
        guard hasStopped == false else { return }
        hasStopped = true
        request.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let transcriptText = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            latestTranscriptText = transcriptText

            publish(
                SpeechTranscriptionUpdate(
                    transcriptText: transcriptText,
                    statusMessage: transcriptText.isEmpty ? "Listening for speech" : "Transcribing live",
                    isTranscribing: true
                )
            )
        }

        guard let error else { return }

        let nsError = error as NSError
        guard hasStopped == false, nsError.code != 301 else { return }

        publish(
            SpeechTranscriptionUpdate(
                transcriptText: latestTranscriptText,
                statusMessage: Self.message(for: nsError),
                isTranscribing: false
            )
        )
    }

    private func publish(_ update: SpeechTranscriptionUpdate) {
        Task { @MainActor in
            updateHandler(update)
        }
    }

    private static func message(for error: NSError) -> String {
        if error.domain == "kLSRErrorDomain", error.code == 102 {
            return "Speech assets are not installed"
        }

        if error.domain == "kLSRErrorDomain", error.code == 201 {
            return "Siri or Dictation is disabled"
        }

        let description = error.localizedDescription
        guard description.isEmpty == false else {
            return "Live transcription could not start"
        }
        return description
    }
}

@available(macOS 26.0, *)
private actor ModernSpeechTranscriptionSession {
    private let audioFormat: AVAudioFormat
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let updateHandler: @MainActor @Sendable (SpeechTranscriptionUpdate) -> Void

    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?

    init(
        locale: Locale,
        audioFormat: AVAudioFormat,
        updateHandler: @escaping @MainActor @Sendable (SpeechTranscriptionUpdate) -> Void
    ) {
        self.audioFormat = audioFormat
        self.updateHandler = updateHandler

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])

        var continuation: AsyncStream<AnalyzerInput>.Continuation?
        self.inputStream = AsyncStream { continuation = $0 }
        self.inputContinuation = continuation!
    }

    func start() async {
        resultTask = Task {
            await self.consumeResults()
        }
        analysisTask = Task {
            await self.runAnalysis()
        }
    }

    func append(_ input: AnalyzerInput) {
        inputContinuation.yield(input)
    }

    func stop() async {
        inputContinuation.finish()
        analysisTask?.cancel()
        resultTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    static func preferredLocale() async -> Locale? {
        if let matchedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: .autoupdatingCurrent) {
            return matchedLocale
        }

        let installedLocales = await SpeechTranscriber.installedLocales
        if let installedLocale = installedLocales.first {
            return installedLocale
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        return supportedLocales.first
    }

    private func consumeResults() async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let update = SpeechTranscriptionUpdate(
                    transcriptText: text,
                    statusMessage: text.isEmpty ? "Listening for speech" : "Transcribing live",
                    isTranscribing: true
                )
                await publish(update)
            }
        } catch is CancellationError {
            return
        } catch {
            await publish(
                SpeechTranscriptionUpdate(
                    transcriptText: "",
                    statusMessage: Self.message(for: error),
                    isTranscribing: false
                )
            )
        }
    }

    private func runAnalysis() async {
        do {
            let assetStatus = await AssetInventory.status(forModules: [transcriber])

            switch assetStatus {
            case .unsupported:
                await publish(
                    SpeechTranscriptionUpdate(
                        transcriptText: "",
                        statusMessage: "Speech transcription is unavailable for this language",
                        isTranscribing: false
                    )
                )
                return
            case .supported:
                await publish(
                    SpeechTranscriptionUpdate(
                        transcriptText: "",
                        statusMessage: "Install speech data to enable live transcription",
                        isTranscribing: false
                    )
                )
                return
            case .downloading:
                await publish(
                    SpeechTranscriptionUpdate(
                        transcriptText: "",
                        statusMessage: "Speech data is downloading",
                        isTranscribing: false
                    )
                )
            case .installed:
                break
            @unknown default:
                break
            }

            try await analyzer.prepareToAnalyze(in: audioFormat)
            await publish(
                SpeechTranscriptionUpdate(
                    transcriptText: "",
                    statusMessage: "Listening for speech",
                    isTranscribing: true
                )
            )
            try await analyzer.start(inputSequence: inputStream)
        } catch is CancellationError {
            return
        } catch {
            await publish(
                SpeechTranscriptionUpdate(
                    transcriptText: "",
                    statusMessage: Self.message(for: error),
                    isTranscribing: false
                )
            )
        }
    }

    private func publish(_ update: SpeechTranscriptionUpdate) async {
        await updateHandler(update)
    }

    private static func message(for error: Error) -> String {
        let description = (error as NSError).localizedDescription
        guard description.isEmpty == false else {
            return "Live transcription could not start"
        }
        return description
    }
}
