import Testing
import Foundation
import Darwin
@testable import LatticeCore

@Suite("Bounded subprocess")
struct BoundedSubprocessTests {
    private var shell: URL {
        URL(fileURLWithPath: "/bin/sh")
    }

    @Test func exitsWithStatusAndCapturesStdout() async {
        let request = BoundedSubprocessRequest(
            executableURL: shell,
            arguments: ["-c", "printf 'hello-stdout'; echo err-msg 1>&2; exit 7"],
            deadline: 5,
            maximumOutputBytes: 64_000
        )
        let result = await BoundedSubprocess.run(request)
        #expect(result.outcome == .exited)
        #expect(result.exitStatus == 7)
        #expect(String(data: result.stdout, encoding: .utf8) == "hello-stdout")
        #expect(String(data: result.stderr, encoding: .utf8)?.contains("err-msg") == true)
        #expect(!result.isSuccess)
    }

    @Test func successfulZeroExit() async {
        let request = BoundedSubprocessRequest(
            executableURL: shell,
            arguments: ["-c", "printf ok"],
            deadline: 5,
            maximumOutputBytes: 1024
        )
        let result = await BoundedSubprocess.run(request)
        #expect(result.outcome == .exited)
        #expect(result.exitStatus == 0)
        #expect(result.isSuccess)
        #expect(String(data: result.stdout, encoding: .utf8) == "ok")
    }

    @Test func timesOutAndReapsChild() async {
        let request = BoundedSubprocessRequest(
            executableURL: shell,
            arguments: ["-c", "while true; do sleep 0.05; done"],
            deadline: 0.15,
            maximumOutputBytes: 1024,
            terminateGraceInterval: 0.05
        )
        let result = await BoundedSubprocess.run(request)
        #expect(result.outcome == .timedOut)
        #expect(result.exitStatus != nil)
    }

    @Test func respectsOutputCapWithoutHanging() async {
        // Emit more than the cap; runner must stop and report outputLimitExceeded.
        let request = BoundedSubprocessRequest(
            executableURL: shell,
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=64 2>/dev/null"],
            deadline: 5,
            maximumOutputBytes: 2048,
            terminateGraceInterval: 0.05
        )
        let result = await BoundedSubprocess.run(request)
        #expect(result.outcome == .outputLimitExceeded)
        #expect(result.stdout.count + result.stderr.count <= 2048)
        #expect(result.observedOutputBytes >= 2048)
    }

    @Test func propagatesCancellation() async {
        let request = BoundedSubprocessRequest(
            executableURL: shell,
            arguments: ["-c", "while true; do sleep 0.05; done"],
            deadline: 10,
            maximumOutputBytes: 1024,
            terminateGraceInterval: 0.05
        )
        let start = Date()
        let flag = CancellationFlag()
        let task = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            flag.cancel()
        }
        let result = await BoundedSubprocess.run(request, isCancelled: { flag.isCancelled })
        _ = await task.result
        #expect(result.outcome == .cancelled)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func propagatesParentTaskCancellation() async {
        let request = BoundedSubprocessRequest(
            executableURL: shell,
            arguments: ["-c", "while true; do sleep 0.05; done"],
            deadline: 10,
            maximumOutputBytes: 1024,
            terminateGraceInterval: 0.05
        )
        let start = Date()
        let handle = Task {
            await BoundedSubprocess.run(request)
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        handle.cancel()
        let result = await handle.value
        #expect(result.outcome == .cancelled)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func launchFailureForMissingExecutable() async {
        let request = BoundedSubprocessRequest(
            executableURL: URL(fileURLWithPath: "/nonexistent/lattice-no-such-binary-\(UUID().uuidString)"),
            arguments: [],
            deadline: 2,
            maximumOutputBytes: 128
        )
        let result = await BoundedSubprocess.run(request)
        #expect(result.outcome == .launchFailed)
        #expect(result.launchErrorDescription != nil)
        #expect(result.stdout.isEmpty)
    }

    @Test func closesStdinSoReadersDoNotHang() async {
        // `cat` with no args reads stdin until EOF. Closed stdin must let it exit.
        let cat = URL(fileURLWithPath: "/bin/cat")
        let request = BoundedSubprocessRequest(
            executableURL: cat,
            arguments: [],
            deadline: 3,
            maximumOutputBytes: 128
        )
        let result = await BoundedSubprocess.run(request)
        #expect(result.outcome == .exited)
        #expect(result.exitStatus == 0)
    }

    @Test func writesBoundedFiniteStdinBeforeClosingPipe() async {
        let request = BoundedSubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            stdinData: Data("finite-input".utf8),
            deadline: 3,
            maximumOutputBytes: 128
        )
        let result = await BoundedSubprocess.run(request)
        #expect(result.outcome == .exited)
        #expect(result.isSuccess)
        #expect(result.stdout == Data("finite-input".utf8))
    }

    @Test func stopsFiniteProtocolWhenCompletionArrives() async {
        let request = BoundedSubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf ready; while :; do :; done"],
            deadline: 3,
            maximumOutputBytes: 128,
            terminateGraceInterval: 0.05
        )
        let result = await BoundedSubprocess.run(request) { stdout, _ in
            stdout == Data("ready".utf8)
        }
        #expect(result.outcome == .completed)
        #expect(result.isSuccess)
        #expect(result.stdout == Data("ready".utf8))
    }

    @Test func timeoutKillsBackgroundPipeHolder() async {
        let marker = temporaryMarker("timeout")
        let start = temporaryMarker("timeout-start")
        defer {
            cleanupProcesses(at: marker)
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: start)
        }

        let request = backgroundHolderRequest(marker: marker, start: start, writesOutput: false, deadline: 0.08)
        let completion = CompletionProbe()
        let task = Task {
            let result = await BoundedSubprocess.run(request)
            completion.markCompleted()
            return result
        }

        let markerReady = await waitUntil(timeout: 1) { FileManager.default.fileExists(atPath: marker.path) }
        #expect(markerReady)
        let completedBeforeCleanup = await waitUntil(timeout: 1) { completion.isCompleted }
        if !completedBeforeCleanup {
            cleanupProcesses(at: marker)
        }
        let result = await task.value

        #expect(completedBeforeCleanup)
        #expect(result.outcome == .timedOut)
        let holderStopped = await waitUntil(timeout: 1) {
            guard let pids = readPIDs(at: marker) else { return false }
            return !isProcessAlive(pids.holder)
        }
        #expect(holderStopped)
    }

    @Test func outputCapKillsBackgroundPipeHolder() async {
        let marker = temporaryMarker("output-cap")
        let start = temporaryMarker("output-cap-start")
        defer {
            cleanupProcesses(at: marker)
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: start)
        }

        let request = backgroundHolderRequest(marker: marker, start: start, writesOutput: true, deadline: 5, maximumOutputBytes: 128)
        let completion = CompletionProbe()
        let task = Task {
            let result = await BoundedSubprocess.run(request)
            completion.markCompleted()
            return result
        }

        let markerReady = await waitUntil(timeout: 1) { FileManager.default.fileExists(atPath: marker.path) }
        #expect(markerReady)
        let completedBeforeCleanup = await waitUntil(timeout: 1) { completion.isCompleted }
        if !completedBeforeCleanup {
            cleanupProcesses(at: marker)
        }
        let result = await task.value

        #expect(completedBeforeCleanup)
        #expect(result.outcome == .outputLimitExceeded)
        #expect(result.stdout.count + result.stderr.count <= 128)
        let holderStopped = await waitUntil(timeout: 1) {
            guard let pids = readPIDs(at: marker) else { return false }
            return !isProcessAlive(pids.holder)
        }
        #expect(holderStopped)
    }

    private func temporaryMarker(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-bounded-subprocess-\(suffix)-\(UUID().uuidString)")
    }

    private func backgroundHolderRequest(
        marker: URL,
        start: URL,
        writesOutput: Bool,
        deadline: TimeInterval,
        maximumOutputBytes: Int = 1_024
    ) -> BoundedSubprocessRequest {
        let loopBody = writesOutput ? "printf x" : ":"
        let script = "( trap '' TERM; while [ ! -f \"$LATTICE_START\" ]; do :; done; while :; do \(loopBody); done ) & holder=$!; printf '%s %s' \"$$\" \"$holder\" > \"$LATTICE_MARKER\"; : > \"$LATTICE_START\"; wait"
        return BoundedSubprocessRequest(
            executableURL: shell,
            arguments: ["-c", script],
            environment: ["LATTICE_MARKER": marker.path, "LATTICE_START": start.path],
            deadline: deadline,
            maximumOutputBytes: maximumOutputBytes,
            terminateGraceInterval: 0.05
        )
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func readPIDs(at marker: URL) -> (group: pid_t, holder: pid_t)? {
        guard let contents = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let values = contents.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { pid_t(String($0)) }
        guard values.count >= 2, values[0] > 0, values[1] > 0 else { return nil }
        return (values[0], values[1])
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func cleanupProcesses(at marker: URL) {
        guard let pids = readPIDs(at: marker) else { return }
        _ = kill(-pids.group, SIGKILL)
        _ = kill(pids.holder, SIGKILL)
    }
}


private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock(); completed = true; lock.unlock()
    }
}

/// Simple lock-backed cancellation probe for tests (avoids relying solely on Task tree).
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
