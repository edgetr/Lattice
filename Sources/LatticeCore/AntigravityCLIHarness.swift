import Foundation

/// Runs Antigravity's first-party non-interactive CLI surface. Unlike ACP-backed
/// providers, this route is intentionally transcript-driven and owns no hidden
/// provider session state.
public final class AntigravityCLIHarness: @unchecked Sendable {
    private let executableURL: URL?
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var inputs: [UUID: FileHandle] = [:]
    private var cancelled: Set<UUID> = []

    public init(executableURL: URL? = ExecutableDiscovery.locate("agy")) {
        self.executableURL = executableURL
    }

    public var isInstalled: Bool { executableURL != nil }

    public func models() async -> [ProviderModel] {
        guard let executableURL else { return [] }
        let result = await Self.run(executableURL, arguments: ["models"])
        guard result.status == 0 else { return [] }
        let names = String(decoding: result.output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.enumerated().map { index, name in
            ProviderModel(
                id: name,
                name: name,
                description: "Antigravity · first-party CLI",
                isDefault: index == 0
            )
        }
    }

    public func stream(
        prompt: String,
        sessionID: UUID,
        workspace: URL,
        model: String,
        policy: ExecutionPolicy
    ) -> AsyncStream<AgentEvent> {
        AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    continuation.yield(.failed("Antigravity CLI is not installed."))
                    continuation.finish()
                    return
                }

                let process = Process()
                let input = Pipe()
                let output = Pipe()
                process.executableURL = executableURL
                process.currentDirectoryURL = workspace
                // Antigravity print mode reads its prompt from stdin when no prompt
                // argument is supplied. Keep transcript content out of argv, where
                // it can be exposed by process inspection and system diagnostics.
                var arguments = ["--print", "--model", model, "--sandbox"]
                if policy == .yolo {
                    arguments += ["--mode", "accept-edits", "--dangerously-skip-permissions"]
                } else {
                    // Print mode cannot forward an interactive permission request back
                    // into Lattice, so Ask and Smart remain read-only/plan routes.
                    arguments += ["--mode", "plan"]
                }
                process.arguments = arguments
                process.standardInput = input
                process.standardOutput = output
                process.standardError = output

                do {
                    try process.run()
                    register(process, input: input.fileHandleForWriting, for: sessionID)
                    try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                    try input.fileHandleForWriting.close()
                    while process.isRunning {
                        let data = output.fileHandleForReading.availableData
                        if !data.isEmpty {
                            continuation.yield(.assistantDelta(String(decoding: data, as: UTF8.self)))
                        }
                    }
                    let trailing = output.fileHandleForReading.readDataToEndOfFile()
                    if !trailing.isEmpty {
                        continuation.yield(.assistantDelta(String(decoding: trailing, as: UTF8.self)))
                    }
                    process.waitUntilExit()
                    let wasCancelled = unregister(sessionID)
                    if wasCancelled {
                        continuation.yield(.cancelled)
                    } else if process.terminationStatus == 0 {
                        continuation.yield(.completed)
                    } else {
                        continuation.yield(.failed("Antigravity exited with status \(process.terminationStatus)."))
                    }
                } catch {
                    let wasCancelled = unregister(sessionID)
                    if process.isRunning { process.terminate() }
                    continuation.yield(wasCancelled ? .cancelled : .failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                self?.cancel(sessionID: sessionID)
                task.cancel()
            }
        }
    }

    public func cancel(sessionID: UUID) {
        lock.lock()
        cancelled.insert(sessionID)
        let process = processes[sessionID]
        let input = inputs[sessionID]
        lock.unlock()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    private func register(_ process: Process, input: FileHandle, for sessionID: UUID) {
        lock.lock()
        cancelled.remove(sessionID)
        processes[sessionID] = process
        inputs[sessionID] = input
        lock.unlock()
    }

    private func unregister(_ sessionID: UUID) -> Bool {
        lock.lock()
        processes[sessionID] = nil
        let input = inputs.removeValue(forKey: sessionID)
        let wasCancelled = cancelled.remove(sessionID) != nil
        lock.unlock()
        try? input?.close()
        return wasCancelled
    }

    private static func run(_ executableURL: URL, arguments: [String]) async -> (status: Int32, output: Data) {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, data)
            } catch {
                return (-1, Data(error.localizedDescription.utf8))
            }
        }.value
    }
}
