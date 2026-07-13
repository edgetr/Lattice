import Foundation

/// Runs Antigravity's first-party non-interactive CLI surface. Unlike ACP-backed
/// providers, this route is intentionally transcript-driven and owns no hidden
/// provider session state.
public final class AntigravityCLIHarness: @unchecked Sendable {
    private let executableURL: URL?
    private let processRegistry = InteractiveProcessRegistry()

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
            let start = processRegistry.beginStart(for: sessionID)
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    _ = processRegistry.abandonStart(start, sessionID: sessionID)
                    continuation.yield(.failed("Antigravity CLI is not installed."))
                    continuation.finish()
                    return
                }

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
                var promptData = Data(prompt.utf8)
                if promptData.last != 0x0A { promptData.append(0x0A) }
                let transport = BoundedProcessTransport(
                    request: .init(
                        executableURL: executableURL,
                        arguments: arguments,
                        currentDirectoryURL: workspace,
                        deadline: 30 * 60,
                        maximumOutputBytes: 8_000_000
                    ),
                    mergeStandardError: true
                )
                var owner: InteractiveProcessRegistry.Owner?
                do {
                    try transport.start()
                    guard case .accepted(let registeredOwner) = processRegistry.register(process: transport, input: nil, for: sessionID, start: start) else {
                        throw NSError(domain: "AntigravityCLIHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Antigravity request cancelled before process registration."])
                    }
                    owner = registeredOwner
                    try transport.write(promptData)
                    transport.closeInput()
                    while let data = try transport.readChunk() {
                        continuation.yield(.assistantDelta(String(decoding: data, as: UTF8.self)))
                    }
                    let exitStatus = transport.waitForExit()
                    let result = processRegistry.unregister(registeredOwner, sessionID: sessionID)
                    let wasCancelled = result.wasCancelled
                    if wasCancelled {
                        continuation.yield(.cancelled)
                    } else if transport.terminationReason == .timedOut {
                        continuation.yield(.failed("Antigravity timed out."))
                    } else if transport.terminationReason == .outputLimitExceeded {
                        continuation.yield(.failed("Antigravity output exceeded its limit."))
                    } else if exitStatus == 0 {
                        continuation.yield(.completed)
                    } else {
                        continuation.yield(.failed("Antigravity exited with status \(exitStatus ?? -1)."))
                    }
                    transport.finish()
                } catch {
                    let wasCancelled: Bool
                    if let owner {
                        wasCancelled = processRegistry.unregister(owner, sessionID: sessionID).wasCancelled
                    } else {
                        wasCancelled = processRegistry.abandonStart(start, sessionID: sessionID)
                    }
                    transport.cancel()
                    continuation.yield(wasCancelled || transport.terminationReason == .cancelled ? .cancelled : .failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                self?.cancel(sessionID: sessionID, start: start)
                task.cancel()
            }
        }
    }

    public func cancel(sessionID: UUID) {
        processRegistry.cancel(sessionID: sessionID).process?.cancel()
    }

    private func cancel(sessionID: UUID, start: InteractiveProcessRegistry.StartToken) {
        processRegistry.cancel(sessionID: sessionID, start: start).process?.cancel()
    }

    private static func run(_ executableURL: URL, arguments: [String]) async -> BoundedSubprocessResult {
        await BoundedSubprocess.run(.init(
            executableURL: executableURL,
            arguments: arguments,
            deadline: 30,
            maximumOutputBytes: BoundedSubprocessRequest.defaultMaximumOutputBytes
        ))
    }
}
