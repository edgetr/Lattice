import Darwin
import Foundation

// MARK: - Request

/// Launch configuration for a child process. Uses an executable URL + argument array only
/// (never shell interpolation / `sh -c` string building).
public struct BoundedSubprocessRequest: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    /// Bytes written to stdin before it is closed. `nil` keeps the existing EOF-only behavior.
    public var stdinData: Data?
    public var currentDirectoryURL: URL?
    /// When non-nil, replaces the child environment entirely.
    public var environment: [String: String]?
    /// Wall-clock deadline after launch. `nil` means no deadline (still subject to cancellation / output cap).
    public var deadline: TimeInterval?
    /// Combined maximum bytes retained from stdout + stderr. Excess yields `.outputLimitExceeded`.
    public var maximumOutputBytes: Int
    /// Grace period after `terminate()` before a forced `SIGKILL`.
    public var terminateGraceInterval: TimeInterval

    public static let defaultMaximumOutputBytes = 2_000_000
    public static let defaultTerminateGraceInterval: TimeInterval = 0.25

    public init(
        executableURL: URL,
        arguments: [String] = [],
        stdinData: Data? = nil,
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        deadline: TimeInterval? = 60,
        maximumOutputBytes: Int = Self.defaultMaximumOutputBytes,
        terminateGraceInterval: TimeInterval = Self.defaultTerminateGraceInterval
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.stdinData = stdinData
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.deadline = deadline
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.terminateGraceInterval = max(0, terminateGraceInterval)
    }
}

// MARK: - Result

public enum BoundedSubprocessOutcome: String, Sendable, Equatable, Codable {
    case exited
    /// Supervisor stopped process after caller-provided finite-protocol completion condition.
    case completed
    case timedOut
    case cancelled
    case launchFailed
    case outputLimitExceeded
}

public struct BoundedSubprocessResult: Sendable, Equatable {
    public var outcome: BoundedSubprocessOutcome
    public var exitStatus: Int32?
    public var stdout: Data
    public var stderr: Data
    public var launchErrorDescription: String?
    /// Total bytes observed on the pipes (may exceed retained capture when limited).
    public var observedOutputBytes: Int

    public init(
        outcome: BoundedSubprocessOutcome,
        exitStatus: Int32? = nil,
        stdout: Data = Data(),
        stderr: Data = Data(),
        launchErrorDescription: String? = nil,
        observedOutputBytes: Int = 0
    ) {
        self.outcome = outcome
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.launchErrorDescription = launchErrorDescription
        self.observedOutputBytes = observedOutputBytes
    }

    public var combinedOutput: Data {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        var merged = stdout
        merged.append(stderr)
        return merged
    }

    public var isSuccess: Bool {
        switch outcome {
        case .exited: return exitStatus == 0
        case .completed: return true
        case .timedOut, .cancelled, .launchFailed, .outputLimitExceeded: return false
        }
    }
}

// MARK: - Runner

/// Bounded, cancelable subprocess runner with concurrent stdout/stderr draining.
///
/// Design notes:
/// - Never uses shell string interpolation.
/// - Never calls unbounded `readDataToEndOfFile` while a child may keep writing.
/// - Writes optional finite stdin before closing it so input readers do not hang.
/// - On timeout / cancel / output-cap: terminate the process group, short grace, then
///   `SIGKILL`, then reap.
/// - Parent-task cancellation is bridged explicitly because `Task.detached` does not
///   inherit cancellation from the caller.
public enum BoundedSubprocess {
    public static func run(_ request: BoundedSubprocessRequest) async -> BoundedSubprocessResult {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            if Task.isCancelled { flag.cancel() }
            return await runUninterruptibly(request, isCancelled: { flag.isCancelled }, stopWhen: nil)
        } onCancel: {
            flag.cancel()
        }
    }

    /// Runs finite protocols that can declare completion before child naturally exits.
    /// Output remains bounded and timeout/cap/cancel outcomes stay typed.
    public static func run(
        _ request: BoundedSubprocessRequest,
        stopWhen: @escaping @Sendable (_ stdout: Data, _ stderr: Data) -> Bool
    ) async -> BoundedSubprocessResult {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            if Task.isCancelled { flag.cancel() }
            return await runUninterruptibly(request, isCancelled: { flag.isCancelled }, stopWhen: stopWhen)
        } onCancel: {
            flag.cancel()
        }
    }

    /// Test / advanced entry point that injects a cancellation probe.
    public static func run(
        _ request: BoundedSubprocessRequest,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> BoundedSubprocessResult {
        await runUninterruptibly(request, isCancelled: isCancelled, stopWhen: nil)
    }

    private static func runUninterruptibly(
        _ request: BoundedSubprocessRequest,
        isCancelled: @escaping @Sendable () -> Bool,
        stopWhen: (@Sendable (_ stdout: Data, _ stderr: Data) -> Bool)?
    ) async -> BoundedSubprocessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(request, isCancelled: isCancelled, stopWhen: stopWhen))
            }
        }
    }

    /// Lock-backed cancellation probe shared between the caller's cancellation handler
    /// and the detached process supervisor.
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

    private static func runSync(
        _ request: BoundedSubprocessRequest,
        isCancelled: @escaping @Sendable () -> Bool,
        stopWhen: (@Sendable (_ stdout: Data, _ stderr: Data) -> Bool)?
    ) -> BoundedSubprocessResult {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        if let currentDirectoryURL = request.currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        if let environment = request.environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let capture = OutputCapture(maximumOutputBytes: request.maximumOutputBytes, stopWhen: stopWhen)

        do {
            try process.run()
        } catch {
            cleanupPipes(stdout: stdoutPipe, stderr: stderrPipe, stdin: stdinPipe)
            return BoundedSubprocessResult(
                outcome: .launchFailed,
                launchErrorDescription: error.localizedDescription
            )
        }

        // `Process` launches each task in a process group led by its PID on macOS. Keep
        // the group only when that invariant is observable; never signal an unrelated
        // group if launch behavior changes or the child exits before this check.
        let processGroupID: pid_t? = {
            let pid = process.processIdentifier
            guard pid > 0, getpgid(pid) == pid else { return nil }
            return pid
        }()

        attachDrain(stdoutPipe.fileHandleForReading, stream: .stdout, capture: capture)
        attachDrain(stderrPipe.fileHandleForReading, stream: .stderr, capture: capture)

        if let stdinData = request.stdinData, !stdinData.isEmpty {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
        }

        // Close our write end of stdin immediately so the child sees EOF.
        try? stdinPipe.fileHandleForWriting.close()

        let deadlineDate: Date? = request.deadline.map { Date().addingTimeInterval($0) }
        var stopReason: StopReason = .waitForExit

        while process.isRunning {
            if isCancelled() {
                stopReason = .cancelled
                break
            }
            if capture.isOverLimit {
                stopReason = .outputLimit
                break
            }
            if capture.isComplete {
                stopReason = .completed
                break
            }
            if let deadlineDate, Date() >= deadlineDate {
                stopReason = .timedOut
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        switch stopReason {
        case .waitForExit:
            // The child can exit while a descendant keeps writing to the pipe. Treat
            // output observed after that race as a stop condition so the descendant's
            // inherited descriptors are closed before the final drain.
            if capture.isOverLimit {
                stopReason = .outputLimit
                forceStop(process, processGroupID: processGroupID, grace: request.terminateGraceInterval)
            }
        case .timedOut, .cancelled, .outputLimit:
            forceStop(process, processGroupID: processGroupID, grace: request.terminateGraceInterval)
        }

        // Drop handlers before reaping so late EOF callbacks do not race with cleanup.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if process.isRunning {
            forceStop(process, processGroupID: processGroupID, grace: request.terminateGraceInterval)
        }
        process.waitUntilExit()

        // Final non-blocking drain of any residual buffered bytes.
        capture.ingestRemaining(from: stdoutPipe.fileHandleForReading, stream: .stdout)
        capture.ingestRemaining(from: stderrPipe.fileHandleForReading, stream: .stderr)

        cleanupPipes(stdout: stdoutPipe, stderr: stderrPipe, stdin: stdinPipe)

        let snapshot = capture.snapshot()
        switch stopReason {
        case .completed:
            return BoundedSubprocessResult(
                outcome: .completed,
                exitStatus: process.terminationStatus,
                stdout: snapshot.stdout,
                stderr: snapshot.stderr,
                observedOutputBytes: snapshot.observed
            )
        case .timedOut:
            return BoundedSubprocessResult(
                outcome: .timedOut,
                exitStatus: process.terminationStatus,
                stdout: snapshot.stdout,
                stderr: snapshot.stderr,
                observedOutputBytes: snapshot.observed
            )
        case .cancelled:
            return BoundedSubprocessResult(
                outcome: .cancelled,
                exitStatus: process.terminationStatus,
                stdout: snapshot.stdout,
                stderr: snapshot.stderr,
                observedOutputBytes: snapshot.observed
            )
        case .outputLimit:
            return BoundedSubprocessResult(
                outcome: .outputLimitExceeded,
                exitStatus: process.terminationStatus,
                stdout: snapshot.stdout,
                stderr: snapshot.stderr,
                observedOutputBytes: snapshot.observed
            )
        case .waitForExit:
            if snapshot.overLimit {
                return BoundedSubprocessResult(
                    outcome: .outputLimitExceeded,
                    exitStatus: process.terminationStatus,
                    stdout: snapshot.stdout,
                    stderr: snapshot.stderr,
                    observedOutputBytes: snapshot.observed
                )
            }
            return BoundedSubprocessResult(
                outcome: .exited,
                exitStatus: process.terminationStatus,
                stdout: snapshot.stdout,
                stderr: snapshot.stderr,
                observedOutputBytes: snapshot.observed
            )
        }
    }

    private enum StopReason {
        case waitForExit
        case completed
        case timedOut
        case cancelled
        case outputLimit
    }

    private enum Stream {
        case stdout
        case stderr
    }

    private static func attachDrain(_ handle: FileHandle, stream: Stream, capture: OutputCapture) {
        handle.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            capture.append(chunk, stream: stream)
        }
    }

    private static func forceStop(_ process: Process, processGroupID: pid_t?, grace: TimeInterval) {
        let pid = process.processIdentifier
        if let processGroupID, processGroupID > 0 {
            _ = kill(-processGroupID, SIGTERM)
        }
        if process.isRunning {
            // Keep Foundation's direct-child fallback for platforms or launch modes
            // where the process-group invariant is unavailable.
            process.terminate()
        }
        let graceDeadline = Date().addingTimeInterval(grace)
        while Date() < graceDeadline {
            if !process.isRunning && !processGroupExists(processGroupID) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if let processGroupID, processGroupID > 0 {
            _ = kill(-processGroupID, SIGKILL)
        }
        if process.isRunning, pid > 0 {
            _ = kill(pid, SIGKILL)
        }
        let killDeadline = Date().addingTimeInterval(max(0.1, grace))
        while Date() < killDeadline {
            if !process.isRunning && !processGroupExists(processGroupID) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func setNonBlocking(_ handle: FileHandle) -> Bool {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func processGroupExists(_ processGroupID: pid_t?) -> Bool {
        guard let processGroupID, processGroupID > 0 else { return false }
        if kill(-processGroupID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func cleanupPipes(stdout: Pipe, stderr: Pipe, stdin: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        try? stdin.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
    }

    /// Thread-safe bounded capture of concurrent pipe drains.
    private final class OutputCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumOutputBytes: Int
        private let stopWhen: (@Sendable (_ stdout: Data, _ stderr: Data) -> Bool)?
        private var stdout = Data()
        private var stderr = Data()
        private var observed = 0
        private var overLimit = false
        private var complete = false

        init(
            maximumOutputBytes: Int,
            stopWhen: (@Sendable (_ stdout: Data, _ stderr: Data) -> Bool)?
        ) {
            self.maximumOutputBytes = maximumOutputBytes
            self.stopWhen = stopWhen
        }

        var isOverLimit: Bool {
            lock.lock(); defer { lock.unlock() }
            return overLimit
        }

        var isComplete: Bool {
            lock.lock(); defer { lock.unlock() }
            return complete
        }

        func append(_ chunk: Data, stream: Stream) {
            guard !chunk.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            observed += chunk.count
            if overLimit { return }
            let retained = stdout.count + stderr.count
            let remaining = maximumOutputBytes - retained
            if remaining <= 0 {
                overLimit = true
                return
            }
            let slice = chunk.count <= remaining ? chunk : chunk.prefix(remaining)
            switch stream {
            case .stdout: stdout.append(slice)
            case .stderr: stderr.append(slice)
            }
            if chunk.count > remaining {
                overLimit = true
            }
            if !overLimit, stopWhen?(stdout, stderr) == true {
                complete = true
            }
        }

        func ingestRemaining(from handle: FileHandle, stream: Stream) {
            guard BoundedSubprocess.setNonBlocking(handle) else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    append(Data(buffer.prefix(count)), stream: stream)
                    if isOverLimit { return }
                    continue
                }
                if count == 0 { return }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
        }

        func snapshot() -> (stdout: Data, stderr: Data, observed: Int, overLimit: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (stdout, stderr, observed, overLimit)
        }
    }
}
