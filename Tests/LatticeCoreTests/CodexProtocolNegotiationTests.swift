import Foundation
import Testing
@testable import LatticeCore

@Suite("Codex app-server protocol negotiation")
struct CodexProtocolNegotiationTests {
    @Test func succeedsWithVersionedHandshakeAndUnknownFields() async throws {
        let fixture = try Fixture(body: Self.successfulServer)
        defer { fixture.remove() }

        let events = await collect(CodexExecHarness(executableURL: fixture.executable).stream(
            prompt: "hello",
            sessionID: UUID(),
            threadID: nil,
            workspace: fixture.root,
            model: "test-model"
        ))

        #expect(events.contains(.harnessSessionStarted("thread-1")))
        #expect(events.contains(.completed))
        #expect(!events.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func optionalProbeDowngradesWithoutInventingCapabilities() async throws {
        let fixture = try Fixture(body: """
        IFS= read -r initialize
        printf '%s\\n' '{"id":0,"result":{"futureHandshakeField":{"nested":true}}}'
        IFS= read -r initialized
        IFS= read -r models
        IFS= read -r tools
        IFS= read -r usage
        printf '%s\\n' '{"id":1,"result":{"data":[{"model":"gpt-test","displayName":"Test"}]}}'
        printf '%s\\n' '{"id":2,"error":{"code":-32601,"message":"unknown method"}}'
        printf '%s\\n' '{"id":3,"error":{"code":-32601,"message":"unknown method"}}'
        """)
        defer { fixture.remove() }

        let snapshot = await CodexExecHarness(executableURL: fixture.executable).providerSnapshot()

        #expect(snapshot.catalogStatus == .loaded)
        #expect(snapshot.models.map(\.id) == ["gpt-test"])
        #expect(snapshot.capabilities.modelCatalog == .supported)
        #expect(snapshot.capabilities.providerTools == .unsupported)
        #expect(snapshot.capabilities.usage == .unsupported)
        #expect(snapshot.capabilities.threadResume == .unknown)
    }

    @Test func malformedHandshakeFailsThenFreshProcessRecovers() async throws {
        let fixture = try Fixture(body: """
        count_file="$(dirname "$0")/count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        IFS= read -r initialize
        if [ "$count" -eq 1 ]; then
          printf '%s\\n' '{"id":1,"result":"not-an-object"}'
          exit 0
        fi
        printf '%s\\n' '{"id":1,"result":{"userAgent":"codex-test","protocolVersion":2}}'
        \(Self.successfulServerAfterInitialize)
        """)
        defer { fixture.remove() }
        let harness = CodexExecHarness(executableURL: fixture.executable)

        let first = await collect(harness.stream(
            prompt: "first", sessionID: UUID(), threadID: nil,
            workspace: fixture.root, model: "test-model"
        ))
        let second = await collect(harness.stream(
            prompt: "second", sessionID: UUID(), threadID: nil,
            workspace: fixture.root, model: "test-model"
        ))

        #expect(failure(in: first)?.contains("malformed protocol handshake") == true)
        #expect(!first.contains(.completed))
        #expect(second.contains(.completed))
    }

    @Test func handshakeTimeoutIsActionableAndNeverCompletes() async throws {
        let fixture = try Fixture(body: """
        IFS= read -r initialize
        while :; do sleep 1; done
        """)
        defer { fixture.remove() }

        let events = await collect(CodexExecHarness(
            executableURL: fixture.executable,
            protocolTimeout: 0.03
        ).stream(
            prompt: "hello", sessionID: UUID(), threadID: nil,
            workspace: fixture.root, model: "test-model"
        ))

        #expect(failure(in: events) == "Codex app-server protocol negotiation timed out. Retry or update Codex.")
        #expect(!events.contains(.completed))
    }

    @Test func unsupportedResumeFailsWithoutStartingReplacementThread() async throws {
        let fixture = try Fixture(body: """
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{"userAgent":"codex-test","protocolVersion":"2"}}'
        IFS= read -r initialized
        IFS= read -r resume
        printf '%s\\n' '{"id":2,"error":{"code":-32601,"message":"method not found"}}'
        """)
        defer { fixture.remove() }

        let events = await collect(CodexExecHarness(executableURL: fixture.executable).stream(
            prompt: "continue", sessionID: UUID(), threadID: "existing-thread",
            workspace: fixture.root, model: "test-model"
        ))

        #expect(failure(in: events)?.contains("cannot resume existing threads") == true)
        #expect(!events.contains { if case .harnessSessionStarted = $0 { return true }; return false })
        #expect(!events.contains(.completed))
    }

    @Test func unsupportedApprovalSchemaFailsClosed() async throws {
        let fixture = try Fixture(body: """
        IFS= read -r initialize
        printf '%s\\n' '{"id":1,"result":{"userAgent":"codex-test"}}'
        IFS= read -r initialized
        IFS= read -r thread
        printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"},"approvalPolicy":"on-request","sandbox":"read-only"}}'
        IFS= read -r turn
        printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
        printf '%s\\n' '{"id":44,"method":"item/permissions/requestApproval","params":{"futurePermission":true}}'
        while IFS= read -r response; do :; done
        """)
        defer { fixture.remove() }

        let events = await collect(CodexExecHarness(executableURL: fixture.executable).stream(
            prompt: "tool", sessionID: UUID(), threadID: nil,
            workspace: fixture.root, model: "test-model"
        ))

        #expect(failure(in: events)?.contains("cannot safely handle") == true)
        #expect(!events.contains(.completed))
    }

    private static let successfulServer = """
    IFS= read -r initialize
    printf '%s\\n' '{"id":1,"result":{"userAgent":"codex-test/1.2","protocolVersion":2,"futureField":true}}'
    \(successfulServerAfterInitialize)
    """

    private static let successfulServerAfterInitialize = """
    IFS= read -r initialized
    IFS= read -r thread
    printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1"},"approvalPolicy":"on-request","sandbox":{"type":"readOnly"},"futureField":true}}'
    IFS= read -r turn
    printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1"},"futureField":true}}'
    printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"},"futureField":true}}'
    """

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func failure(in events: [AgentEvent]) -> String? {
        events.compactMap { event in
            guard case .failed(let message) = event else { return nil }
            return message
        }.first
    }
}

private struct Fixture {
    let root: URL
    let executable: URL

    init(body: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-codex-negotiation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
