//
//  VoicePipelineService.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 14/04/2026.
//

import Foundation
import Combine
import AVFoundation

@MainActor
final class VoicePipelineService: ObservableObject {
    enum State: Equatable {
        case idle
        case retrieving
        case thinking
        case speaking
        case failed(String)

        var isProcessing: Bool {
            switch self {
            case .retrieving, .thinking, .speaking: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var playbackWaveformSamples: [CGFloat]

    private let indexingService: CodebaseIndexingService
    private var mistralAPIKey: String
    private var elevenLabsAPIKey: String

    private let mistralModel = "mistral-small-latest"
    private let voiceID = "pwlDGUWLQ5QKExUL31Om"
    private let ttsModel = "eleven_multilingual_v2"
    private let playbackSampleCount = 18
    private let playbackMeterInterval: TimeInterval = 1.0 / 30.0
    private let playbackSilenceFloor: CGFloat = 0.08
    private let playbackAttackSmoothing: CGFloat = 0.48
    private let playbackDecaySmoothing: CGFloat = 0.20

    private var audioPlayer: AVAudioPlayer?
    private var playbackMeterTimer: Timer?
    private var playbackTargetLevel: CGFloat
    private var playbackSmoothedLevel: CGFloat

    init(indexingService: CodebaseIndexingService,
         mistralAPIKey: String = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] ?? "",
         elevenLabsAPIKey: String = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? "") {
        self.indexingService = indexingService
        self.mistralAPIKey = mistralAPIKey
        self.elevenLabsAPIKey = elevenLabsAPIKey
        self.playbackWaveformSamples = Array(repeating: playbackSilenceFloor, count: playbackSampleCount)
        self.playbackTargetLevel = playbackSilenceFloor
        self.playbackSmoothedLevel = playbackSilenceFloor
    }

    func updateAPIKeys(mistralAPIKey: String, elevenLabsAPIKey: String) {
        self.mistralAPIKey = mistralAPIKey
        self.elevenLabsAPIKey = elevenLabsAPIKey

        if case .failed = state, !state.isProcessing {
            state = .idle
        }
    }

    // MARK: Full Pipeline: transcript -> TurboPuffer -> Mistral -> ElevenLabs TTS
    func process(transcript: String) async {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        guard !state.isProcessing else { return }
        guard !mistralAPIKey.isEmpty else {
            state = .failed("Missing Mistral API key. Add it in Settings.")
            return
        }
        guard !elevenLabsAPIKey.isEmpty else {
            state = .failed("Missing ElevenLabs API key. Add it in Settings.")
            return
        }

        do {
            // 1) Retrieve relevant code chunks from TurboPuffer
            state = .retrieving
            let results = try await indexingService.query(transcript, topK: 5)

            guard !results.isEmpty else {
                state = .failed("No relevant code found for your question")
                return
            }

            // 2) Ansewer synthesis
            state = .thinking
            let answer = try await synthesize(question: transcript, context: results)

            // 3) 11Labs TTS spoken answer
            state = .speaking
            try await speak(answer)

            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        stopPlaybackMetering(resetSamples: true)
        audioPlayer?.stop()
        audioPlayer = nil
        state = .idle
    }

    private func synthesize(question: String, context: [CodebaseIndexingService.QueryResult]) async throws -> String {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Request: Encodable {
            let model: String
            let messages: [Message]
            let max_tokens: Int
            let temperature: Double
        }

        struct Response: Decodable {
            struct Choice: Decodable {
                struct MessageContent: Decodable {
                    let content: String
                }
                let message: MessageContent
            }
            let choices: [Choice]
        }

        let contextBlock = context.enumerated().map { index, result in
            """
            --- Chunk \(index + 1) (\(result.filePath) --
            \(result.content)
            """
        }
            .joined(separator: "\n\n")

        let systemPrompt = """
        You are a concise, expert code brainstorming partner. \
        You answer questions about a codebase based only on the provided code context. \
        Keep answers to 2-4 sentences maximum — your response will be spoken aloud. \
        Be direct and specific. If the context doesn't contain enough information, say so briefly.
        """

        let userPrompt = """
        Here is the relevant code context from the codebase:
        
        \(contextBlock)
        
        Question: \(question)
        """

        let body = Request(model: mistralModel, messages: [Message(role: "system", content: systemPrompt),
                                                           Message(role: "user", content: userPrompt)], max_tokens: 180, temperature: 0.3)

        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(mistralAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown"
            throw PipelineError.mistralFailed(raw)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)

        guard let answer = decoded.choices.first?.message.content else {
            throw PipelineError.mistralFailed("Empty response from Mistral API")
        }

        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: ElevenLabs TTS methods

    private func speak(_ text: String) async throws {
        struct TTSRequest: Encodable {
            let text: String
            let model_id: String
            let voice_settings: VoiceSettings

            struct VoiceSettings: Encodable {
                let stability: Double
                let similarity_boost: Double
            }
        }

        let body = TTSRequest(
            text: text,
            model_id: ttsModel,
            voice_settings: .init(
                stability: 0.5,
                similarity_boost: 0.75
            )
        )

        let urlString = "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let raw = String(data: data, encoding: .utf8) ?? "unknown"
        print("ElevenLabs status: \(statusCode)")
        print("ElevenLabs response: \(raw)")

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown"
            throw PipelineError.ttsFailed(raw)
        }

        // Write audio to temp file and play
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpuffer_response_\(UUID().uuidString).mp3")

        try data.write(to: tempURL)

        stopPlaybackMetering(resetSamples: true)
        audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
        audioPlayer?.isMeteringEnabled = true
        audioPlayer?.prepareToPlay()
        startPlaybackMeteringIfNeeded()
        audioPlayer?.play()

        // Wait for playback to finish
        try await waitForPlayback()

        stopPlaybackMetering(resetSamples: true)
        audioPlayer = nil

        // Clean up temp file
        try? FileManager.default.removeItem(at: tempURL)
    }


    private func waitForPlayback() async throws {
        guard let player = audioPlayer else { return }

        // Poll until playback finishes or state changes
        while player.isPlaying && state == .speaking {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    private func startPlaybackMeteringIfNeeded() {
        guard playbackMeterTimer == nil else { return }

        let timer = Timer(timeInterval: playbackMeterInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickPlaybackMeter()
            }
        }
        playbackMeterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackMetering(resetSamples: Bool) {
        playbackMeterTimer?.invalidate()
        playbackMeterTimer = nil

        if resetSamples {
            playbackTargetLevel = playbackSilenceFloor
            playbackSmoothedLevel = playbackSilenceFloor
            playbackWaveformSamples = Array(repeating: playbackSilenceFloor, count: playbackSampleCount)
        }
    }

    private func tickPlaybackMeter() {
        guard let player = audioPlayer else {
            stopPlaybackMetering(resetSamples: true)
            return
        }

        player.updateMeters()
        playbackTargetLevel = normalizedPlaybackLevel(from: player)

        let smoothing = playbackTargetLevel > playbackSmoothedLevel
        ? playbackAttackSmoothing
        : playbackDecaySmoothing
        playbackSmoothedLevel += (playbackTargetLevel - playbackSmoothedLevel) * smoothing

        let displayedLevel = min(max(playbackSmoothedLevel, playbackSilenceFloor), 1)
        playbackWaveformSamples.removeFirst()
        playbackWaveformSamples.append(displayedLevel)

        if !player.isPlaying && state != .speaking {
            stopPlaybackMetering(resetSamples: true)
        }
    }

    private func normalizedPlaybackLevel(from player: AVAudioPlayer) -> CGFloat {
        guard player.numberOfChannels > 0 else {
            return playbackSilenceFloor
        }

        var strongestPower: Float = -80
        for channel in 0..<player.numberOfChannels {
            strongestPower = max(strongestPower, player.averagePower(forChannel: channel))
        }

        let clampedPower = max(strongestPower, -60)
        let linearLevel = pow(10, clampedPower / 20)
        let boostedLevel = pow(CGFloat(linearLevel), 0.55) * 1.6
        return min(max(boostedLevel, playbackSilenceFloor), 1)
    }

    enum PipelineError: Error, LocalizedError {
        case mistralFailed(String)
        case ttsFailed(String)

        var errorDescription: String? {
            switch self {
            case .mistralFailed(let msg): return "Mistral failed: \(msg)"
            case .ttsFailed(let msg):     return "ElevenLabs TTS failed: \(msg)"
            }
        }
    }
}
