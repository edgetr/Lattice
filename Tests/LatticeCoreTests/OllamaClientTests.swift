import Foundation
import Testing
@testable import LatticeCore

@Suite("Ollama client streaming")
struct OllamaClientTests {
    @Test func completeModelDetailsProduceAuthoritativeCatalog() async {
        let transport = ModelCatalogFixtureTransport(
            tags: ["chat", "embed"],
            capabilities: ["chat": ["completion"], "embed": ["embedding"]]
        )

        let result = await OllamaClient(transport: transport).modelsResult()

        #expect(result.status == .loaded)
        #expect(result.models.map(\.name) == ["chat"])
    }

    @Test func anyModelDetailFailureMakesCatalogNonAuthoritative() async {
        let transport = ModelCatalogFixtureTransport(
            tags: ["verified", "unavailable"],
            capabilities: ["verified": ["completion"]],
            failingModels: ["unavailable"]
        )

        let result = await OllamaClient(transport: transport).modelsResult()

        #expect(result.status == .failed)
        #expect(result.models.map(\.name) == ["verified"])
    }

    @Test func emptyTagsResponseIsAuthoritativeEmptyCatalog() async {
        let result = await OllamaClient(
            transport: ModelCatalogFixtureTransport(tags: [], capabilities: [:])
        ).modelsResult()

        #expect(result.status == .empty)
        #expect(result.models.isEmpty)
    }

    @Test func partialStreamEOFFailsInsteadOfStayingStreaming() async {
        let transport = FixtureTransport(lines: [
            #"{"message":{"content":"partial"}}"#
        ])
        let events = await collectEvents(from: transport)

        #expect(events == [
            .assistantDelta("partial"),
            .failed("The local model stream ended before Ollama reported completion.")
        ])
    }

    @Test func doneFrameCompletesNormally() async {
        let transport = FixtureTransport(lines: [
            #"{"message":{"content":"complete"}}"#,
            #"{"done":true}"#
        ])
        let events = await collectEvents(from: transport)

        #expect(events == [.assistantDelta("complete"), .completed])
    }

    @Test func cancellationEmitsCancelledWithoutFailure() async {
        let transport = CancellationFixtureTransport()
        let sessionID = UUID()
        let client = OllamaClient(transport: transport)
        let eventsTask = Task {
            var events: [AgentEvent] = []
            for await event in client.stream(
                messages: [ChatMessage(role: .user, text: "hello")],
                model: "fixture",
                sessionID: sessionID
            ) {
                events.append(event)
            }
            return events
        }

        await transport.waitUntilStreaming()
        client.cancel(sessionID: sessionID)
        let events = await eventsTask.value

        #expect(events == [.cancelled])
    }

    private func collectEvents(from transport: any OllamaTransport) async -> [AgentEvent] {
        let client = OllamaClient(transport: transport)
        var events: [AgentEvent] = []
        for await event in client.stream(
            messages: [ChatMessage(role: .user, text: "hello")],
            model: "fixture",
            sessionID: UUID()
        ) {
            events.append(event)
        }
        return events
    }
}

private actor ModelCatalogFixtureTransport: OllamaTransport {
    let tags: [String]
    let capabilities: [String: Set<String>]
    let failingModels: Set<String>

    init(tags: [String], capabilities: [String: Set<String>], failingModels: Set<String> = []) {
        self.tags = tags
        self.capabilities = capabilities
        self.failingModels = failingModels
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        switch request.url?.path {
        case "/api/tags":
            let models = tags.map { ["name": $0, "size": 1] as [String: Any] }
            return (try JSONSerialization.data(withJSONObject: ["models": models]), Self.response)
        case "/api/show":
            guard let body = request.httpBody,
                  let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let model = object["model"] as? String else {
                throw FixtureError.malformedRequest
            }
            if failingModels.contains(model) { throw FixtureError.detailUnavailable }
            guard let values = capabilities[model] else { throw FixtureError.detailUnavailable }
            return (try JSONSerialization.data(withJSONObject: ["capabilities": Array(values).sorted()]), Self.response)
        default:
            throw FixtureError.malformedRequest
        }
    }

    func streamLines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        fatalError("Model catalog fixture does not implement streaming requests")
    }

    private static var response: HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://fixture")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private enum FixtureError: Error {
        case malformedRequest
        case detailUnavailable
    }
}

private struct FixtureTransport: OllamaTransport {
    let lines: [String]

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        fatalError("Fixture does not implement non-streaming requests")
    }

    func streamLines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            for line in self.lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
        return (lines, Self.response)
    }

    fileprivate static var response: HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://fixture")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

private final class CancellationFixtureTransport: OllamaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var streaming = false

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        fatalError("Fixture does not implement non-streaming requests")
    }

    func streamLines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            lock.withLock { streaming = true }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.streaming = false }
            }
        }
        return (lines, FixtureTransport.response)
    }

    func waitUntilStreaming() async {
        while !lock.withLock({ streaming }) {
            await Task.yield()
        }
    }
}
