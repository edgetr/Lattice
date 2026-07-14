import Foundation
import Testing
@testable import LatticeCore

@Suite("Antigravity CLI harness")
struct AntigravityCLIHarnessTests {
    @Test func detectsOnlyExplicitStructuredProtocolSupport() {
        #expect(AntigravityCLIProtocol.detect(helpOutput: "--print\n--conversation") == .transcript(reason: "This Antigravity CLI does not advertise stream-json output."))
        #expect(AntigravityCLIProtocol.detect(helpOutput: "--output-format text|json|stream-json") == .streamJSON)
        #expect(AntigravityCLIProtocol.detect(helpOutput: "--output-format json") == .transcript(reason: "This Antigravity CLI does not advertise stream-json output."))
        let oversizedID = String(repeating: "x", count: 257)
        let event = AntigravityCLIHarness.structuredEvent(
            from: Data("{\"type\":\"init\",\"session_id\":\"\(oversizedID)\"}".utf8),
            workspace: URL(fileURLWithPath: "/tmp/Lattice")
        )
        #expect(event.contains(where: { if case .providerDiagnostic = $0 { return true }; return false }))
    }

    @Test func streamsPromptOverStdinWithoutPuttingItInLaunchArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = root.appendingPathComponent("agy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        #!/bin/sh
        printf 'ARGS\\n'
        for argument in "$@"; do
          printf '%s\\n' "$argument"
        done
        printf 'INPUT\\n'
        cat
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let prompt = "private transcript: do not expose\nsecond line; $(not executed)"
        let stream = AntigravityCLIHarness(executableURL: executable).stream(
            prompt: prompt,
            sessionID: UUID(),
            workspace: root,
            model: "test-model",
            policy: .smart
        )
        var output = ""
        var events: [AgentEvent] = []
        for await event in stream {
            events.append(event)
            if case .assistantDelta(let delta) = event { output += delta }
        }

        #expect(events.contains(.completed))
        guard let inputMarker = output.range(of: "INPUT\n") else {
            Issue.record("Fake Antigravity did not report stdin")
            return
        }
        let argumentsOutput = String(output[..<inputMarker.lowerBound])
        let inputOutput = String(output[inputMarker.upperBound...])
        #expect(argumentsOutput == "ARGS\n--print\n--model\ntest-model\n--sandbox\n--mode\nplan\n")
        #expect(!argumentsOutput.contains(prompt))
        #expect(inputOutput == prompt)
        #expect(events.contains(where: {
            guard case .harnessActivity(let activity) = $0 else { return false }
            return activity.status == .degraded && activity.detail.contains("provider permissions")
        }))
        #expect(!events.contains(where: { if case .harnessSessionStarted = $0 { return true }; return false }))
    }

    @Test func structuredPathExposesSessionToolAndCommandLifecycle() async throws {
        let fixture = try executable(body: """
        if [ "${1:-}" = "--help" ]; then
          printf '%s\n' '--output-format text|json|stream-json'
          exit 0
        fi
        printf '%s\n' "$@" > "$(dirname "$0")/arguments"
        cat >/dev/null
        printf '%s\n' '{"type":"init","session_id":"provider-session","model":"test"}'
        printf '%s\n' '{"type":"tool_use","tool_id":"tool-1","tool_name":"run_command","parameters":{"command":"swift test"}}'
        printf '%s\n' '{"type":"tool_result","tool_id":"tool-1","status":"success"}'
        printf '%s\n' '{"type":"message","role":"assistant","content":"done"}'
        printf '%s\n' '{"type":"result","status":"success"}'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let events = await collect(AntigravityCLIHarness(executableURL: fixture.url).stream(
            prompt: "work",
            sessionID: UUID(),
            threadID: "prior-session",
            workspace: fixture.root,
            model: "test-model",
            policy: .smart
        ))

        #expect(events.contains(.harnessSessionStarted("provider-session")))
        #expect(events.contains(.assistantDelta("done")))
        #expect(events.contains(.completed))
        #expect(events.contains(where: {
            guard case .toolRequested(let request) = $0 else { return false }
            return request.kind == .command && request.detail == "$ swift test"
        }))
        #expect(events.contains(where: {
            guard case .toolProgress(_, _, let detail) = $0 else { return false }
            return detail == "Completed"
        }))
        #expect(events.contains(where: {
            guard case .harnessActivity(let activity) = $0 else { return false }
            return activity.status == .completed
        }))
        #expect(events.contains(where: {
            guard case .harnessActivity(let activity) = $0 else { return false }
            return activity.status == .unsupported && activity.title.contains("permission")
        }))
        let arguments = try String(contentsOf: fixture.root.appendingPathComponent("arguments"), encoding: .utf8)
        #expect(arguments.contains("--output-format\nstream-json\n"))
        #expect(arguments.contains("--conversation\nprior-session\n"))
    }

    @Test func malformedStructuredOutputFailsClosedAndNextRunRecovers() async throws {
        let fixture = try executable(body: """
        if [ "${1:-}" = "--help" ]; then
          printf '%s\n' '--output-format stream-json'
          exit 0
        fi
        cat >/dev/null
        count_file="$(dirname "$0")/count"
        count=0
        [ -f "$count_file" ] && count=$(cat "$count_file")
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        if [ "$count" -eq 1 ]; then
          printf '%s\n' 'not-json'
          exit 0
        fi
        printf '%s\n' '{"type":"init","session_id":"recovered-session"}'
        printf '%s\n' '{"type":"message","role":"assistant","content":"recovered"}'
        printf '%s\n' '{"type":"result","status":"success"}'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let harness = AntigravityCLIHarness(executableURL: fixture.url)

        let first = await collect(harness.stream(prompt: "first", sessionID: UUID(), workspace: fixture.root, model: "test", policy: .smart))
        #expect(first.contains(where: { if case .providerDiagnostic = $0 { return true }; return false }))
        #expect(first.contains(.failed("Antigravity ended without a structured result event.")))

        let second = await collect(harness.stream(prompt: "second", sessionID: UUID(), workspace: fixture.root, model: "test", policy: .smart))
        #expect(second.contains(.harnessSessionStarted("recovered-session")))
        #expect(second.contains(.assistantDelta("recovered")))
        #expect(second.contains(.completed))
    }

    @Test func cancellationIsObservableAndDoesNotPoisonRecovery() async throws {
        let fixture = try executable(body: """
        if [ "${1:-}" = "--help" ]; then
          printf '%s\n' '--print only'
          exit 0
        fi
        touch "$(dirname "$0")/started"
        cat >/dev/null
        while :; do sleep 0.05; done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let harness = AntigravityCLIHarness(executableURL: fixture.url)
        let sessionID = UUID()
        let collector = Task { await collect(harness.stream(prompt: "cancel", sessionID: sessionID, workspace: fixture.root, model: "test", policy: .smart)) }
        #expect(await waitForFile(fixture.root.appendingPathComponent("started")))
        harness.cancel(sessionID: sessionID)
        let events = await collector.value
        #expect(events.contains(.cancelled))
        #expect(events.contains(where: {
            guard case .harnessActivity(let activity) = $0 else { return false }
            return activity.status == .cancelled
        }))

        let recovery = try executable(body: """
        if [ "${1:-}" = "--help" ]; then printf '%s\n' '--print only'; exit 0; fi
        cat >/dev/null
        printf 'recovered'
        """)
        defer { try? FileManager.default.removeItem(at: recovery.root) }
        let recovered = await collect(AntigravityCLIHarness(executableURL: recovery.url).stream(prompt: "again", sessionID: sessionID, workspace: recovery.root, model: "test", policy: .smart))
        #expect(recovered.contains(.assistantDelta("recovered")))
        #expect(recovered.contains(.completed))
    }

    @Test func providerHealthDistinguishesCatalogFailureFromEmptyCatalog() async throws {
        let failed = try executable(body: """
        if [ "${1:-}" = "--help" ]; then printf '%s\n' '--print only'; exit 0; fi
        if [ "${1:-}" = "models" ]; then exit 7; fi
        """)
        defer { try? FileManager.default.removeItem(at: failed.root) }
        let failedHealth = await AntigravityCLIHarness(executableURL: failed.url).health()
        #expect(failedHealth.installed)
        #expect(failedHealth.catalogStatus == .failed)
        #expect(!failedHealth.protocolSupport.isStructured)

        let empty = try executable(body: """
        if [ "${1:-}" = "--help" ]; then printf '%s\n' '--output-format stream-json'; exit 0; fi
        if [ "${1:-}" = "models" ]; then exit 0; fi
        """)
        defer { try? FileManager.default.removeItem(at: empty.root) }
        let emptyHealth = await AntigravityCLIHarness(executableURL: empty.url).health()
        #expect(emptyHealth.catalogStatus == .empty)
        #expect(emptyHealth.protocolSupport == .streamJSON)
    }

    private func executable(body: String) throws -> (root: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("agy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (root, url)
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
