import Foundation
import Testing
@testable import LatticeCore

@Suite("Finite provider subprocesses")
struct FiniteProviderSubprocessTests {
    @Test func fakeExecutableHangTimesOutAndCleansUp() async throws {
        let fixture = try FakeExecutable(body: "while :; do :; done")
        defer { fixture.remove() }

        let start = Date()
        let result = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: fixture.executable,
                deadline: 0.12,
                maximumOutputBytes: 4_096,
                terminateGraceInterval: 0.05
            )
        )

        #expect(result.outcome == .timedOut)
        #expect(await waitForFile(fixture.cleaned))
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func fakeExecutableOutputIsCappedAndCleanedUp() async throws {
        let fixture = try FakeExecutable(body: "while :; do printf '%8192s' ''; done")
        defer { fixture.remove() }

        let result = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: fixture.executable,
                deadline: 5,
                maximumOutputBytes: 4_096,
                terminateGraceInterval: 0.05
            )
        )

        #expect(result.outcome == .outputLimitExceeded)
        #expect(result.stdout.count + result.stderr.count <= 4_096)
        #expect(result.observedOutputBytes >= 4_096)
        #expect(await waitForFile(fixture.cleaned))
    }

    @Test func fakeExecutableParentCancellationReapsAndCleansUp() async throws {
        let fixture = try FakeExecutable(body: "while :; do :; done")
        defer { fixture.remove() }

        let task = Task {
            await BoundedSubprocess.run(
                BoundedSubprocessRequest(
                    executableURL: fixture.executable,
                    deadline: 30,
                    maximumOutputBytes: 4_096,
                    terminateGraceInterval: 0.05
                )
            )
        }
        #expect(await waitForFile(fixture.started))
        task.cancel()
        let result = await task.value

        #expect(result.outcome == .cancelled)
        #expect(await waitForFile(fixture.cleaned))
    }

    @Test func finiteHarnessCommandsCancelAndCleanUp() async throws {
        let codexFixture = try FakeExecutable(body: "while :; do :; done")
        defer { codexFixture.remove() }
        let codexTask = Task {
            await CodexExecHarness(executableURL: codexFixture.executable).isAuthenticated()
        }
        #expect(await waitForFile(codexFixture.started))
        codexTask.cancel()
        #expect(await codexTask.value == false)
        #expect(await waitForFile(codexFixture.cleaned))

        let structuredFixture = try FakeExecutable(body: "while :; do :; done")
        defer { structuredFixture.remove() }
        let structuredTask = Task {
            await StructuredCLIHarness(kind: .grok, executableURL: structuredFixture.executable).isAuthenticated()
        }
        #expect(await waitForFile(structuredFixture.started))
        structuredTask.cancel()
        #expect(await structuredTask.value == false)
        #expect(await waitForFile(structuredFixture.cleaned))

        let antigravityFixture = try FakeExecutable(body: "while :; do :; done")
        defer { antigravityFixture.remove() }
        let antigravityTask = Task {
            await AntigravityCLIHarness(executableURL: antigravityFixture.executable).models()
        }
        #expect(await waitForFile(antigravityFixture.started))
        antigravityTask.cancel()
        let antigravityModels = await antigravityTask.value
        #expect(antigravityModels.isEmpty)
        #expect(await waitForFile(antigravityFixture.cleaned))
    }

    @Test func finiteHarnessCommandsRejectOversizedOutput() async throws {
        let fixture = try FakeExecutable(body: """
        i=0
        while [ "$i" -lt 400 ]; do
            printf '%8192s' ''
            i=$((i + 1))
        done
        """)
        defer { fixture.remove() }

        let start = Date()
        let codexVersion = await CodexExecHarness(executableURL: fixture.executable).cliVersion()
        let structuredModels = await StructuredCLIHarness(kind: .grok, executableURL: fixture.executable).models()
        let antigravityModels = await AntigravityCLIHarness(executableURL: fixture.executable).models()

        #expect(codexVersion == nil)
        #expect(structuredModels.isEmpty)
        #expect(antigravityModels.isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

private struct FakeExecutable {
    let root: URL
    let executable: URL
    let started: URL
    let cleaned: URL

    init(body: String) throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent("lattice-fake-subprocess-\(UUID().uuidString)", isDirectory: true)
        executable = root.appendingPathComponent("fake-provider")
        started = root.appendingPathComponent("started")
        cleaned = root.appendingPathComponent("cleaned")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        STARTED=\(shellQuote(started.path))
        CLEANED=\(shellQuote(cleaned.path))
        printf started > "$STARTED"
        trap 'printf cleaned > "$CLEANED"; exit 143' TERM INT
        \(body)
        """
        try Data(script.utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func waitForFile(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: url.path) {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}
