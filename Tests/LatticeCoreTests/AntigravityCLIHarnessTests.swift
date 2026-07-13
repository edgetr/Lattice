import Foundation
import Testing
@testable import LatticeCore

@Suite("Antigravity CLI harness")
struct AntigravityCLIHarnessTests {
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
    }
}
