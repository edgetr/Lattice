import Foundation
import Testing
@testable import LatticeCore

@Suite("Permission deadlines")
struct PermissionTimeoutTests {
    @Test func multipleWaitersResolveTogetherWithoutContinuationOverwrite() async {
        let waiter = PermissionWaiter<String>()
        async let first = waiter.wait(timeoutNanoseconds: 1_000_000_000)
        async let second = waiter.wait(timeoutNanoseconds: 1_000_000_000)
        await Task.yield()
        #expect(waiter.resolve("allow"))

        guard case .resolved(let firstValue) = await first,
              case .resolved(let secondValue) = await second else {
            Issue.record("Every registered waiter must receive the one-shot result")
            return
        }
        #expect(firstValue == "allow")
        #expect(secondValue == "allow")
        #expect(!waiter.resolve("deny"))
    }

    @Test func multipleWaitersTimeoutTogether() async {
        let waiter = PermissionWaiter<Int>()
        async let first = waiter.wait(timeoutNanoseconds: 1_000_000)
        async let second = waiter.wait(timeoutNanoseconds: 1_000_000)
        guard case .timedOut = await first,
              case .timedOut = await second else {
            Issue.record("Every registered waiter must receive the timeout")
            return
        }
        #expect(!waiter.resolve(1))
    }

    @Test func codexPermissionTimeoutFailsAndCleansUp() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeExecutable(
            """
            printf '%s\\n' '{"id":1,"result":{"userAgent":"test-codex","futureField":true}}'
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread"},"approvalPolicy":"on-request","sandbox":"read-only"}}'
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn"}}}'
            printf '%s\\n' '{"id":"permission","method":"item/commandExecution/requestApproval","params":{"command":"echo test","availableDecisions":["accept","decline"]}}'
            while IFS= read -r line; do :; done
            """,
            in: root
        )
        let harness = CodexExecHarness(executableURL: executable, permissionTimeout: 0.03)
        let sessionID = UUID()
        let events = await collect(harness.stream(
            prompt: "test",
            sessionID: sessionID,
            threadID: nil,
            workspace: root,
            model: "test-model"
        ))

        let requestID = try permissionRequestID(in: events)
        expectTimeout(in: events)
        #expect(harness.respondToPermission(sessionID: sessionID, requestID: requestID, optionID: "accept") == false)
    }

    @Test func hermesPermissionTimeoutFailsAndCleansUp() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeExecutable(
            """
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session","models":{"availableModels":[{"modelId":"test-model","name":"Test Model"}],"currentModelId":"test-model"}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"toolCall":{"title":"Run command","kind":"execute","rawInput":{"command":"echo test"}},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}'
            while IFS= read -r line; do :; done
            """,
            in: root
        )
        let sandboxExecutable = try makeExecutable(
            """
            if [ \"$1\" = \"-p\" ]; then shift 2; fi
            exec \"$@\"
            """,
            in: root
        )
        let harness = HermesACPHarness(
            executableURL: executable,
            sandboxExecutableURL: sandboxExecutable,
            permissionTimeout: 0.03
        )
        let sessionID = UUID()
        let events = await collect(harness.stream(
            prompt: "test",
            sessionID: sessionID,
            threadID: nil,
            workspace: root,
            requestedModel: "test-model"
        ))

        let requestID = try permissionRequestID(in: events)
        expectTimeout(in: events)
        #expect(harness.respondToPermission(sessionID: sessionID, requestID: requestID, optionID: "allow") == false)
    }

    @Test func piPermissionTimeoutFailsAndCleansUp() async throws {
        let root = try makeTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeExecutable(
            """
            printf '%s\\n' '{"type":"extension_ui_request","id":"permission","method":"confirm","message":"{\\"toolName\\":\\"bash\\",\\"input\\":{\\"command\\":\\"echo test\\"}}"}'
            while IFS= read -r line; do :; done
            """,
            in: root
        )
        let sandboxExecutable = try makeExecutable(
            """
            if [ \"$1\" = \"-p\" ]; then shift 2; fi
            exec \"$@\"
            """,
            in: root
        )
        let harness = PiRPCHarness(
            executableURL: executable,
            permissionExtensionURL: root.appendingPathComponent("permission.js"),
            sandboxExecutableURL: sandboxExecutable,
            permissionTimeout: 0.03,
            applicationSupportDirectory: root.appendingPathComponent("app-support")
        )
        let sessionID = UUID()
        let events = await collect(harness.stream(
            prompt: "test",
            sessionID: sessionID,
            threadID: nil,
            workspace: root,
            provider: "test-provider",
            model: "test-model",
            reasoningEffort: nil,
            allowFileModification: true
        ))

        let requestID = try permissionRequestID(in: events)
        expectTimeout(in: events)
        #expect(harness.respondToPermission(sessionID: sessionID, requestID: requestID, optionID: "allow_once") == false)
    }

    private func makeTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-permission-timeout-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(_ body: String, in root: URL) throws -> URL {
        let executable = root.appendingPathComponent("fake-provider-" + UUID().uuidString)
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func permissionRequestID(in events: [AgentEvent]) throws -> UUID {
        guard let request = events.compactMap({ event -> ApprovalRequest? in
            guard case .permissionRequested(let request) = event else { return nil }
            return request
        }).first else {
            throw TestError.missingPermissionRequest(events)
        }
        return request.id
    }

    private func expectTimeout(in events: [AgentEvent]) {
        #expect(events.contains { event in
            guard case .failed(let message) = event else { return false }
            return message == PermissionTimeout.message
        })
        #expect(!events.contains(.completed))
    }
}

private enum TestError: Error {
    case missingPermissionRequest([AgentEvent])
}
