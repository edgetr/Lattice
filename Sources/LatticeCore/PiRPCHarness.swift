import Foundation

public final class PiRPCHarness: @unchecked Sendable {
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

    public func stream(prompt: String, sessionID: UUID, threadID: String?, workspace: URL, provider: String, model: String, reasoningEffort: ReasoningEffort?, allowFileModification: Bool = false) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let start = processRegistry.beginStart(for: sessionID)
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    continuation.yield(.failed("Pi is not installed.")); continuation.finish(); return
                }
                let tools = allowFileModification ? "read,grep,find,ls,write,edit,bash" : "read,grep,find,ls"
                let piThreadID = Self.piThreadID(from: threadID) ?? UUID().uuidString.lowercased()
                let sessionDirectory = sessionDirectory()
                let scratchDirectory = scratchDirectory(for: sessionID)
                var transport: BoundedProcessTransport?
                var owner: InteractiveProcessRegistry.Owner?
                do {
                    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
                    let canonicalWorkspace = try HarnessSandbox.canonicalDirectory(workspace)
                    var arguments = ["--mode", "rpc", "--session-dir", sessionDirectory.path, "--session-id", piThreadID, "--no-approve", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--tools", tools, "--provider", provider, "--model", model]
                    if allowFileModification {
                        let extensionURL = try permissionExtensionURL ?? Self.installPermissionExtension()
                        arguments += ["--extension", extensionURL.path]
                    }
                    if let reasoningEffort, reasoningEffort != .none {
                        arguments += ["--thinking", Self.piThinkingLevel(reasoningEffort)]
                    }
                    let launch = try HarnessSandbox.writeRestrictedLaunch(
                        command: executableURL,
                        arguments: arguments,
                        writableDirectories: (allowFileModification ? [canonicalWorkspace] : []) + [sessionDirectory, scratchDirectory],
                        writablePaths: [Self.piSettingsLockURL()],
                        sandboxExecutableURL: sandboxExecutableURL
                    )
                    var environment = ProcessInfo.processInfo.environment
                    environment["LATTICE_PI_WORKSPACE"] = canonicalWorkspace.path
                    // Keep legacy env for older Pi helper tooling that still reads NISA_*.
                    environment["NISA_PI_WORKSPACE"] = canonicalWorkspace.path
                    environment["TMPDIR"] = scratchDirectory.path + "/"
                    let runningTransport = BoundedProcessTransport(request: .init(
                        executableURL: launch.executableURL,
                        arguments: launch.arguments,
                        currentDirectoryURL: canonicalWorkspace,
                        environment: environment,
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
                    else { continuation.yield(.failed((error as? PiHarnessError)?.text ?? error.localizedDescription)) }
                }
                try? FileManager.default.removeItem(at: scratchDirectory)
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
            try Self.write(["type": "extension_ui_response", "id": externalID, "confirmed": true], to: transport)
        case .resolved(.selected):
            try Self.write(["type": "extension_ui_response", "id": externalID, "confirmed": false], to: transport)
        case .resolved(.cancelled):
            try Self.write(["type": "extension_ui_response", "id": externalID, "cancelled": true], to: transport)
        case .timedOut:
            try? Self.write(["type": "extension_ui_response", "id": externalID, "cancelled": true], to: transport)
            throw PiHarnessError.permissionTimedOut
        }
    }

    private func cancelPendingPermissions(_ requestIDs: Set<UUID>) -> Bool {
        lock.lock(); let pending = requestIDs.compactMap { pendingPermissions[$0] }; lock.unlock()
        pending.forEach { $0.resolve(optionID: nil) }
        return !pending.isEmpty
    }

    private enum PiHarnessError: Error {
        case permissionTimedOut

        var text: String {
            switch self {
            case .permissionTimedOut: PermissionTimeout.message
            }
        }
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

    public static let permissionExtensionSource = """
    export default function (pi) {
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

    private func sessionDirectory() -> URL {
        productRootURL().appendingPathComponent("HarnessSessions/Pi", isDirectory: true)
    }

    private static func supportDirectory() -> URL {
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        return LatticeApplicationSupport.productRootURL().appendingPathComponent("HarnessSupport/Pi", isDirectory: true)
    }

    private func scratchDirectory(for sessionID: UUID) -> URL {
        productRootURL().appendingPathComponent("HarnessScratch/Pi/\(sessionID.uuidString.lowercased())", isDirectory: true)
    }

    private static func piSettingsLockURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/settings.json.lock", isDirectory: true)
    }
}
