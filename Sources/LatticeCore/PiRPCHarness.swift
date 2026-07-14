import Foundation

public final class PiRPCHarness: @unchecked Sendable {
    public struct PiProviderModel: Equatable, Sendable {
        public let provider: String
        public let model: String

        public init(provider: String, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    /// Complete child-process launch description. Secret values stay in
    /// `environment`; `arguments` never contains prompt or credential data.
    public struct LaunchPlan: Equatable, Sendable {
        public let executableURL: URL
        public let arguments: [String]
        public let piArguments: [String]
        public let currentDirectoryURL: URL
        public let environment: [String: String]
        public let sessionDirectory: URL
        public let agentDirectory: URL
        public let scratchDirectory: URL
        public let instructionFileURL: URL
        public let instructionEnvelope: LatticeInstructionEnvelope

        public var redactedArguments: [String] {
            PiRPCHarness.redact(arguments: arguments)
        }

        public var redactedEnvironment: [String: String] {
            PiRPCHarness.redact(environment: environment)
        }

        public var logSafeArguments: [String] { redactedArguments }
        public var logSafeEnvironment: [String: String] { redactedEnvironment }
    }

    public enum Error: LocalizedError, Equatable, Sendable {
        case invalidProviderOrModel
        case invalidEnvironmentOverride(String)
        case instructionEnvelopeModeMismatch
        case instructionEnvelopeTrustMismatch
        case permissionTimedOut

        public var errorDescription: String? {
            switch self {
            case .invalidProviderOrModel:
                "Pi provider and model must be non-empty."
            case .invalidEnvironmentOverride(let name):
                "Pi environment override is not allowed: \(name)."
            case .instructionEnvelopeModeMismatch:
                "Pi instruction envelope mode does not match launch mode."
            case .instructionEnvelopeTrustMismatch:
                "Pi instruction envelope trust does not match launch trust."
            case .permissionTimedOut:
                PermissionTimeout.message
            }
        }

        var text: String { errorDescription ?? "Pi launch failed." }
    }

    private final class PendingPermission: @unchecked Sendable {
        enum Decision: Sendable { case selected(String), cancelled }

        let sessionID: UUID
        let owner: InteractiveProcessRegistry.Owner
        let requestID: UUID
        private let waiter = PermissionWaiter<Decision>()

        init(sessionID: UUID, owner: InteractiveProcessRegistry.Owner, requestID: UUID) {
            self.sessionID = sessionID
            self.owner = owner
            self.requestID = requestID
        }

        @discardableResult
        func resolve(optionID: String?) -> Bool {
            waiter.resolve(optionID.map(Decision.selected) ?? .cancelled)
        }

        func wait(timeoutNanoseconds: UInt64) async -> PermissionWaitResult<Decision> {
            await withTaskCancellationHandler(operation: {
                await waiter.wait(timeoutNanoseconds: timeoutNanoseconds)
            }, onCancel: {
                _ = waiter.resolve(.cancelled)
            })
        }
    }

    private let executableURL: URL?
    private let permissionExtensionURL: URL?
    private let sandboxExecutableURL: URL?
    private let applicationSupportDirectory: URL?
    private let permissionTimeoutNanoseconds: UInt64
    private let lock = NSLock()
    private let processRegistry = InteractiveProcessRegistry()
    private var pendingPermissions: [UUID: PendingPermission] = [:]

    public init(
        executableURL: URL? = ExecutableDiscovery.locate("pi"),
        permissionExtensionURL: URL? = nil,
        sandboxExecutableURL: URL? = HarnessSandbox.systemExecutableURL,
        permissionTimeout: TimeInterval = 120,
        applicationSupportDirectory: URL? = nil
    ) {
        self.executableURL = executableURL
        self.permissionExtensionURL = permissionExtensionURL
        self.sandboxExecutableURL = sandboxExecutableURL
        self.permissionTimeoutNanoseconds = PermissionTimeout.nanoseconds(for: permissionTimeout)
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var isInstalled: Bool { executableURL != nil }

    public static func mapProviderModel(provider: String, model: String) -> PiProviderModel? {
        let rawProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawProvider.isEmpty, !rawModel.isEmpty else { return nil }

        let normalizedProvider = rawProvider.lowercased()
        if normalizedProvider == "codex" {
            return PiProviderModel(provider: "openai-codex", model: rawModel)
        }
        if normalizedProvider == "open-code" || normalizedProvider == "open_code" {
            return PiProviderModel(provider: "opencode", model: rawModel)
        }
        if normalizedProvider == "opencode", let separator = rawModel.firstIndex(of: "/") {
            let qualifiedProvider = String(rawModel[..<separator])
            let qualifiedModel = String(rawModel[rawModel.index(after: separator)...])
            if !qualifiedProvider.isEmpty, !qualifiedModel.isEmpty {
                return PiProviderModel(provider: qualifiedProvider, model: qualifiedModel)
            }
        }
        return PiProviderModel(provider: rawProvider, model: rawModel)
    }

    public static func providerModel(for route: ExecutionRoute) -> PiProviderModel? {
        guard route.mode == .code,
              route.runtimeID == "pi",
              let model = route.modelID else { return nil }
        switch route.providerID.lowercased() {
        case "codex", "opencode":
            return mapProviderModel(provider: route.providerID, model: model)
        default:
            return nil
        }
    }

    public static func redact(arguments: [String]) -> [String] {
        var redactNext = false
        return arguments.map { argument in
            if redactNext {
                redactNext = false
                return "<redacted>"
            }
            if ["--api-key", "OPENCODE_API_KEY"].contains(argument) {
                redactNext = true
                return argument
            }
            let uppercased = argument.uppercased()
            if uppercased.contains("API_KEY=") || uppercased.contains("TOKEN=") || uppercased.contains("SECRET=") {
                return "<redacted>"
            }
            return argument
        }
    }

    public static func redact(environment: [String: String]) -> [String: String] {
        environment.mapValues { value in value }
            .reduce(into: [String: String]()) { result, entry in
                let key = entry.key.uppercased()
                result[entry.key] = key.contains("API_KEY") || key.contains("TOKEN") || key.contains("SECRET") || key.contains("PASSWORD") || key.contains("AUTH")
                    ? "<redacted>"
                    : entry.value
            }
    }

    public func makeLaunchPlan(
        sessionID: UUID,
        threadID: String? = nil,
        workspace: URL,
        provider: String,
        model: String,
        reasoningEffort: ReasoningEffort? = nil,
        allowFileModification: Bool = false,
        mode: ConversationMode = .code,
        workspaceInstructionsTrusted: Bool = false,
        instructionEnvelope: LatticeInstructionEnvelope? = nil,
        openCodeAPIKey: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) throws -> LaunchPlan {
        guard let executableURL else {
            throw NSError(domain: "PiRPCHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Pi is not installed."])
        }
        guard let providerModel = Self.mapProviderModel(provider: provider, model: model) else {
            throw Error.invalidProviderOrModel
        }

        let canonicalWorkspace = try HarnessSandbox.canonicalDirectory(workspace)
        let sessionKey = sessionID.uuidString.lowercased()
        let sessionDirectory = productRootURL()
            .appendingPathComponent("HarnessSessions/Pi/\(sessionKey)", isDirectory: true)
        let agentDirectory = productRootURL()
            .appendingPathComponent("HarnessRuntime/Pi/\(sessionKey)", isDirectory: true)
        let scratchDirectory = productRootURL()
            .appendingPathComponent("HarnessScratch/Pi/\(sessionKey)/\(UUID().uuidString.lowercased())", isDirectory: true)
        var retainScratchDirectory = false
        defer {
            if !retainScratchDirectory {
                try? FileManager.default.removeItem(at: scratchDirectory)
            }
        }
        try Self.createPrivateDirectory(sessionDirectory)
        try Self.createPrivateDirectory(agentDirectory)
        try Self.createPrivateDirectory(scratchDirectory)

        let envelope = try instructionEnvelope ?? .default(
            mode: mode,
            workspace: canonicalWorkspace,
            allowFileModification: allowFileModification,
            workspaceInstructionsTrusted: workspaceInstructionsTrusted
        )
        guard envelope.selectedMode == mode else { throw Error.instructionEnvelopeModeMismatch }
        guard envelope.workspaceInstructionsTrusted == workspaceInstructionsTrusted else {
            throw Error.instructionEnvelopeTrustMismatch
        }

        let instructionFileURL = scratchDirectory.appendingPathComponent("lattice-instruction-envelope.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(envelope).write(to: instructionFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: instructionFileURL.path)

        let defaultExtensionURL = productRootURL()
            .appendingPathComponent("HarnessSupport/Pi/lattice-permission-gate.js")
        let extensionURL = try Self.installPermissionExtension(at: permissionExtensionURL ?? defaultExtensionURL)
        let tools = allowFileModification ? "read,grep,find,ls,write,edit,bash" : "read,grep,find,ls"
        let piSessionID = Self.piThreadID(from: threadID) ?? threadID ?? UUID().uuidString.lowercased()
        var piArguments = [
            "--mode", "rpc",
            "--session-dir", sessionDirectory.path,
            "--session-id", piSessionID,
            workspaceInstructionsTrusted ? "--approve" : "--no-approve"
        ]
        if !workspaceInstructionsTrusted {
            piArguments.append("--no-context-files")
        }
        piArguments += [
            "--no-extensions",
            "--no-skills",
            "--no-prompt-templates",
            "--no-themes",
            "--tools", tools,
            "--provider", providerModel.provider,
            "--model", providerModel.model,
            "--extension", extensionURL.path
        ]
        if let reasoningEffort, reasoningEffort != .none {
            piArguments += ["--thinking", Self.piThinkingLevel(reasoningEffort)]
        }

        var environment = Self.safeChildEnvironment(from: ProcessInfo.processInfo.environment)
        environment["LATTICE_PI_WORKSPACE"] = canonicalWorkspace.path
        environment["PI_CODING_AGENT_DIR"] = agentDirectory.path
        environment["PI_CODING_AGENT_SESSION_DIR"] = sessionDirectory.path
        environment["LATTICE_PI_INSTRUCTION_FILE"] = instructionFileURL.path
        environment["TMPDIR"] = scratchDirectory.path + "/"
        try Self.applyEnvironmentOverrides(environmentOverrides, to: &environment)
        if providerModel.provider.lowercased().hasPrefix("opencode") {
            if let openCodeAPIKey = openCodeAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !openCodeAPIKey.isEmpty {
                environment["OPENCODE_API_KEY"] = openCodeAPIKey
            }
        } else {
            environment.removeValue(forKey: "OPENCODE_API_KEY")
        }

        let writableDirectories = (allowFileModification ? [canonicalWorkspace] : []) + [sessionDirectory, agentDirectory, scratchDirectory]
        let launch = try HarnessSandbox.writeRestrictedLaunch(
            command: executableURL,
            arguments: piArguments,
            writableDirectories: writableDirectories,
            writablePaths: [Self.piSettingsLockURL(in: agentDirectory)],
            sandboxExecutableURL: sandboxExecutableURL
        )
        retainScratchDirectory = true
        return LaunchPlan(
            executableURL: launch.executableURL,
            arguments: launch.arguments,
            piArguments: piArguments,
            currentDirectoryURL: canonicalWorkspace,
            environment: environment,
            sessionDirectory: sessionDirectory,
            agentDirectory: agentDirectory,
            scratchDirectory: scratchDirectory,
            instructionFileURL: instructionFileURL,
            instructionEnvelope: envelope
        )
    }

    public func stream(
        prompt: String,
        sessionID: UUID,
        threadID: String?,
        workspace: URL,
        provider: String,
        model: String,
        reasoningEffort: ReasoningEffort?,
        allowFileModification: Bool = false,
        mode: ConversationMode = .code,
        workspaceInstructionsTrusted: Bool = false,
        instructionEnvelope: LatticeInstructionEnvelope? = nil,
        openCodeAPIKey: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let start = processRegistry.beginStart(for: sessionID)
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard executableURL != nil else {
                    _ = processRegistry.abandonStart(start, sessionID: sessionID)
                    continuation.yield(.failed("Pi is not installed.")); continuation.finish(); return
                }
                let piThreadID = Self.piThreadID(from: threadID) ?? UUID().uuidString.lowercased()
                var scratchDirectory: URL?
                var transport: BoundedProcessTransport?
                var owner: InteractiveProcessRegistry.Owner?
                do {
                    let canonicalWorkspace = try HarnessSandbox.canonicalDirectory(workspace)
                    let plan = try makeLaunchPlan(
                        sessionID: sessionID,
                        threadID: piThreadID,
                        workspace: canonicalWorkspace,
                        provider: provider,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        allowFileModification: allowFileModification,
                        mode: mode,
                        workspaceInstructionsTrusted: workspaceInstructionsTrusted,
                        instructionEnvelope: instructionEnvelope,
                        openCodeAPIKey: openCodeAPIKey,
                        environmentOverrides: environmentOverrides
                    )
                    scratchDirectory = plan.scratchDirectory
                    let runningTransport = BoundedProcessTransport(request: .init(
                        executableURL: plan.executableURL,
                        arguments: plan.arguments,
                        currentDirectoryURL: canonicalWorkspace,
                        environment: plan.environment,
                        deadline: 30 * 60,
                        maximumOutputBytes: 8_000_000
                    ))
                    transport = runningTransport
                    try runningTransport.start()
                    guard let registeredOwner = register(process: runningTransport, input: runningTransport.input, for: sessionID, start: start) else {
                        throw NSError(domain: "PiRPCHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pi request cancelled before process registration."])
                    }
                    owner = registeredOwner
                    continuation.yield(.harnessSessionStarted("pi:\(piThreadID)"))
                    try Self.write(["id": "prompt", "type": "prompt", "message": prompt], to: runningTransport)
                    let reader = BoundedJSONLineReader(runningTransport)
                    var finished = false
                    while !finished {
                        guard let object = try reader.next() else { break }
                        finished = try await parse(object, sessionID: sessionID, owner: registeredOwner, workspace: canonicalWorkspace, transport: runningTransport, continuation: continuation)
                    }
                    runningTransport.finish()
                    let didCancel = unregister(registeredOwner, start: start, sessionID: sessionID)
                    if didCancel { continuation.yield(.cancelled) }
                    else if !finished { continuation.yield(.failed("Pi ended before completing the response.")) }
                } catch {
                    let didCancel = unregister(owner, start: start, sessionID: sessionID)
                    transport?.cancel()
                    if didCancel || transport?.terminationReason == .cancelled { continuation.yield(.cancelled) }
                    else if transport?.terminationReason == .timedOut { continuation.yield(.failed("Pi timed out.")) }
                    else if transport?.terminationReason == .outputLimitExceeded { continuation.yield(.failed("Pi output exceeded its limit.")) }
                    else { continuation.yield(.failed((error as? PiRPCHarness.Error)?.text ?? error.localizedDescription)) }
                }
                if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
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
        cancel(processRegistry.cancel(sessionID: sessionID))
    }

    private func cancel(sessionID: UUID, start: InteractiveProcessRegistry.StartToken) {
        cancel(processRegistry.cancel(sessionID: sessionID, start: start))
    }

    private func cancel(_ target: InteractiveProcessRegistry.CancellationTarget) {
        let hadPermission = cancelPendingPermissions(target.metadata.pendingPermissionIDs)
        let stop = {
            try? Self.write(["type": "abort"], to: target.process)
            target.process?.cancel()
        }
        if hadPermission { DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: stop) }
        else { stop() }
    }

    @discardableResult
    public func respondToPermission(sessionID: UUID, requestID: UUID, optionID: String?) -> Bool {
        lock.lock(); let pending = pendingPermissions[requestID]; lock.unlock()
        guard pending?.sessionID == sessionID,
              optionID == nil || optionID == "allow_once" || optionID == "deny" else { return false }
        return pending?.resolve(optionID: optionID) == true
    }

    private func parse(_ object: [String: Any], sessionID: UUID, owner: InteractiveProcessRegistry.Owner, workspace: URL, transport: BoundedProcessTransport, continuation: AsyncStream<AgentEvent>.Continuation) async throws -> Bool {
        guard let type = object["type"] as? String else {
            continuation.yield(HarnessToolEventDecoder.diagnostic(provider: "Pi", object: object, reason: "Event is missing type."))
            return false
        }
        if type == "extension_ui_request" {
            guard object["id"] as? String != nil else { continuation.yield(HarnessToolEventDecoder.diagnostic(provider: "Pi", object: object, reason: "Extension UI request is missing id.")); return false }
            try await handleExtensionUIRequest(object, sessionID: sessionID, owner: owner, workspace: workspace, transport: transport, continuation: continuation)
            return false
        }
        if type == "extension_error" {
            let message = object["error"] as? String ?? "Pi's permission gate failed."
            continuation.yield(.failed("Pi permission gate failed: \(message)"))
            return true
        }
        if let event = HarnessToolEventDecoder.piEvent(from: object, workspace: workspace) {
            continuation.yield(event)
        }
        if type == "message_update",
           let update = object["assistantMessageEvent"] as? [String: Any],
           update["type"] as? String == "text_delta",
           let delta = update["delta"] as? String {
            continuation.yield(.assistantDelta(delta))
        } else if type == "message_update" {
            continuation.yield(HarnessToolEventDecoder.diagnostic(provider: "Pi", object: object, reason: "Message update is malformed."))
        }
        if type == "message_end",
           let message = object["message"] as? [String: Any],
           message["role"] as? String == "assistant",
           let error = message["errorMessage"] as? String, !error.isEmpty {
            continuation.yield(.failed(error))
            return true
        } else if type == "message_end" {
            continuation.yield(HarnessToolEventDecoder.diagnostic(provider: "Pi", object: object, reason: "Message end is malformed."))
        }
        if type == "agent_end" {
            if !processRegistry.isCancelled(owner, sessionID: sessionID) { continuation.yield(.completed) }
            return true
        }
        return false
    }

    private func register(process: BoundedProcessTransport, input: FileHandle, for id: UUID, start: InteractiveProcessRegistry.StartToken) -> InteractiveProcessRegistry.Owner? {
        guard case .accepted(let owner) = processRegistry.register(process: process, input: input, for: id, start: start) else { return nil }
        lock.lock()
        let stale = pendingPermissions.values.filter { $0.sessionID == id }
        pendingPermissions = pendingPermissions.filter { $0.value.sessionID != id }
        lock.unlock()
        stale.forEach { _ = $0.resolve(optionID: nil) }
        return owner
    }

    private func register(_ pending: PendingPermission) {
        guard processRegistry.registerPendingPermission(
            pending.requestID,
            owner: pending.owner,
            sessionID: pending.sessionID
        ) else {
            _ = pending.resolve(optionID: nil)
            return
        }
        lock.lock()
        pendingPermissions[pending.requestID] = pending
        lock.unlock()
        guard processRegistry.isPendingPermissionActive(
            pending.requestID,
            owner: pending.owner,
            sessionID: pending.sessionID
        ) else {
            lock.lock()
            if pendingPermissions[pending.requestID] === pending {
                pendingPermissions[pending.requestID] = nil
            }
            lock.unlock()
            processRegistry.updateMetadata(pending.owner, sessionID: pending.sessionID) {
                $0.pendingPermissionIDs.remove(pending.requestID)
            }
            _ = pending.resolve(optionID: nil)
            return
        }
    }

    private func removePendingPermission(_ requestID: UUID, owner: InteractiveProcessRegistry.Owner, sessionID: UUID) {
        processRegistry.updateMetadata(owner, sessionID: sessionID) {
            $0.pendingPermissionIDs.remove(requestID)
        }
        lock.lock(); pendingPermissions[requestID] = nil; lock.unlock()
    }

    private func unregister(_ owner: InteractiveProcessRegistry.Owner?, start: InteractiveProcessRegistry.StartToken, sessionID id: UUID) -> Bool {
        guard let owner else { return processRegistry.abandonStart(start, sessionID: id) }
        let result = processRegistry.unregister(owner, sessionID: id)
        guard result.removedCurrentOwner else { return result.wasCancelled }
        lock.lock()
        let pending = result.metadata.pendingPermissionIDs.compactMap { pendingPermissions.removeValue(forKey: $0) }
        lock.unlock()
        pending.forEach { _ = $0.resolve(optionID: nil) }
        return result.wasCancelled
    }

    private func handleExtensionUIRequest(_ object: [String: Any], sessionID: UUID, owner: InteractiveProcessRegistry.Owner, workspace: URL, transport: BoundedProcessTransport, continuation: AsyncStream<AgentEvent>.Continuation) async throws {
        guard let externalID = object["id"] as? String else { return }
        guard object["method"] as? String == "confirm",
              let request = Self.permissionRequest(from: object, workspace: workspace) else {
            try Self.write(["type": "extension_ui_response", "id": externalID, "cancelled": true], to: transport)
            return
        }
        let pending = PendingPermission(sessionID: sessionID, owner: owner, requestID: request.id)
        register(pending)
        continuation.yield(.permissionRequested(request))
        let result = await pending.wait(timeoutNanoseconds: permissionTimeoutNanoseconds)
        removePendingPermission(request.id, owner: owner, sessionID: sessionID)
        switch result {
        case .resolved(.selected("allow_once")):
            try Self.writeControl(["type": "extension_ui_response", "id": externalID, "confirmed": true], to: transport)
        case .resolved(.selected):
            try Self.writeControl(["type": "extension_ui_response", "id": externalID, "confirmed": false], to: transport)
        case .resolved(.cancelled):
            try Self.writeControl(["type": "extension_ui_response", "id": externalID, "cancelled": true], to: transport)
        case .timedOut:
            try? Self.writeControl(["type": "extension_ui_response", "id": externalID, "cancelled": true], to: transport)
            throw Error.permissionTimedOut
        }
    }

    private func cancelPendingPermissions(_ requestIDs: Set<UUID>) -> Bool {
        lock.lock(); let pending = requestIDs.compactMap { pendingPermissions[$0] }; lock.unlock()
        pending.forEach { $0.resolve(optionID: nil) }
        return !pending.isEmpty
    }

    public static func permissionRequest(from object: [String: Any], workspace: URL) -> ApprovalRequest? {
        guard object["type"] as? String == "extension_ui_request",
              object["method"] as? String == "confirm",
              let message = object["message"] as? String,
              let data = message.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = payload["toolName"] as? String,
              ["write", "edit", "bash"].contains(toolName),
              let rawInput = payload["input"] as? [String: Any] else { return nil }
        let detail = permissionDetail(toolName: toolName, input: rawInput)
        let path = rawInput["path"] as? String
        let workspaceScoped = path.map { WorkspacePathScope.isWorkspaceScoped($0, workspace: workspace) } ?? false
        let kind: ToolRequest.Kind = toolName == "bash" ? .command : .write
        let toolRequest = ToolRequest(kind: kind, title: "Pi wants to use \(toolName)", detail: detail, workspaceScoped: workspaceScoped, reversible: false)
        return ApprovalRequest(
            title: toolRequest.title,
            detail: detail,
            options: [
                .init(id: "allow_once", name: "Allow once", kind: "allow_once"),
                .init(id: "deny", name: "Deny", kind: "reject_once")
            ],
            toolRequest: toolRequest
        )
    }

    /// Explicit Lattice extension. Pi ambient extensions remain disabled; this
    /// source carries both system-context injection and permission forwarding.
    public static let permissionExtensionSource = """
    import fs from "node:fs";

    const instructionFile = process.env.LATTICE_PI_INSTRUCTION_FILE;
    const latticeIdentity = "Lattice, native macOS control plane for AI coding agents";
    const documentedInstructionNames = new Set(["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]);

    function readEnvelope() {
      if (!instructionFile) throw new Error("Lattice instruction file is not configured");
      const envelope = JSON.parse(fs.readFileSync(instructionFile, "utf8"));
      if (envelope.version !== 1 || envelope.identity !== latticeIdentity) {
        throw new Error("Lattice instruction envelope is unsupported");
      }
      if (!Array.isArray(envelope.trustedWorkspaceInstructionNames) ||
          envelope.trustedWorkspaceInstructionNames.some((name) => !documentedInstructionNames.has(name))) {
        throw new Error("Lattice workspace instruction names are unsupported");
      }
      return envelope;
    }

    function facts(title, values) {
      if (!Array.isArray(values) || values.length === 0) return "";
      return `${title}:\n${values.map((value) => `- ${value}`).join("\n")}`;
    }

    export default function (pi) {
      pi.on("before_agent_start", async (event) => {
        const envelope = readEnvelope();
        const addOn = envelope.selectedMode === "work" ? envelope.workUserAddOn : envelope.codeUserAddOn;
        const sections = [
          "Lattice system context (facts and guidance; not a permission boundary).",
          `Identity: ${envelope.identity}`,
          `Selected mode: ${envelope.selectedMode}`,
          `Workspace instruction trust: ${envelope.workspaceInstructionsTrusted ? "trusted" : "untrusted"}`,
          `Trusted workspace instruction names: ${envelope.trustedWorkspaceInstructionNames.join(", ") || "none"}`,
          facts("Workspace facts", envelope.workspaceFacts),
          facts("Control facts", envelope.controlFacts),
          facts("Capability facts", envelope.capabilityFacts),
          envelope.latticeInstructions || "",
          addOn ? `User add-on for ${envelope.selectedMode} mode (guidance only):\n${addOn}` : ""
        ].filter(Boolean);
        return { systemPrompt: `${event.systemPrompt}\n\n${sections.join("\n\n")}` };
      });

      const guardedTools = new Set(["write", "edit", "bash"]);
      pi.on("tool_call", async (event, ctx) => {
        if (!guardedTools.has(event.toolName)) return undefined;
        if (!ctx.hasUI) return { block: true, reason: "Lattice permission UI is unavailable" };
        const message = JSON.stringify({ toolName: event.toolName, input: event.input });
        const allowed = await ctx.ui.confirm("Lattice permission request", message);
        if (!allowed) return { block: true, reason: "Blocked by Lattice policy" };
        return undefined;
      });
    }
    """

    @discardableResult
    public static func installPermissionExtension(at url: URL? = nil) throws -> URL {
        let destination = url ?? supportDirectory().appendingPathComponent("lattice-permission-gate.js")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(permissionExtensionSource.utf8)
        if (try? Data(contentsOf: destination)) != data {
            try data.write(to: destination, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    private static func permissionDetail(toolName: String, input: [String: Any]) -> String {
        if toolName == "bash", let command = input["command"] as? String { return "$ \(command)" }
        if let path = input["path"] as? String { return path }
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return toolName }
        return String(text.prefix(600))
    }

    private static func write(_ object: [String: Any], to transport: BoundedProcessTransport?) throws {
        guard let transport else { return }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try transport.write(data)
    }

    private static func writeControl(_ object: [String: Any], to transport: BoundedProcessTransport) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try transport.writeControl(data)
    }

    private static func piThinkingLevel(_ effort: ReasoningEffort) -> String {
        switch effort {
        case .none, .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh, .max: "xhigh"
        case .thinking: "medium"
        }
    }

    private static func piThreadID(from value: String?) -> String? {
        guard let value, value.hasPrefix("pi:") else { return nil }
        let id = String(value.dropFirst("pi:".count))
        return id.isEmpty ? nil : id
    }

    private func productRootURL() -> URL {
        if let applicationSupportDirectory {
            return applicationSupportDirectory.appendingPathComponent(LatticeApplicationSupport.productFolderName, isDirectory: true)
        }
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        return LatticeApplicationSupport.productRootURL()
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func applyEnvironmentOverrides(_ overrides: [String: String], to environment: inout [String: String]) throws {
        let allowed = Set(["PI_OFFLINE", "PI_TELEMETRY"])
        let reserved = Set([
            "LATTICE_PI_WORKSPACE",
            "LATTICE_PI_INSTRUCTION_FILE",
            "PI_CODING_AGENT_DIR",
            "PI_CODING_AGENT_SESSION_DIR",
            "TMPDIR",
            "OPENCODE_API_KEY"
        ])
        for (name, value) in overrides {
            guard allowed.contains(name), !reserved.contains(name) else {
                throw Error.invalidEnvironmentOverride(name)
            }
            environment[name] = value
        }
    }

    private static func supportDirectory() -> URL {
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        return LatticeApplicationSupport.productRootURL().appendingPathComponent("HarnessSupport/Pi", isDirectory: true)
    }

    private static func safeChildEnvironment(from base: [String: String]) -> [String: String] {
        let safeKeys = [
            "PATH", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TERM",
            "TERM_PROGRAM", "DISPLAY", "WAYLAND_DISPLAY"
        ]
        return safeKeys.reduce(into: [String: String]()) { environment, key in
            environment[key] = base[key]
        }
    }

    private static func piSettingsLockURL(in agentDirectory: URL) -> URL {
        agentDirectory.appendingPathComponent("settings.json.lock")
    }
}
