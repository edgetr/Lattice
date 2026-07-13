import Testing
import Foundation
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
