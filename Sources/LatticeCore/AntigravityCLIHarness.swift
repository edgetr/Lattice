import Foundation

public enum AntigravityCLIProtocol: Equatable, Sendable {
    case streamJSON
    case transcript(reason: String)

    public var isStructured: Bool {
        if case .streamJSON = self { return true }
        return false
    }

    /// Antigravity has no versioned integration protocol today. Upgrade only when
    /// the running executable explicitly advertises the machine-readable surface.
    public static func detect(helpOutput: String) -> Self {
        let declaresStreamJSON = helpOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.lowercased() }
            .contains { $0.contains("--output-format") && $0.contains("stream-json") }
        guard declaresStreamJSON else {
            return .transcript(reason: "This Antigravity CLI does not advertise stream-json output.")
        }
        return .streamJSON
    }
}

public struct AntigravityProviderHealth: Sendable {
    public let installed: Bool
    public let protocolSupport: AntigravityCLIProtocol
    public let catalogStatus: ProviderCatalogStatus

    public init(installed: Bool, protocolSupport: AntigravityCLIProtocol, catalogStatus: ProviderCatalogStatus) {
        self.installed = installed
        self.protocolSupport = protocolSupport
        self.catalogStatus = catalogStatus
    }
}

/// Runs Antigravity's first-party non-interactive CLI surface. The harness probes
/// the executable's declared flags instead of assuming that Antigravity matches a
/// different Google CLI. Runtimes without stream-json remain explicitly degraded.
public final class AntigravityCLIHarness: @unchecked Sendable {
    private let executableURL: URL?
    private let processRegistry = InteractiveProcessRegistry()

    public init(executableURL: URL? = ExecutableDiscovery.locate("agy")) {
        self.executableURL = executableURL
    }

    public var isInstalled: Bool { executableURL != nil }

    public func models() async -> [ProviderModel] {
        await modelsResult().models
    }

    public func modelsResult() async -> ProviderCatalogResult<ProviderModel> {
        guard let executableURL else { return .unknown() }
        let result = await Self.run(executableURL, arguments: ["models"])
        guard result.isSuccess else { return ProviderCatalogResult(models: [], status: .failed) }
        let names = String(decoding: result.combinedOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let models = names.enumerated().map { index, name in
            ProviderModel(
                id: name,
                name: name,
                description: "Antigravity · first-party CLI",
                isDefault: index == 0
            )
        }
        return ProviderCatalogResult(models: models, succeeded: true)
    }

    public func protocolSupport() async -> AntigravityCLIProtocol {
        guard let executableURL else {
            return .transcript(reason: "Antigravity CLI is not installed.")
        }
        let result = await Self.run(executableURL, arguments: ["--help"], deadline: 2)
        guard result.isSuccess else {
            return .transcript(reason: "Antigravity protocol detection failed; structured output is unavailable.")
        }
        return .detect(helpOutput: String(decoding: result.combinedOutput, as: UTF8.self))
    }

    public func health() async -> AntigravityProviderHealth {
        guard executableURL != nil else {
            return AntigravityProviderHealth(
                installed: false,
                protocolSupport: .transcript(reason: "Antigravity CLI is not installed."),
                catalogStatus: .unknown
            )
        }
        async let protocolSupport = protocolSupport()
        async let catalog = modelsResult()
        return await AntigravityProviderHealth(
            installed: true,
            protocolSupport: protocolSupport,
            catalogStatus: catalog.status
        )
    }

    public func stream(
        prompt: String,
        sessionID: UUID,
        threadID: String? = nil,
        workspace: URL,
        model: String,
        policy: ExecutionPolicy
    ) -> AsyncStream<AgentEvent> {
        AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { continuation in
            let start = processRegistry.beginStart(for: sessionID)
            let commandID = HarnessToolEventDecoder.stableID(for: "antigravity:command:\(sessionID.uuidString)")
            continuation.yield(.sessionStarted(sessionID))
            continuation.yield(.harnessActivity(.init(
                id: commandID,
                provider: "Antigravity",
                title: "Starting Antigravity command",
                detail: "Checking the runtime protocol before launching print mode.",
                status: .running
            )))

            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    _ = processRegistry.abandonStart(start, sessionID: sessionID)
                    continuation.yield(.harnessActivity(.init(id: commandID, provider: "Antigravity", title: "Antigravity unavailable", detail: "The CLI executable is not installed.", status: .failed)))
                    continuation.yield(.failed("Antigravity CLI is not installed."))
                    continuation.finish()
                    return
                }

                let protocolSupport = await protocolSupport()
                if case .transcript(let reason) = protocolSupport {
                    continuation.yield(.harnessActivity(.init(
                        id: HarnessToolEventDecoder.stableID(for: "antigravity:protocol:\(sessionID.uuidString)"),
                        provider: "Antigravity",
                        title: "Antigravity structured events unavailable",
                        detail: "\(reason) Tool calls, provider permissions, and provider session IDs are unsupported on this run; output is transcript text.",
                        status: .degraded
                    )))
                } else {
                    continuation.yield(.harnessActivity(.init(
                        id: HarnessToolEventDecoder.stableID(for: "antigravity:permissions:\(sessionID.uuidString)"),
                        provider: "Antigravity",
                        title: "Antigravity permission events unsupported",
                        detail: policy == .yolo
                            ? "This run explicitly disables provider permission prompts."
                            : "The declared stream-json surface does not advertise interactive permission events, so Ask and Smart remain in provider plan mode.",
                        status: .unsupported
                    )))
                }

                var arguments = ["--print", "--model", model, "--sandbox"]
                if protocolSupport.isStructured {
                    arguments += ["--output-format", "stream-json"]
                    if let threadID, !threadID.isEmpty { arguments += ["--conversation", threadID] }
                }
                if policy == .yolo {
                    arguments += ["--mode", "accept-edits", "--dangerously-skip-permissions"]
                } else {
                    // Print mode cannot forward interactive provider permission requests.
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
                    mergeStandardError: !protocolSupport.isStructured
                )
                var owner: InteractiveProcessRegistry.Owner?
                do {
                    try transport.start()
                    guard case .accepted(let registeredOwner) = processRegistry.register(process: transport, input: nil, for: sessionID, start: start) else {
                        throw HarnessFailure("Antigravity request cancelled before process registration.")
                    }
                    owner = registeredOwner
                    continuation.yield(.harnessActivity(.init(id: commandID, provider: "Antigravity", title: "Antigravity command running", detail: protocolSupport.isStructured ? "Receiving provider JSONL events." : "Receiving degraded transcript output.", status: .running)))
                    try transport.write(promptData)
                    transport.closeInput()

                    let structuredTerminal: AgentEvent?
                    if protocolSupport.isStructured {
                        structuredTerminal = try Self.readStructuredEvents(from: transport, workspace: workspace, continuation: continuation)
                    } else {
                        while let data = try transport.readChunk() {
                            continuation.yield(.assistantDelta(String(decoding: data, as: UTF8.self)))
                        }
                        structuredTerminal = nil
                    }

                    let exitStatus = transport.waitForExit()
                    let result = processRegistry.unregister(registeredOwner, sessionID: sessionID)
                    if result.wasCancelled {
                        Self.yieldTerminal(.cancelled, commandID: commandID, continuation: continuation)
                    } else if transport.terminationReason == .timedOut {
                        Self.yieldTerminal(.failed("Antigravity timed out."), commandID: commandID, continuation: continuation)
                    } else if transport.terminationReason == .outputLimitExceeded {
                        Self.yieldTerminal(.failed("Antigravity output exceeded its limit."), commandID: commandID, continuation: continuation)
                    } else if exitStatus != 0 {
                        Self.yieldTerminal(.failed("Antigravity exited with status \(exitStatus ?? -1)."), commandID: commandID, continuation: continuation)
                    } else if protocolSupport.isStructured {
                        Self.yieldTerminal(structuredTerminal ?? .failed("Antigravity ended without a structured result event."), commandID: commandID, continuation: continuation)
                    } else {
                        Self.yieldTerminal(.completed, commandID: commandID, continuation: continuation)
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
                    let terminal: AgentEvent = wasCancelled || transport.terminationReason == .cancelled ? .cancelled : .failed(error.localizedDescription)
                    Self.yieldTerminal(terminal, commandID: commandID, continuation: continuation)
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

    public static func structuredEvent(
        from data: Data,
        workspace: URL,
        applicationSupportRoot: URL = LatticeApplicationSupport.productRootURL(),
        imageProbe: AssistantImageArtifactPolicy.FileProbe = .default
    ) -> [AgentEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [HarnessToolEventDecoder.malformedEvent(provider: "Antigravity", byteCount: data.count)]
        }
        guard let type = object["type"] as? String else {
            return [HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Structured event is missing type.")]
        }
        switch type {
        case "init":
            guard let session = object["session_id"] as? String, Self.isValidOpaqueID(session) else {
                return [HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Init event is missing session_id.")]
            }
            return [.harnessSessionStarted(session)]
        case "message":
            guard object["role"] as? String == "assistant" else { return [] }
            guard let content = object["content"] as? String else {
                return [HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Assistant message is missing content.")]
            }
            return [.assistantDelta(content)]
        case "tool_use":
            guard let externalID = object["tool_id"] as? String, Self.isValidOpaqueID(externalID),
                  let name = object["tool_name"] as? String, !name.isEmpty, name.count <= 160 else {
                return [HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Tool event is missing tool_id or tool_name.")]
            }
            let parameters = object["parameters"] as? [String: Any] ?? [:]
            let id = HarnessToolEventDecoder.stableID(for: "antigravity:\(externalID)")
            return [.toolRequested(.init(
                id: id,
                kind: Self.toolKind(name),
                title: "Antigravity is using \(name.replacingOccurrences(of: "_", with: " "))",
                detail: Self.toolDetail(parameters, fallback: name),
                workspaceScoped: WorkspacePathScope.isWorkspaceScoped(
                    rawInput: parameters,
                    locations: nil,
                    workspace: workspace
                ),
                reversible: false
            ))]
        case "tool_result":
            guard let externalID = object["tool_id"] as? String, Self.isValidOpaqueID(externalID),
                  let status = object["status"] as? String else {
                return [HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Tool result is missing tool_id or status.")]
            }
            let detail: String
            switch status {
            case "success": detail = "Completed"
            case "error", "failed": detail = "Failed"
            case "cancelled", "canceled": detail = "Cancelled"
            default:
                return [
                    .toolProgress(id: HarnessToolEventDecoder.stableID(for: "antigravity:\(externalID)"), fraction: 1, detail: "Failed"),
                    HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Tool result has unsupported status.")
                ]
            }
            var events: [AgentEvent] = [
                .toolProgress(id: HarnessToolEventDecoder.stableID(for: "antigravity:\(externalID)"), fraction: 1, detail: detail)
            ]
            // Only when the envelope already exposes an explicit typed image path field.
            // No Markdown parsing and no recursive path discovery.
            if status == "success",
               let artifactEvent = StructuredAssistantArtifactDecoder.toolResultArtifactEvent(
                   from: object,
                   provider: "Antigravity",
                   eventID: externalID,
                   workspace: workspace,
                   applicationSupportRoot: applicationSupportRoot,
                   probe: imageProbe
               ) {
                events.append(artifactEvent)
            }
            return events
        case "error":
            return [HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Provider reported a structured error.")]
        case "result":
            return []
        default:
            return [HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Unsupported structured event.")]
        }
    }

    private static func readStructuredEvents(
        from transport: BoundedProcessTransport,
        workspace: URL,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) throws -> AgentEvent? {
        var terminal: AgentEvent?
        while let line = try transport.readLine() {
            guard !line.isEmpty else { continue }
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            if let object, object["type"] as? String == "result" {
                guard let status = object["status"] as? String else {
                    continuation.yield(HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Result event is missing status."))
                    terminal = .failed("Antigravity returned a malformed structured result.")
                    continue
                }
                switch status {
                case "success": terminal = .completed
                case "cancelled", "canceled": terminal = .cancelled
                case "error", "failed": terminal = .failed("Antigravity reported a structured failure.")
                default:
                    continuation.yield(HarnessToolEventDecoder.diagnostic(provider: "Antigravity", object: object, reason: "Result event has unsupported status."))
                    terminal = .failed("Antigravity returned an unsupported structured result status.")
                }
                continue
            }
            for event in structuredEvent(from: line, workspace: workspace) { continuation.yield(event) }
        }
        return terminal
    }

    private static func yieldTerminal(
        _ event: AgentEvent,
        commandID: UUID,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) {
        let activity: HarnessActivityEvent
        switch event {
        case .completed:
            activity = .init(id: commandID, provider: "Antigravity", title: "Antigravity command completed", detail: "The provider process exited successfully.", status: .completed)
        case .cancelled:
            activity = .init(id: commandID, provider: "Antigravity", title: "Antigravity command cancelled", detail: "Lattice terminated the provider process.", status: .cancelled)
        case .failed(let message):
            activity = .init(id: commandID, provider: "Antigravity", title: "Antigravity command failed", detail: message, status: .failed)
        default:
            activity = .init(id: commandID, provider: "Antigravity", title: "Antigravity command failed", detail: "The provider returned an invalid terminal event.", status: .failed)
        }
        continuation.yield(.harnessActivity(activity))
        continuation.yield(event)
    }

    private static func toolKind(_ name: String) -> ToolRequest.Kind {
        let normalized = name.lowercased()
        if normalized.contains("credential") || normalized.contains("secret") || normalized.contains("password") || normalized.contains("token") || normalized.contains("keychain") { return .credential }
        if normalized.contains("write") || normalized.contains("edit") || normalized.contains("patch") { return .write }
        if normalized.contains("command") || normalized.contains("shell") || normalized.contains("bash") || normalized.contains("terminal") { return .command }
        if normalized.contains("search") || normalized.contains("web") || normalized.contains("fetch") { return .network }
        if normalized.contains("read") || normalized.contains("list") || normalized.contains("view") { return .read }
        return .unknown
    }

    private static func isValidOpaqueID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 256
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func toolDetail(_ parameters: [String: Any], fallback: String) -> String {
        if let command = parameters["command"] as? String, !command.isEmpty {
            return CLIActionStatusPolicy.redactedDetail("$ \(command)")
        }
        if let path = parameters["path"] as? String, !path.isEmpty {
            return CLIActionStatusPolicy.redactedDetail(path)
        }
        guard !parameters.isEmpty else { return fallback }
        return "Structured parameters: \(parameters.keys.sorted().prefix(24).joined(separator: ", ")) (values hidden)"
    }

    private func cancel(sessionID: UUID, start: InteractiveProcessRegistry.StartToken) {
        processRegistry.cancel(sessionID: sessionID, start: start).process?.cancel()
    }

    private static func run(_ executableURL: URL, arguments: [String], deadline: TimeInterval = 30) async -> BoundedSubprocessResult {
        await BoundedSubprocess.run(.init(
            executableURL: executableURL,
            arguments: arguments,
            deadline: deadline,
            maximumOutputBytes: BoundedSubprocessRequest.defaultMaximumOutputBytes
        ))
    }

    private struct HarnessFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
