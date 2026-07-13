import Foundation

/// Runs Antigravity's first-party non-interactive CLI surface. Unlike ACP-backed
/// providers, this route is intentionally transcript-driven and owns no hidden
/// provider session state.
public final class AntigravityCLIHarness: @unchecked Sendable {
    private let executableURL: URL?
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var cancelled: Set<UUID> = []

    public init(executableURL: URL? = ExecutableDiscovery.locate("agy")) {
        self.executableURL = executableURL
    }

    public var isInstalled: Bool { executableURL != nil }

    public func models() async -> [ProviderModel] {
        guard let executableURL else { return [] }
        let result = await Self.run(executableURL, arguments: ["models"])
        guard result.isSuccess else { return [] }
        let names = String(decoding: result.combinedOutput, as: UTF8.self)
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
                let output = Pipe()
                process.executableURL = executableURL
                process.currentDirectoryURL = workspace
                var arguments = ["--print", prompt, "--model", model, "--sandbox"]
                if policy == .yolo {
                    arguments += ["--mode", "accept-edits", "--dangerously-skip-permissions"]
                } else {
                    // Print mode cannot forward an interactive permission request back
                    // into Lattice, so Ask and Smart remain read-only/plan routes.
                    arguments += ["--mode", "plan"]
                }
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = output

                do {
                    try process.run()
                    register(process, for: sessionID)
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
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func register(_ process: Process, for sessionID: UUID) {
        lock.lock()
        cancelled.remove(sessionID)
        processes[sessionID] = process
        lock.unlock()
    }

    private func unregister(_ sessionID: UUID) -> Bool {
        lock.lock()
        processes[sessionID] = nil
        let wasCancelled = cancelled.remove(sessionID) != nil
        lock.unlock()
        return wasCancelled
    }

    private static func run(_ executableURL: URL, arguments: [String]) async -> BoundedSubprocessResult {
        await BoundedSubprocess.run(.init(
            executableURL: executableURL,
            arguments: arguments
        ))
    }
}
