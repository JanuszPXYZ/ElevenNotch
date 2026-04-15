//
//  CodebaseIndexingService.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 13/04/2026.
//

import Foundation
import Combine
import AppKit
import CryptoKit

@MainActor
final class CodebaseIndexingService: ObservableObject {
    enum State: Equatable {
        case idle
        case indexing(progress: Double, message: String)
        case ready(projectName: String, chunkCount: Int)
        case failed(String)


        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var isIndexing: Bool {
            if case .indexing = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle

    private var mistralAPIKey: String
    private var turbopufferAPIKey: String
    private let turbopufferBaseURL = "https://gcp-europe-west3.turbopuffer.com"
    private let embeddingModel = "codestral-embed-2505"
    private let embeddingDimension = 1024
    private let maxChunkCharacters = 12_000
    private let batchSize = 16
    private let namespacePrefix = "codebase"
    private var activeNamespace: String?

    private let indexedExtensions: Set<String> = ["swift", "m", "h", "mm", "py", "ts", "js", "rs", "go", "kt"]
    private let ignoredDirectories: Set<String> = [
        ".git", ".build", "DerivedData", "Pods",
        "Carthage", ".swiftpm", "build"
    ]


    init(
        mistralAPIKey: String = ProcessInfo.processInfo.environment["MISTRAL_API_KEY"] ?? "",
        turbopufferAPIKey: String = ProcessInfo.processInfo.environment["TURBOPUFFER_API_KEY"] ?? ""
    ) {
        self.mistralAPIKey = mistralAPIKey
        self.turbopufferAPIKey = turbopufferAPIKey
    }

    func updateAPIKeys(mistralAPIKey: String, turbopufferAPIKey: String) {
        self.mistralAPIKey = mistralAPIKey
        self.turbopufferAPIKey = turbopufferAPIKey

        if case .failed = state, !state.isIndexing {
            state = .idle
        }
    }


    func selectAndIndex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Index This Project"
        panel.message = "Select the root folder of the project you want to brainstorm with"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await index(projectAt: url)
        }
    }

    func index(projectAt url: URL) async {
        guard !mistralAPIKey.isEmpty, !turbopufferAPIKey.isEmpty else {
            state = .failed("Missing API keys. Add Mistral and TurboPuffer in Settings.")
            return
        }

        activeNamespace = nextNamespace(for: url)

        state = .indexing(progress: 0, message: "Scanning project files...")

        do {
            let files = try await Self.collectFiles(
                at: url,
                indexedExtensions: indexedExtensions,
                ignoredDirectories: ignoredDirectories
            )
            guard !files.isEmpty else {
                state = .failed("No source files found at \(url.lastPathComponent)")
                return
            }

            state = .indexing(progress: 0.05, message: "Found \(files.count) files, chunking...")

            let chunks = try await Self.makeChunks(
                from: files,
                projectRoot: url,
                maxChunkCharacters: maxChunkCharacters
            )
            let total = chunks.count

            state = .indexing(progress: 0.1, message: "Indexing \(total) chunks...")

            var processed = 0

            for batchStart in stride(from: 0, to: chunks.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, chunks.count)
                let batch = Array(chunks[batchStart..<batchEnd])

                let embeddings = try await embedBatch(batch.map(\.content))
                let vectors = zip(batch, embeddings).map { chunk, vector in
                    buildVector(chunk: chunk, vector: vector)
                }

                try await upsert(vectors)

                processed += batch.count

                let progress = 0.1 + (Double(processed) / Double(total)) * 0.9
                state = .indexing(progress: progress, message: "Indexed \(processed)/\(total) chunks...")
            }

            // sleeping to respect Mistral's rate limit
            try await Task.sleep(nanoseconds: 200_000_000)
            state = .ready(projectName: url.lastPathComponent, chunkCount: total)
        } catch {
            state = .failed(error.localizedDescription)
            print(error.localizedDescription)
        }
    }

    // MARK: - File Collection

    nonisolated private static func collectFiles(
        at root: URL,
        indexedExtensions: Set<String>,
        ignoredDirectories: Set<String>
    ) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            try Self.collectFilesSync(
                at: root,
                indexedExtensions: indexedExtensions,
                ignoredDirectories: ignoredDirectories
            )
        }.value
    }

    nonisolated private static func collectFilesSync(
        at root: URL,
        indexedExtensions: Set<String>,
        ignoredDirectories: Set<String>
    ) throws -> [URL] {
        var result: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            if Task.isCancelled {
                throw CancellationError()
            }

            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDir {
                let name = fileURL.lastPathComponent
                if ignoredDirectories.contains(name) ||
                    name.hasSuffix(".xcodeproj") ||
                    name.hasSuffix(".xcworkspace") {
                    enumerator.skipDescendants()
                }
                continue
            }

            if indexedExtensions.contains(fileURL.pathExtension.lowercased()) {
                result.append(fileURL)
            }
        }

        return result
    }

    // MARK: - Chunking

    private struct CodeChunk: Sendable {
        let id: String
        let filePath: String
        let content: String
        let language: String
    }

    nonisolated private static func makeChunks(
        from files: [URL],
        projectRoot: URL,
        maxChunkCharacters: Int
    ) async throws -> [CodeChunk] {
        try await Task.detached(priority: .userInitiated) {
            try Self.makeChunksSync(
                from: files,
                projectRoot: projectRoot,
                maxChunkCharacters: maxChunkCharacters
            )
        }.value
    }

    nonisolated private static func makeChunksSync(
        from files: [URL],
        projectRoot: URL,
        maxChunkCharacters: Int
    ) throws -> [CodeChunk] {
        try files.flatMap { fileURL -> [CodeChunk] in
            if Task.isCancelled {
                throw CancellationError()
            }

            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            let relativePath = fileURL.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
            let lang = Self.language(for: fileURL.pathExtension)
            return Self.split(
                source: source,
                relativePath: relativePath,
                language: lang,
                maxChunkCharacters: maxChunkCharacters
            )
        }
    }

    nonisolated private static func split(
        source: String,
        relativePath: String,
        language: String,
        maxChunkCharacters: Int
    ) -> [CodeChunk] {
        guard source.count > maxChunkCharacters else {
            return [CodeChunk(
                id: stableID(path: relativePath, index: 0),
                filePath: relativePath,
                content: descriptor(path: relativePath, language: language) + source,
                language: language
            )]
        }

        var chunks: [CodeChunk] = []
        var buffer: [String] = []
        var charCount = 0
        var chunkIndex = 0
        let lines = source.components(separatedBy: "\n")

        for line in lines {
            buffer.append(line)
            charCount += line.count + 1

            if charCount >= maxChunkCharacters {
                let content = descriptor(path: relativePath, language: language, part: chunkIndex + 1)
                + buffer.joined(separator: "\n")
                chunks.append(CodeChunk(
                    id: stableID(path: relativePath, index: chunkIndex),
                    filePath: relativePath,
                    content: content,
                    language: language
                ))
                // 20% overlap for context continuity
                let overlapStart = Int(Double(buffer.count) * 0.8)
                buffer = Array(buffer.suffix(from: overlapStart))
                charCount = buffer.joined(separator: "\n").count
                chunkIndex += 1
            }
        }

        if !buffer.isEmpty {
            let content = descriptor(path: relativePath, language: language, part: chunkIndex + 1)
            + buffer.joined(separator: "\n")
            chunks.append(CodeChunk(
                id: stableID(path: relativePath, index: chunkIndex),
                filePath: relativePath,
                content: content,
                language: language
            ))
        }

        return chunks
    }

    nonisolated private static func descriptor(path: String, language: String, part: Int? = nil) -> String {
        let partLabel = part.map { " (part \($0))" } ?? ""
        return "// File: \(path)\(partLabel)\n// Language: \(language)\n\n"
    }

    nonisolated static private func stableID(path: String, index: Int) -> String {
        let sanitized = path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        let suffix = "_c\(index)"
        let maxBase = 63 - suffix.count

        let trimmed = sanitized.count > maxBase
            ? String(sanitized.suffix(maxBase))
            : sanitized

        return trimmed + suffix
    }

    nonisolated private static func language(for ext: String) -> String {
        switch ext.lowercased() {
        case "swift":        return "Swift"
        case "m", "mm":      return "Objective-C"
        case "h":            return "C/ObjC Header"
        case "py":           return "Python"
        case "ts", "tsx":    return "TypeScript"
        case "js", "jsx":    return "JavaScript"
        case "rs":           return "Rust"
        case "go":           return "Go"
        case "kt":           return "Kotlin"
        case "java":         return "Java"
        default:             return ext.uppercased()
        }
    }

    private func nextNamespace(for projectURL: URL) -> String {
        let resolvedURL = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let projectName = slug(from: resolvedURL.lastPathComponent)
        let projectDigest = SHA256.hash(data: Data(resolvedURL.path.utf8))
        let projectHash = projectDigest.prefix(10).map { String(format: "%02x", $0) }.joined()
        let runToken = UUID().uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
        return "\(namespacePrefix)-\(projectName)-\(projectHash)-\(runToken)"
    }

    private func slug(from name: String) -> String {
        let lowercase = name.lowercased()
        let scalars = lowercase.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "0"..."9":
                return Character(scalar)
            default:
                return "-"
            }
        }

        let normalized = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if normalized.isEmpty {
            return "project"
        }

        return String(normalized.prefix(24))
    }

    // MARK: - Mistral Embeddings

    private func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        struct Request: Encodable {
            let model: String
            let input: [String]
            let output_dimension: Int
        }

        struct Response: Decodable {
            struct EmbeddingObject: Decodable {
                let embedding: [Float]
            }
            let data: [EmbeddingObject]
        }

        let body = Request(
            model: embeddingModel,
            input: texts,
            output_dimension: embeddingDimension
        )

        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/embeddings")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(mistralAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown"
            throw ServiceError.embeddingFailed(raw)
        }

        return try JSONDecoder().decode(Response.self, from: data).data.map(\.embedding)
    }

    // MARK: - TurboPuffer Upsert

    private struct VectorRow: Encodable {
        let id: String
        let vector: [Float]
        let file_path: String
        let language: String
        let preview: String
    }

    private func buildVector(chunk: CodeChunk, vector: [Float]) -> VectorRow {
        VectorRow(
            id: chunk.id,
            vector: vector,
            file_path: chunk.filePath,
            language: chunk.language,
            preview: String(chunk.content.prefix(200))
        )
    }

    private func upsert(_ vectors: [VectorRow]) async throws {
        struct Payload: Encodable {
            let upsert_rows: [VectorRow]
            let distance_metric: String
        }

        guard let namespace = activeNamespace else {
            throw ServiceError.upsertFailed("No active project namespace is selected")
        }

        let urlString = "\(turbopufferBaseURL)/v2/namespaces/\(namespace)"
        var request = URLRequest(url: URL(string: urlString)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(turbopufferAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            Payload(upsert_rows: vectors, distance_metric: "cosine_distance")
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let raw = String(data: data, encoding: .utf8) ?? "empty"
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        print("TurboPuffer status: \(statusCode)")
        print("TurboPuffer response: \(raw)")

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ServiceError.upsertFailed(raw)
        }
    }

    // MARK: - TurboPuffer Query

    struct QueryResult {
        let filePath: String
        let language: String
        let preview: String
        let content: String
    }

    func query(_ text: String, topK: Int = 5) async throws -> [QueryResult] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return [] }

        guard state.isReady else {
            throw ServiceError.queryFailed("Codebase is not indexed yet")
        }

        guard mistralAPIKey.isEmpty == false, turbopufferAPIKey.isEmpty == false else {
            throw ServiceError.queryFailed("Missing API keys. Add Mistral and TurboPuffer in Settings.")
        }

        guard activeNamespace != nil else {
            throw ServiceError.queryFailed("No indexed project namespace is available yet")
        }

        guard let vector = try await embedBatch([trimmedText]).first else {
            throw ServiceError.queryFailed("Question embedding failed")
        }

        return try await search(vector: vector, topK: topK)
    }

    func search(vector: [Float], topK: Int) async throws -> [QueryResult] {
        struct SearchPayload: Encodable {
            let rank_by: [JSONValue]
            let top_k: Int
            let include_attributes: [String]
        }

        struct SearchResponse: Decodable {
            struct Row: Decodable {
                let id: String
                let file_path: String
                let language: String
                let preview: String

                enum CodingKeys: String, CodingKey {
                    case id, file_path, language, preview
                }
            }
            let rows: [Row]
        }

        let payload = SearchPayload(
            rank_by: [.string("vector"), .string("ANN"), .floatArray(vector)],
            top_k: topK,
            include_attributes: ["file_path", "language", "preview"]
        )

        guard let namespace = activeNamespace else {
            throw ServiceError.queryFailed("No active project namespace is selected")
        }

        let urlString = "\(turbopufferBaseURL)/v2/namespaces/\(namespace)/query"

        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(turbopufferAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        let raw = String(data: data, encoding: .utf8) ?? "empty"
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        print("TurboPuffer status: \(statusCode)")
        print("TurboPuffer response: \(raw)")

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown"
            throw ServiceError.queryFailed(raw)
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.rows.map {
            QueryResult(
                filePath: $0.file_path,
                language: $0.language,
                preview: $0.preview,
                content: $0.preview
            )
        }
    }

    // MARK: - Errors

    enum ServiceError: Error, LocalizedError {
        case embeddingFailed(String)
        case upsertFailed(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .embeddingFailed(let msg): return "Embedding failed: \(msg)"
            case .upsertFailed(let msg):    return "TurboPuffer upsert failed: \(msg)"
            case .queryFailed(let msg):     return "TurboPuffer query failed: \(msg)"
            }
        }
    }

    enum JSONValue: Encodable {
        case string(String)
        case floatArray([Float])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .floatArray(let a): try container.encode(a)
            }
        }
    }
}
