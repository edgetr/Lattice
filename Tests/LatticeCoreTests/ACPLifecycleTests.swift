import Foundation
import Testing
@testable import LatticeCore

@Suite("Typed ACP lifecycle")
struct ACPLifecycleTests {
    @Test func reconnectBackoffIsBoundedAndDeterministic() {
        let policy = ACPReconnectPolicy(
            maximumAttempts: 3,
            initialDelayNanoseconds: 10,
            maximumDelayNanoseconds: 25
        )

        #expect(policy.state(forAttempt: 1) == .init(attempt: 1, maximumAttempts: 3, delayNanoseconds: 10, disposition: .scheduled))
        #expect(policy.state(forAttempt: 2) == .init(attempt: 2, maximumAttempts: 3, delayNanoseconds: 20, disposition: .scheduled))
        #expect(policy.state(forAttempt: 3) == .init(attempt: 3, maximumAttempts: 3, delayNanoseconds: 25, disposition: .scheduled))
        #expect(policy.state(forAttempt: 4).disposition == .exhausted)
        #expect(policy.state(forAttempt: 1, supported: false).disposition == .unsupported)
    }

    @Test func permissionRequestAndSelectedDecisionStayTyped() async throws {
        let fixture = try Fixture(script: """
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session","models":{"availableModels":[{"modelId":"test-model","name":"Test Model"}],"currentModelId":"test-model"}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"toolCall":{"title":"Run command","kind":"execute","rawInput":{"command":"echo test"}},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{}}'
        while IFS= read -r line; do :; done
        """)
        defer { fixture.remove() }
        let harness = fixture.harness()
        let sessionID = UUID()
        var iterator = harness.stream(
            prompt: "test",
            sessionID: sessionID,
            threadID: nil,
            workspace: fixture.root,
            requestedModel: "test-model"
        ).makeAsyncIterator()

        var request: ApprovalRequest?
        while let event = await iterator.next() {
            if case .permissionRequested(let value) = event {
                request = value
                break
            }
        }
        let permission = try #require(request)
        #expect(permission.options.map(\.kind) == ["allow_once", "reject_once"])
        #expect(harness.respondToPermission(sessionID: sessionID, requestID: permission.id, optionID: "allow"))

        var decision: ProviderPermissionDecision?
        while let event = await iterator.next() {
            if case .permissionDecided(let value) = event { decision = value }
        }
        #expect(decision == .init(requestID: permission.id, outcome: .selected(optionID: "allow", kind: "allow_once")))
    }

    @Test func cancellationCarriesExplicitReason() async throws {
        let fixture = try Fixture(script: """
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session","models":{"availableModels":[{"modelId":"test-model","name":"Test Model"}],"currentModelId":"test-model"}}}'
        while IFS= read -r line; do :; done
        """)
        defer { fixture.remove() }
        let harness = fixture.harness()
        let sessionID = UUID()
        var iterator = harness.stream(prompt: "test", sessionID: sessionID, threadID: nil, workspace: fixture.root, requestedModel: "test-model").makeAsyncIterator()

        while let event = await iterator.next() {
            if case .providerSessionLifecycle(let lifecycle) = event, lifecycle.health == .healthy {
                harness.cancel(sessionID: sessionID)
                break
            }
        }

        var events: [AgentEvent] = []
        while let event = await iterator.next() { events.append(event) }
        #expect(events.contains(.runCancelled(.init(reason: .userRequested))))
        #expect(events.contains(.cancelled))
    }

    @Test func rejectedSessionReconnectsWithTypedRecoveryState() async throws {
        let fixture = try Fixture(script: """
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"message":"session not found"}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"fresh","models":{"availableModels":[{"modelId":"test-model","name":"Test Model"}],"currentModelId":"test-model"}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":4,"result":{}}'
        while IFS= read -r line; do :; done
        """)
        defer { fixture.remove() }
        let harness = fixture.harness(reconnectPolicy: .init(maximumAttempts: 1, initialDelayNanoseconds: 0, maximumDelayNanoseconds: 0))
        let events = await collect(harness.stream(
            prompt: "current",
            sessionID: UUID(),
            threadID: "hermes:stale",
            workspace: fixture.root,
            requestedModel: "test-model",
            recoveryPrompt: "Visible transcript handoff",
            recoveryUsesVisibleTranscriptHandoff: true
        ))

        #expect(events.contains { event in
            guard case .providerSessionLifecycle(let lifecycle) = event,
                  case .reconnecting(let reconnect) = lifecycle.health else { return false }
            return reconnect.attempt == 1 && reconnect.disposition == .scheduled
        })
        #expect(events.contains(.providerSessionLifecycle(.init(provider: "Hermes", providerSessionID: "fresh", health: .recovered))))
        #expect(events.contains(.completed))
    }

    @Test func disconnectMarksSessionUnhealthyWithoutTextInference() async throws {
        let fixture = try Fixture(script: """
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session","models":{"availableModels":[{"modelId":"test-model","name":"Test Model"}],"currentModelId":"test-model"}}}'
        exit 0
        """)
        defer { fixture.remove() }
        let events = await collect(fixture.harness().stream(prompt: "test", sessionID: UUID(), threadID: nil, workspace: fixture.root, requestedModel: "test-model"))

        #expect(events.contains { event in
            guard case .providerSessionLifecycle(let lifecycle) = event,
                  case .unhealthy(.disconnected) = lifecycle.health else { return false }
            return true
        })
        #expect(events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func unsupportedProviderModelIsTypedAndFailsClosed() async throws {
        let fixture = try Fixture(script: """
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session","models":{"availableModels":[{"modelId":"other-model","name":"Other"}],"currentModelId":"other-model"}}}'
        while IFS= read -r line; do :; done
        """)
        defer { fixture.remove() }
        let events = await collect(fixture.harness().stream(prompt: "test", sessionID: UUID(), threadID: nil, workspace: fixture.root, requestedModel: "missing-model"))

        #expect(events.contains(.providerSessionLifecycle(.init(
            provider: "Hermes",
            providerSessionID: "session",
            health: .unhealthy(.unsupportedProvider("missing-model"))
        ))))
        #expect(!events.contains(.completed))
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}

private struct Fixture {
    let root: URL
    let executable: URL
    let sandbox: URL

    init(script: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-acp-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("provider")
        sandbox = root.appendingPathComponent("sandbox")
        try Self.writeExecutable("#!/bin/sh\nset -eu\n\(script)\n", to: executable)
        try Self.writeExecutable("#!/bin/sh\nif [ \"$1\" = \"-p\" ]; then shift 2; fi\nexec \"$@\"\n", to: sandbox)
    }

    func harness(reconnectPolicy: ACPReconnectPolicy = .init()) -> HermesACPHarness {
        HermesACPHarness(
            executableURL: executable,
            sandboxExecutableURL: sandbox,
            reconnectPolicy: reconnectPolicy,
            hermesProfile: LatticeHermesProfile(hermesHome: root.appendingPathComponent("hermes-home", isDirectory: true))
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
