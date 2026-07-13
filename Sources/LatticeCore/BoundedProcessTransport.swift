import Darwin
import Foundation

public enum BoundedProcessTerminationReason: String, Sendable, Equatable {
    case completed
    case timedOut
    case cancelled
    case outputLimitExceeded
    case launchFailed
}

public enum BoundedProcessTransportError: LocalizedError, Sendable, Equatable {
    case notStarted
    case launchFailed(String)
    case timedOut
    case cancelled
    case outputLimitExceeded
    case closed
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notStarted: "Process has not started."
        case .launchFailed(let message): "Process could not start: \(message)"
        case .timedOut: "Provider process timed out."
        case .cancelled: "Provider process was cancelled."
        case .outputLimitExceeded: "Provider process exceeded its output limit."
        case .closed: "Provider process output closed before completion."
        case .readFailed(let message): "Provider process output could not be read: \(message)"
        }
    }
}

/// Owns an interactive provider process without blocking Swift's cooperative executor.
/// Call blocking read/write methods only inside `BoundedSubprocess.performOffCooperativeExecutor`.
public final class BoundedProcessTransport: @unchecked Sendable {
    private let request: BoundedSubprocessRequest
    private let mergeStandardError: Bool
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let stateLock = NSLock()
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private let waitLock = NSLock()
    private var started = false
    private var launching = false
    private var cleanedUp = false
    private var stopping = false
    private var processIdentifier: pid_t = 0
    private var reapedProcessIdentifier: pid_t?
    /// Populated only after observing that the child leads its own group.
    private var processGroupIdentifier: pid_t?
    private var cachedExitStatus: Int32?
    private var reason: BoundedProcessTerminationReason?
    private var totalObservedOutputBytes = 0
    private var watchdog: DispatchWorkItem?
    private var lineBuffer = Data()

    public init(request: BoundedSubprocessRequest, mergeStandardError: Bool = false) {
        self.request = request
        self.mergeStandardError = mergeStandardError
    }

    public var input: FileHandle { inputPipe.fileHandleForWriting }
    public var output: FileHandle { outputPipe.fileHandleForReading }

    public var terminationReason: BoundedProcessTerminationReason? {
        stateLock.lock(); defer { stateLock.unlock() }
        return reason
    }

    public var observedOutputBytes: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return totalObservedOutputBytes
    }

    public var isRunning: Bool {
        guard let processIdentifier = currentProcessIdentifier else { return false }
        if reapIfExited(processIdentifier) != nil { return false }
        return processExists(processIdentifier)
    }

    /// True after cancellation, timeout, output overflow, or process cleanup.
    public var shouldStop: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return reason != nil
    }

    public var exitStatus: Int32? {
        stateLock.lock()
        let cachedExitStatus = self.cachedExitStatus
        let processIdentifier = self.processIdentifier
        stateLock.unlock()
        if let cachedExitStatus { return cachedExitStatus }
        guard processIdentifier > 0 else { return nil }
        return reapIfExited(processIdentifier)
    }

    /// Bounded direct-child reap after protocol EOF. This is useful for
    /// transcript-driven CLIs where EOF can race process termination.
    public func waitForExit(timeout: TimeInterval = 0.5) -> Int32? {
        guard let processIdentifier = currentProcessIdentifier else { return exitStatus }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if let status = reapIfExited(processIdentifier) { return status }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.005)
        } while true
    }

    public func start() throws {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            return
        }
        started = true
        launching = true
        let alreadyStopped = reason
        stateLock.unlock()

        if let alreadyStopped {
            cleanupPipes()
            throw error(for: alreadyStopped)
        }

        do {
            let spawned = try spawn()
            stateLock.lock()
            processIdentifier = spawned.processIdentifier
            processGroupIdentifier = spawned.processGroupIdentifier
            launching = false
            let shouldStop = cleanedUp || reason != nil
            stateLock.unlock()
            if shouldStop {
                forceStop(spawned, grace: request.terminateGraceInterval)
                cleanupPipes()
                stateLock.lock()
                cleanedUp = true
                stateLock.unlock()
                return
            }
        } catch {
            stateLock.lock()
            launching = false
            if reason == nil { reason = .launchFailed }
            let finalReason = reason ?? .launchFailed
            stateLock.unlock()
            cleanupPipes()
            if finalReason == .launchFailed {
                throw BoundedProcessTransportError.launchFailed(error.localizedDescription)
            }
            throw self.error(for: finalReason)
        }

        if let deadline = request.deadline {
            let work = DispatchWorkItem { [weak self] in self?.timeout() }
            stateLock.lock()
            watchdog = work
            stateLock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + max(0, deadline),
                execute: work
            )
        }
    }

    public func write(_ data: Data) throws {
        try write(data, allowingCancellation: false)
    }

    /// Writes a final protocol-control frame during the bounded cancellation grace period.
    /// Use only for cancellation/denial acknowledgements, never for new work.
    public func writeControl(_ data: Data) throws {
        try write(data, allowingCancellation: true)
    }

    private func write(_ data: Data, allowingCancellation: Bool) throws {
        guard !data.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        if let reason = terminationReason,
           !(allowingCancellation && reason == .cancelled) {
            throw error(for: reason)
        }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw BoundedProcessTransportError.readFailed(error.localizedDescription)
        }
    }

    /// Closes the provider's stdin after all preceding writes have completed.
    public func closeInput() {
        writeLock.lock()
        defer { writeLock.unlock() }
        try? inputPipe.fileHandleForWriting.close()
    }

    public func readLine() throws -> Data? {
        readLock.lock()
        defer { readLock.unlock() }

        while true {
            if let newline = lineBuffer.firstIndex(of: 0x0A) {
                let line = Data(lineBuffer[..<newline])
                lineBuffer.removeSubrange(...newline)
                return line
            }

            do {
                let chunk = try readChunkFromPipe(maxLength: 16_384)
                guard let chunk, !chunk.isEmpty else {
                    guard !lineBuffer.isEmpty else {
                        if let reason = terminationReason, reason != .completed {
                            throw error(for: reason)
                        }
                        return nil
                    }
                    defer { lineBuffer.removeAll(keepingCapacity: true) }
                    return lineBuffer
                }
                lineBuffer.append(chunk)
            } catch {
                throw mapped(error)
            }
        }
    }

    public func readChunk(maxLength: Int = 16_384) throws -> Data? {
        readLock.lock()
        defer { readLock.unlock() }
        do {
            return try readChunkFromPipe(maxLength: max(1, maxLength))
        } catch {
            throw mapped(error)
        }
    }

    /// Mark normal protocol completion and stop the child with bounded cleanup.
    public func finish() {
        markReasonIfNeeded(.completed)
        stopNow()
    }

    /// Mark cancellation immediately. Delay allows protocol cancellation messages to be sent first.
    public func cancel(after delay: TimeInterval = 0) {
        markReasonIfNeeded(.cancelled)
        scheduleStop(after: delay)
    }

    private func timeout() {
        stateLock.lock()
        let shouldTimeout = started && !cleanedUp && reason == nil
        stateLock.unlock()
        guard shouldTimeout else { return }
        markReasonIfNeeded(.timedOut)
        stopNow()
    }

    private func scheduleStop(after delay: TimeInterval) {
        guard delay > 0 else {
            stopNow()
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.stopNow()
        }
    }

    private func readChunkFromPipe(maxLength: Int) throws -> Data? {
        do {
            // `read(upToCount:)` may wait for the requested byte count while an
            // interactive child remains alive. `availableData` returns as soon as
            // the pipe has bytes, which is required for request/response protocols.
            // A pipe read is kernel-bounded; the aggregate cap is enforced below.
            _ = maxLength
            let data = output.availableData
            if data.isEmpty { return nil }
            try recordOutput(data.count)
            return data
        } catch let error as BoundedProcessTransportError {
            throw error
        } catch {
            throw BoundedProcessTransportError.readFailed(error.localizedDescription)
        }
    }

    private func recordOutput(_ count: Int) throws {
        stateLock.lock()
        totalObservedOutputBytes += count
        let exceeded = totalObservedOutputBytes > request.maximumOutputBytes
        if exceeded, reason == nil { reason = .outputLimitExceeded }
        stateLock.unlock()
        if exceeded {
            stopNow()
            throw BoundedProcessTransportError.outputLimitExceeded
        }
    }

    private func markReasonIfNeeded(_ value: BoundedProcessTerminationReason) {
        stateLock.lock()
        if reason == nil { reason = value }
        stateLock.unlock()
    }

    private func stopNow() {
        stateLock.lock()
        guard !cleanedUp, !stopping, !launching else {
            stateLock.unlock()
            return
        }
        stopping = true
        let wasStarted = started
        let spawned: SpawnedProcess?
        if processIdentifier > 0 || processGroupIdentifier != nil {
            spawned = SpawnedProcess(processIdentifier: processIdentifier, processGroupIdentifier: processGroupIdentifier)
        } else {
            spawned = nil
        }
        watchdog?.cancel()
        stateLock.unlock()

        if wasStarted, let spawned {
            forceStop(spawned, grace: request.terminateGraceInterval)
        }
        cleanupPipes()

        stateLock.lock()
        cleanedUp = true
        stopping = false
        stateLock.unlock()
    }

    private func cleanupPipes() {
        writeLock.lock()
        try? inputPipe.fileHandleForWriting.close()
        writeLock.unlock()
        try? outputPipe.fileHandleForReading.close()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
    }

    private func mapped(_ error: Error) -> Error {
        if let error = error as? BoundedProcessTransportError { return error }
        if let reason = terminationReason, reason != .completed { return self.error(for: reason) }
        return error
    }

    private func error(for reason: BoundedProcessTerminationReason) -> BoundedProcessTransportError {
        switch reason {
        case .completed: .closed
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .outputLimitExceeded: .outputLimitExceeded
        case .launchFailed: .launchFailed("launch failed")
        }
    }

    private func spawn() throws -> SpawnedProcess {
        let nullDescriptor = mergeStandardError ? -1 : Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
        if !mergeStandardError, nullDescriptor < 0 { throw SpawnError(code: errno) }
        defer {
            if nullDescriptor >= 0 { _ = Darwin.close(nullDescriptor) }
        }
        var fileActions: posix_spawn_file_actions_t?
        let fileActionsStatus = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsStatus == 0 else { throw SpawnError(code: fileActionsStatus) }
        defer { _ = posix_spawn_file_actions_destroy(&fileActions) }

        try addDup2(source: inputPipe.fileHandleForReading.fileDescriptor, destination: STDIN_FILENO, to: &fileActions)
        try addDup2(source: outputPipe.fileHandleForWriting.fileDescriptor, destination: STDOUT_FILENO, to: &fileActions)
        let standardErrorDescriptor = mergeStandardError ? outputPipe.fileHandleForWriting.fileDescriptor : nullDescriptor
        try addDup2(source: standardErrorDescriptor, destination: STDERR_FILENO, to: &fileActions)

        let sourceDescriptors = [
            inputPipe.fileHandleForReading.fileDescriptor,
            outputPipe.fileHandleForWriting.fileDescriptor,
            standardErrorDescriptor,
            inputPipe.fileHandleForWriting.fileDescriptor,
            outputPipe.fileHandleForReading.fileDescriptor
        ]
        for descriptor in Set(sourceDescriptors) where descriptor != STDIN_FILENO && descriptor != STDOUT_FILENO && descriptor != STDERR_FILENO {
            let status = posix_spawn_file_actions_addclose(&fileActions, descriptor)
            guard status == 0 else { throw SpawnError(code: status) }
        }
        if let currentDirectoryURL = request.currentDirectoryURL {
            let status = currentDirectoryURL.path.withCString { posix_spawn_file_actions_addchdir_np(&fileActions, $0) }
            guard status == 0 else { throw SpawnError(code: status) }
        }

        var attributes: posix_spawnattr_t?
        let attributesStatus = posix_spawnattr_init(&attributes)
        guard attributesStatus == 0 else { throw SpawnError(code: attributesStatus) }
        defer { _ = posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        let flagsStatus = posix_spawnattr_setflags(&attributes, flags)
        guard flagsStatus == 0 else { throw SpawnError(code: flagsStatus) }

        let executablePath = request.executableURL.path
        let arguments = [executablePath] + request.arguments
        let environment = request.environment?.map { key, value in String(key) + "=" + value }
        var processIdentifier: pid_t = 0
        let spawnStatus = try withCStringArray(arguments) { argumentPointers in
            try executablePath.withCString { executablePointer in
                if let environment {
                    return try withCStringArray(environment) { environmentPointers in
                        posix_spawn(&processIdentifier, executablePointer, &fileActions, &attributes, argumentPointers, environmentPointers)
                    }
                }
                return posix_spawn(&processIdentifier, executablePointer, &fileActions, &attributes, argumentPointers, environ)
            }
        }
        guard spawnStatus == 0 else { throw SpawnError(code: spawnStatus) }
        guard processIdentifier > 0 else { throw SpawnError(code: EINVAL) }
        let observedGroup = getpgid(processIdentifier)
        let processGroupIdentifier: pid_t? = observedGroup == processIdentifier ? observedGroup : nil

        // ESRCH is normal when a short-lived child exits between spawn and
        // observation. For every mismatch, retain direct-child ownership but
        // never signal a process group that was not positively verified.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        return SpawnedProcess(processIdentifier: processIdentifier, processGroupIdentifier: processGroupIdentifier)
    }

    private struct SpawnError: LocalizedError {
        let code: Int32
        var errorDescription: String? {
            guard let message = strerror(code) else { return "POSIX error \(code)" }
            return String(cString: message)
        }
    }

    private func addDup2(source: Int32, destination: Int32, to fileActions: inout posix_spawn_file_actions_t?) throws {
        let status = posix_spawn_file_actions_adddup2(&fileActions, source, destination)
        guard status == 0 else { throw SpawnError(code: status) }
    }

    private func withCStringArray<T>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> T) throws -> T {
        var allocatedPointers = [UnsafeMutablePointer<CChar>]()
        allocatedPointers.reserveCapacity(strings.count)
        defer { allocatedPointers.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else { throw SpawnError(code: ENOMEM) }
            allocatedPointers.append(pointer)
        }
        var pointers = allocatedPointers.map(Optional.some)
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in try body(buffer.baseAddress) }
    }

    private func reapFailedProcess(_ processIdentifier: pid_t) {
        guard processIdentifier > 0 else { return }
        var waitStatus: Int32 = 0
        while waitpid(processIdentifier, &waitStatus, 0) == -1 && errno == EINTR {}
    }

    private struct SpawnedProcess {
        let processIdentifier: pid_t
        let processGroupIdentifier: pid_t?
    }

    private func forceStop(_ process: SpawnedProcess, grace: TimeInterval) {
        let childWasReaped = hasReapedProcess(process.processIdentifier)
        if let group = process.processGroupIdentifier,
           processGroupExists(group) {
            signalProcessGroup(group, signal: SIGTERM)
        } else if !childWasReaped, processExists(process.processIdentifier) {
            _ = kill(process.processIdentifier, SIGTERM)
        }
        waitUntilStopped(process, timeout: grace)
        let childIsReaped = hasReapedProcess(process.processIdentifier)
        if let group = process.processGroupIdentifier,
           processGroupExists(group) {
            signalProcessGroup(group, signal: SIGKILL)
        } else if !childIsReaped, processExists(process.processIdentifier) {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        waitUntilStopped(process, timeout: max(0.1, grace))
        if !hasReapedProcess(process.processIdentifier) {
            _ = reapIfExited(process.processIdentifier)
        }
    }

    private func waitUntilStopped(_ process: SpawnedProcess, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            let childExited = reapIfExited(process.processIdentifier) != nil || hasReapedProcess(process.processIdentifier)
            let childExists = !childExited && processExists(process.processIdentifier)
            let groupExists = process.processGroupIdentifier.map(processGroupExists) == true
            if !childExists && !groupExists { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private var currentProcessIdentifier: pid_t? {
        stateLock.lock(); defer { stateLock.unlock() }
        return processIdentifier > 0 ? processIdentifier : nil
    }

    private func processExists(_ processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0 else { return false }
        if kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private func processGroupExists(_ processGroupIdentifier: pid_t) -> Bool {
        guard processGroupIdentifier > 0 else { return false }
        if kill(-processGroupIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private func signalProcessGroup(_ processGroupIdentifier: pid_t, signal: Int32) {
        guard processGroupIdentifier > 0, processGroupExists(processGroupIdentifier) else { return }
        _ = kill(-processGroupIdentifier, signal)
    }

    private func reapIfExited(_ processIdentifier: pid_t) -> Int32? {
        guard processIdentifier > 0 else { return nil }
        waitLock.lock(); defer { waitLock.unlock() }
        var waitStatus: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &waitStatus, WNOHANG)
            if result == processIdentifier {
                let status = terminationStatus(from: waitStatus)
                if let status {
                    stateLock.lock()
                    cachedExitStatus = status
                    reapedProcessIdentifier = processIdentifier
                    if self.processIdentifier == processIdentifier {
                        self.processIdentifier = 0
                    }
                    stateLock.unlock()
                }
                return status
            }
            if result == 0 { return nil }
            if errno == EINTR { continue }
            if errno == ECHILD {
                return cachedStatus(for: processIdentifier)
            }
            return nil
        }
    }

    private func cachedStatus(for processIdentifier: pid_t) -> Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard self.processIdentifier == processIdentifier || reapedProcessIdentifier == processIdentifier else { return nil }
        return cachedExitStatus
    }

    private func hasReapedProcess(_ processIdentifier: pid_t) -> Bool {
        cachedStatus(for: processIdentifier) != nil
    }

    private func terminationStatus(from waitStatus: Int32) -> Int32? {
        let status = waitStatus & 0o177
        if status == 0 { return (waitStatus >> 8) & 0xFF }
        if status != 0o177 { return status }
        return nil
    }
}
