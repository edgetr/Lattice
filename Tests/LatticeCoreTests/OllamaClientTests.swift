import Foundation
import Testing
@testable import LatticeCore

@Suite("Ollama client streaming")
struct OllamaClientTests {
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
