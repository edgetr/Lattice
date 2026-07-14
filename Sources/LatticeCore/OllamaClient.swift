import Foundation

public struct OllamaModel: Identifiable, Hashable, Codable, Sendable {
    public let name: String
    public let size: Int64
    public let parameterSize: String?
    public let quantization: String?
    public let capabilities: Set<String>
    public var id: String { name }
    public init(name: String, size: Int64, parameterSize: String? = nil, quantization: String? = nil, capabilities: Set<String> = []) {
        self.name = name; self.size = size; self.parameterSize = parameterSize; self.quantization = quantization; self.capabilities = capabilities
    }
}

public enum OllamaModelDeletionResult: Equatable, Sendable {
    case deleted
    case failed(String)
}

// MARK: - Transport

/// Minimal HTTP surface for Ollama so production uses `URLSession` and tests inject deterministic behavior.
public protocol OllamaTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    /// NDJSON body as an async line sequence plus the HTTP response (used by `/api/chat` streaming).
    func streamLines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse)
}

/// Default transport wrapping `URLSession`.
public struct URLSessionOllamaTransport: OllamaTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func streamLines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, response)
    }
}

// MARK: - Client

public final class OllamaClient: @unchecked Sendable {
    /// Maximum number of concurrent `/api/show` detail requests during model discovery.
    public static let modelDetailConcurrencyLimit = 4

    public static let availabilityTimeout: TimeInterval = 3
    public static let tagsTimeout: TimeInterval = 10
    public static let detailTimeout: TimeInterval = 10
    public static let unloadTimeout: TimeInterval = 10
    public static let deleteTimeout: TimeInterval = 15
    /// Chat streams can run for a long time; this bounds connection establishment / stall only.
    public static let chatTimeout: TimeInterval = 600

    private let baseURL: URL
    private let transport: any OllamaTransport
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var activeModel: String?

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        transport: any OllamaTransport = URLSessionOllamaTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Convenience initializer that injects a `URLSession` via the default transport.
    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession) {
        self.baseURL = baseURL
        self.transport = URLSessionOllamaTransport(session: session)
    }

    public func isAvailable() async -> Bool {
        guard let url = endpoint("/api/version") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.availabilityTimeout
        do {
            let (_, response) = try await transport.data(for: request)
            return try isSuccessStatus(response)
        } catch {
            return false
        }
    }

    /// Legacy list-only view. Use `modelsResult()` when catalog authority matters.
    public func models() async -> [OllamaModel] {
        await modelsResult().models
    }

    /// Discovers completion-capable models with bounded concurrent `/api/show` detail fetches.
    ///
    /// **Detail failure / omission policy:** When a model’s `/api/show` request fails (timeout,
    /// non-success HTTP status, transport error) or returns malformed JSON, that model is
    /// **omitted** from the result. We do not invent capabilities or surface a model as
    /// chat-capable without verified `"completion"` support. Successful sibling detail
    /// requests remain available. Final order matches `/api/tags` order among models that
    /// both appear in tags and report the `completion` capability.
    public func modelsResult() async -> ProviderCatalogResult<OllamaModel> {
        guard let url = endpoint("/api/tags") else {
            return ProviderCatalogResult(models: [], status: .failed)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.tagsTimeout
        let data: Data
        do {
            let (body, response) = try await transport.data(for: request)
            guard try isSuccessStatus(response) else {
                return ProviderCatalogResult(models: [], status: .failed)
            }
            data = body
        } catch {
            return ProviderCatalogResult(models: [], status: .failed)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["models"] as? [[String: Any]] else {
            return ProviderCatalogResult(models: [], status: .failed)
        }

        struct TagEntry: Sendable {
            let index: Int
            let name: String
            let size: Int64
            let parameterSize: String?
            let quantization: String?
        }

        var entries: [TagEntry] = []
        entries.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard let name = item["name"] as? String else { continue }
            let details = item["details"] as? [String: Any]
            entries.append(TagEntry(
                index: index,
                name: name,
                size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                parameterSize: details?["parameter_size"] as? String,
                quantization: details?["quantization_level"] as? String
            ))
        }

        let detailBatch = await fetchCapabilitiesBounded(entries.map { ($0.index, $0.name) })

        var models: [OllamaModel] = []
        models.reserveCapacity(entries.count)
        for entry in entries {
            guard let capabilities = detailBatch.capabilitiesByIndex[entry.index],
                  capabilities.contains("completion") else { continue }
            models.append(OllamaModel(
                name: entry.name,
                size: entry.size,
                parameterSize: entry.parameterSize,
                quantization: entry.quantization,
                capabilities: capabilities
            ))
        }
        let status: ProviderCatalogStatus = detailBatch.hadFailure
            ? .failed
            : .resolved(modelCount: models.count, succeeded: true)
        return ProviderCatalogResult(models: models, status: status)
    }

    /// Fetches `/api/show` for each tagged model with at most `modelDetailConcurrencyLimit` in flight.
    /// Verified siblings remain available, but any failed detail marks the batch non-authoritative.
    private func fetchCapabilitiesBounded(_ named: [(index: Int, name: String)]) async -> CapabilityFetchBatch {
        guard !named.isEmpty else { return CapabilityFetchBatch(capabilitiesByIndex: [:], hadFailure: false) }
        let limit = Self.modelDetailConcurrencyLimit
        return await withTaskGroup(of: (Int, Set<String>?).self, returning: CapabilityFetchBatch.self) { group in
            var results: [Int: Set<String>] = [:]
            var hadFailure = false
            var nextIndex = 0
            var inFlight = 0

            func startNextIfPossible() {
                while inFlight < limit, nextIndex < named.count {
                    let item = named[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        let caps = await self.capabilities(for: item.name)
                        return (item.index, caps)
                    }
                }
            }

            startNextIfPossible()
            for await (index, caps) in group {
                inFlight -= 1
                if let caps { results[index] = caps }
                else { hadFailure = true }
                startNextIfPossible()
            }
            return CapabilityFetchBatch(capabilitiesByIndex: results, hadFailure: hadFailure)
        }
    }

    private struct CapabilityFetchBatch: Sendable {
        let capabilitiesByIndex: [Int: Set<String>]
        let hadFailure: Bool
    }

    /// Returns verified capabilities, or `nil` when detail cannot be trusted (omit model).
    private func capabilities(for model: String) async -> Set<String>? {
        guard let url = endpoint("/api/show") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.detailTimeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        do {
            let (data, response) = try await transport.data(for: request)
            guard try isSuccessStatus(response) else { return nil }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            // Malformed: missing or non-array capabilities → omit (cannot claim completion).
            guard let raw = root["capabilities"] as? [String] else { return nil }
            return Set(raw)
        } catch {
            return nil
        }
    }

    public func stream(messages: [ChatMessage], model: String, sessionID: UUID, keepAliveSeconds: Int = 300) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task { [self] in
                defer {
                    finish(sessionID)
                    continuation.finish()
                }
                do {
                    try Task.checkCancellation()
                    await unloadIfNeeded(beforeLoading: model)
                    try Task.checkCancellation()
                    guard let url = endpoint("/api/chat") else {
                        continuation.yield(.failed("The local model is unavailable. Start Ollama and try again."))
                        return
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = Self.chatTimeout
                    let wireMessages = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
                    request.httpBody = try? JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "messages": wireMessages,
                        "stream": true,
                        "keep_alive": "\(max(0, keepAliveSeconds))s"
                    ])
                    let (lines, response) = try await transport.streamLines(for: request)
                    guard try isSuccessStatus(response) else {
                        throw URLError(.badServerResponse)
                    }
                    var receivedDone = false
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let message = json["message"] as? [String: Any],
                           let content = message["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(.assistantDelta(content))
                        }
                        if json["done"] as? Bool == true {
                            receivedDone = true
                            continuation.yield(.completed)
                        }
                    }
                    try Task.checkCancellation()
                    if !receivedDone {
                        continuation.yield(.failed("The local model stream ended before Ollama reported completion."))
                    }
                } catch {
                    if Self.isCancellation(error) {
                        continuation.yield(.cancelled)
                    } else {
                        continuation.yield(.failed("The local model is unavailable. Start Ollama and try again."))
                    }
                }
            }
            register(task, sessionID: sessionID)
            continuation.onTermination = { [weak self] _ in self?.cancel(sessionID: sessionID) }
        }
    }

    public func cancel(sessionID: UUID) {
        let task = lock.withLock { tasks.removeValue(forKey: sessionID) }
        task?.cancel()
    }

    public func unload(model: String) async {
        guard let url = endpoint("/api/generate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.unloadTimeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        // Best-effort: apply timeout and status check, then clear local active tracking either way
        // so a failed unload does not pin `activeModel` forever.
        _ = try? await validatedData(for: request)
        lock.withLock { if activeModel == model { activeModel = nil } }
    }

    public func unloadActive() async {
        let model = lock.withLock { activeModel }
        if let model { await unload(model: model) }
    }

    /// Deletes an installed model through Ollama's bounded local API. Response
    /// bodies are intentionally not surfaced because they are not trusted UI copy.
    public func deleteModel(named model: String) async -> OllamaModelDeletionResult {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = endpoint("/api/delete") else {
            return .failed("Choose an installed local model to delete.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.deleteTimeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": trimmed])
        do {
            let (_, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Ollama returned an invalid response while deleting the model.")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed("Ollama could not delete the model (HTTP \(http.statusCode)).")
            }
            lock.withLock { if activeModel == trimmed { activeModel = nil } }
            return .deleted
        } catch {
            return .failed("Ollama could not delete the model. Make sure it is running, then try again.")
        }
    }

    // MARK: - Internals

    private func unloadIfNeeded(beforeLoading model: String) async {
        let previous = lock.withLock { let value = activeModel; activeModel = model; return value }
        if let previous, previous != model { await unload(model: previous) }
    }

    private func register(_ task: Task<Void, Never>, sessionID: UUID) {
        lock.withLock { tasks[sessionID] = task }
    }

    private func finish(_ id: UUID) {
        lock.withLock { tasks[id] = nil }
    }

    private func endpoint(_ path: String) -> URL? {
        URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    private func validatedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        guard try isSuccessStatus(response) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Returns `true` for HTTP 2xx; throws `URLError.badServerResponse` when the response is not HTTP.
    private func isSuccessStatus(_ response: URLResponse) throws -> Bool {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (200..<300).contains(http.statusCode)
    }

    /// Classifies cooperative and URL-layer cancellation as stream `.cancelled`, not local-model failure.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if Task.isCancelled { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        return false
    }
}
