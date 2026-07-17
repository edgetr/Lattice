import Foundation

private enum CodexHarnessError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

public struct CodexAppServerCapabilities: Sendable, Equatable {
    public enum Support: String, Sendable, Equatable {
        case unknown
        case supported
        case unsupported
    }

    public let serverIdentity: String?
    public let protocolVersion: String?
    public let modelCatalog: Support
    public let usage: Support
    public let providerTools: Support
    public let threadResume: Support
    public let approvals: Support
    public let imageInput: Support

    public init(
        serverIdentity: String? = nil,
        protocolVersion: String? = nil,
        modelCatalog: Support = .unknown,
        usage: Support = .unknown,
        providerTools: Support = .unknown,
        threadResume: Support = .unknown,
        approvals: Support = .unknown,
        imageInput: Support = .unknown
    ) {
        self.serverIdentity = serverIdentity
        self.protocolVersion = protocolVersion
        self.modelCatalog = modelCatalog
        self.usage = usage
        self.providerTools = providerTools
        self.threadResume = threadResume
        self.approvals = approvals
        self.imageInput = imageInput
    }
}

private final class CodexProtocolTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var didTimeOut = false

    func finish() { lock.withLock { active = false } }

    func fire(_ transport: BoundedProcessTransport) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard active else { return false }
            didTimeOut = true
            active = false
            return true
        }
        if shouldCancel { transport.cancel() }
    }

    var timedOut: Bool { lock.withLock { didTimeOut } }
}

public final class CodexExecHarness: @unchecked Sendable {
    private final class PendingPermission: @unchecked Sendable {
        enum Decision: Sendable {
            case selected(String)
            case cancelled
        }

        let sessionID: UUID
        let owner: InteractiveProcessRegistry.Owner
        let requestID: UUID
        let serverRequestID: Any
        let allowedDecisions: Set<String>
        private let waiter = PermissionWaiter<Decision>()

        init(sessionID: UUID, owner: InteractiveProcessRegistry.Owner, requestID: UUID, serverRequestID: Any, allowedDecisions: Set<String>) {
            self.sessionID = sessionID
            self.owner = owner
            self.requestID = requestID
            self.serverRequestID = serverRequestID
            self.allowedDecisions = allowedDecisions
        }

        func resolve(_ decision: String?) -> Bool {
            if let decision {
                guard allowedDecisions.contains(decision) else { return false }
                return waiter.resolve(.selected(decision))
            }
            return waiter.resolve(.cancelled)
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
    private let permissionTimeoutNanoseconds: UInt64
    private let protocolTimeout: TimeInterval
    private let lock = NSLock()
    private let processRegistry = InteractiveProcessRegistry()
    private var pendingPermissions: [UUID: PendingPermission] = [:]

    public init(
        executableURL: URL? = ExecutableDiscovery.locate("codex"),
        permissionTimeout: TimeInterval = 120,
        protocolTimeout: TimeInterval = 8
    ) {
        self.executableURL = executableURL
        self.permissionTimeoutNanoseconds = PermissionTimeout.nanoseconds(for: permissionTimeout)
        self.protocolTimeout = max(0.01, protocolTimeout)
    }

    public var isInstalled: Bool { executableURL != nil }

    public func isAuthenticated() async -> Bool {
        guard let executableURL else { return false }
        return await Self.run(executableURL, arguments: ["login", "-c", "service_tier=\"flex\"", "status"]).isSuccess
    }

    public func login() async -> Bool {
        guard let executableURL else { return false }
        return await Self.run(executableURL, arguments: ["login", "-c", "service_tier=\"flex\""]).isSuccess
    }

    public func updateCLI() async -> Bool {
        guard let executableURL else { return false }
        return await Self.run(executableURL, arguments: ["update"]).isSuccess
    }

    public func cliVersion() async -> String? {
        guard let executableURL else { return nil }
        let result = await Self.run(executableURL, arguments: ["--version"])
        guard result.isSuccess else { return nil }
        let value = String(decoding: result.combinedOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let version = value.split(separator: " ").last { return String(version) }
        return value
    }

    public func providerSnapshot() async -> CodexProviderSnapshot {
        guard let executableURL else { return .empty }
        let timeout = protocolTimeout
        return await BoundedSubprocess.performOffCooperativeExecutor {
            let transport = BoundedProcessTransport(request: .init(
                executableURL: executableURL,
                arguments: ["app-server", "-c", "service_tier=\"flex\""],
                environment: ChildProcessEnvironmentPolicy.providerOwnedRuntime(),
                deadline: timeout,
                maximumOutputBytes: 4_000_000
            ))
            do {
                try transport.start()
                let reader = BoundedJSONLineReader(transport)
                try Self.write(Self.initializeRequest(id: 0), to: transport)
                let initialize = try Self.readProbeResponse(id: 0, from: reader)
                var capabilities = try Self.negotiatedCapabilities(from: initialize)
                try Self.write(["method": "initialized", "params": [:]], to: transport)
                try Self.write(["method": "model/list", "id": 1, "params": ["includeHidden": false, "limit": 100]], to: transport)
                try Self.write(["method": "modelProvider/capabilities/read", "id": 2, "params": [:]], to: transport)
                try Self.write(["method": "account/rateLimits/read", "id": 3, "params": [:]], to: transport)
                var responses: [Int: [String: Any]] = [:]
                while responses.count < 3, let object = try reader.next() {
                    guard object["method"] == nil, let id = (object["id"] as? NSNumber)?.intValue, (1...3).contains(id) else { continue }
                    responses[id] = object
                }
                transport.finish()
                let modelResponse = responses[1]
                let toolsResponse = responses[2]
                let usageResponse = responses[3]
                let modelSupport = Self.probeSupport(modelResponse) { result in result["data"] is [[String: Any]] }
                let toolSupport = Self.probeSupport(toolsResponse) { result in
                    result["webSearch"] is Bool
                        && result["imageGeneration"] is Bool
                        && result["namespaceTools"] is Bool
                }
                let usageSupport = Self.probeSupport(usageResponse) { result in result["rateLimits"] is [String: Any] }
                capabilities = .init(
                    serverIdentity: capabilities.serverIdentity,
                    protocolVersion: capabilities.protocolVersion,
                    modelCatalog: modelSupport,
                    usage: usageSupport,
                    providerTools: toolSupport,
                    threadResume: capabilities.threadResume,
                    approvals: capabilities.approvals,
                    imageInput: Self.imageInputSupport(modelResponse)
                )
                let models = modelSupport == .supported ? Self.parseModels(modelResponse ?? [:]) : []
                let usage = usageSupport == .supported ? Self.parseUsage(usageResponse ?? [:]) : nil
                return CodexProviderSnapshot(
                    models: models,
                    usage: usage,
                    catalogStatus: .resolved(modelCount: models.count, succeeded: modelSupport == .supported),
                    capabilities: capabilities,
                    unavailableReason: Self.modelCatalogUnavailableReason(for: modelSupport)
                )
            } catch {
                transport.cancel()
                return CodexProviderSnapshot(
                    models: [],
                    usage: nil,
                    catalogStatus: .failed,
                    unavailableReason: transport.terminationReason == .timedOut
                        ? "Codex app-server protocol negotiation timed out. Retry or update Codex."
                        : error.localizedDescription
                )
            }
        }
    }

    public func stream(prompt: String, sessionID: UUID, threadID: String?, workspace: URL, model: String, reasoningEffort: ReasoningEffort? = nil, policy: ExecutionPolicy = .ask, workspaceWrite: Bool = false, developerInstructions: String? = nil, attachments: [ContextAttachment] = [], imageInputCapability: ImageInputCapability = .init(support: .unknown)) -> AsyncStream<AgentEvent> {
        AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { continuation in
            if let reason = ExecutionInputAttachmentPolicy.unavailableReason(
                attachments: attachments,
                capability: imageInputCapability
            ) {
                continuation.yield(.failed(reason))
                continuation.finish()
                return
            }
            let start = processRegistry.beginStart(for: sessionID)
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    _ = processRegistry.abandonStart(start, sessionID: sessionID)
                    continuation.yield(.failed("Codex is not installed.")); continuation.finish(); return
                }
                let transport = BoundedProcessTransport(request: .init(
                    executableURL: executableURL,
                    arguments: ["app-server", "-c", "service_tier=\"flex\""],
                    currentDirectoryURL: workspace,
                    environment: ChildProcessEnvironmentPolicy.providerOwnedRuntime(),
                    deadline: 30 * 60,
                    maximumOutputBytes: 8_000_000
                ))
                var owner: InteractiveProcessRegistry.Owner?
                let handshakeTimeout = CodexProtocolTimeout()
                var handshakeCompleted = false
                do {
                    try transport.start()
                    guard let registeredOwner = register(process: transport, input: transport.input, for: sessionID, start: start) else {
                        throw CodexHarnessError.message("Codex request cancelled before process registration.")
                    }
                    owner = registeredOwner
                    let reader = BoundedJSONLineReader(transport)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + protocolTimeout) {
                        handshakeTimeout.fire(transport)
                    }
                    try Self.write(Self.initializeRequest(id: 1), to: transport)
                    let initializeResponse = try await readResponse(id: 1, sessionID: sessionID, owner: registeredOwner, from: reader, transport: transport, continuation: continuation)
                    _ = try Self.negotiatedCapabilities(from: initializeResponse)
                    handshakeCompleted = true
                    handshakeTimeout.finish()
                    try Self.write(["method": "initialized", "params": [:]], to: transport)

                    let route = Self.executionRoute(policy: policy, workspaceWrite: workspaceWrite)
                    let method = threadID == nil ? "thread/start" : "thread/resume"
                    var threadParams: [String: Any] = [
                        "model": model,
                        "serviceTier": "flex",
                        "cwd": workspace.path,
                        "runtimeWorkspaceRoots": [workspace.path],
                        "approvalPolicy": route.approvalPolicy,
                        "approvalsReviewer": "user",
                        "sandbox": route.sandbox
                    ]
                    if let developerInstructions = developerInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !developerInstructions.isEmpty {
                        threadParams["developerInstructions"] = developerInstructions
                    }
                    if let threadID { threadParams["threadId"] = threadID }
                    try Self.write(["method": method, "id": 2, "params": threadParams], to: transport)
                    let threadResponse = try await readResponse(id: 2, sessionID: sessionID, owner: registeredOwner, from: reader, transport: transport, continuation: continuation)
                    if Self.isUnsupportedMethod(threadResponse), threadID != nil {
                        throw CodexHarnessError.message("This Codex app-server cannot resume existing threads. Update Codex or start a new chat.")
                    }
                    guard let result = threadResponse["result"] as? [String: Any],
                          let activeThreadID = Self.threadID(from: result) else {
                        throw CodexHarnessError.message(Self.responseError(threadResponse, fallback: "Codex did not return a thread ID."))
                    }
                    try Self.validateEffectiveRoute(result, requested: route)
                    setThreadID(activeThreadID, owner: registeredOwner, for: sessionID)
                    continuation.yield(.harnessSessionStarted(activeThreadID))

                    var turnParams: [String: Any] = [
                        "threadId": activeThreadID,
                        "input": Self.turnInput(prompt: prompt, attachments: attachments),
                        "cwd": workspace.path,
                        "runtimeWorkspaceRoots": [workspace.path],
                        "model": model,
                        "serviceTier": "flex",
                        "approvalPolicy": route.approvalPolicy
                    ]
                    if let reasoningEffort, reasoningEffort != .none {
                        turnParams["effort"] = reasoningEffort.rawValue
                        turnParams["summary"] = "auto"
                    }
                    try Self.write(["method": "turn/start", "id": 3, "params": turnParams], to: transport)
                    let turnResponse = try await readResponse(id: 3, sessionID: sessionID, owner: registeredOwner, from: reader, transport: transport, continuation: continuation)
                    guard let turnResult = turnResponse["result"] as? [String: Any],
                          let turnID = Self.turnID(from: turnResult) else {
                        throw CodexHarnessError.message(Self.responseError(turnResponse, fallback: "Codex did not start the turn."))
                    }
                    setTurnID(turnID, owner: registeredOwner, for: sessionID)
                    let turnReportedCancellation = try await readTurn(sessionID: sessionID, owner: registeredOwner, workspace: workspace, from: reader, transport: transport, continuation: continuation)
                    transport.finish()
                    let didCancel = unregister(registeredOwner, start: start, sessionID: sessionID)
                    if didCancel && !turnReportedCancellation { continuation.yield(.cancelled) }
                } catch {
                    handshakeTimeout.finish()
                    let didCancel = unregister(owner, start: start, sessionID: sessionID)
                    let terminationReason = transport.terminationReason
                    transport.cancel()
                    if handshakeTimeout.timedOut { continuation.yield(.failed("Codex app-server protocol negotiation timed out. Retry or update Codex.")) }
                    else if !handshakeCompleted {
                        let detail = error.localizedDescription
                        let message = detail.contains("Update Codex")
                            ? detail
                            : "Codex returned a malformed protocol handshake: \(detail) Update Codex and retry."
                        continuation.yield(.failed(message))
                    }
                    else if didCancel || terminationReason == .cancelled { continuation.yield(.cancelled) }
                    else if terminationReason == .timedOut { continuation.yield(.failed("Codex timed out.")) }
                    else if terminationReason == .outputLimitExceeded { continuation.yield(.failed("Codex output exceeded its limit.")) }
                    else { continuation.yield(.failed(error.localizedDescription)) }
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
        cancel(processRegistry.cancel(sessionID: sessionID))
    }

    private func cancel(sessionID: UUID, start: InteractiveProcessRegistry.StartToken) {
        cancel(processRegistry.cancel(sessionID: sessionID, start: start))
    }

    private func cancel(_ target: InteractiveProcessRegistry.CancellationTarget) {
        let threadID = target.metadata.threadID
        let turnID = target.metadata.turnID
        lock.lock()
        let pending = target.metadata.pendingPermissionIDs.compactMap { pendingPermissions[$0] }
        lock.unlock()
        pending.forEach { _ = $0.resolve(nil) }
        if let process = target.process, let threadID, let turnID {
            try? Self.write(["method": "turn/interrupt", "id": 99, "params": ["threadId": threadID, "turnId": turnID]], to: process)
            target.process?.cancel(after: 0.35)
        } else { target.process?.cancel() }
    }

    @discardableResult
    public func respondToPermission(sessionID: UUID, requestID: UUID, optionID: String?) -> Bool {
        lock.lock(); let pending = pendingPermissions[requestID]; lock.unlock()
        guard pending?.sessionID == sessionID else { return false }
        return pending?.resolve(optionID) == true
    }

    private func register(process: BoundedProcessTransport, input: FileHandle, for id: UUID, start: InteractiveProcessRegistry.StartToken) -> InteractiveProcessRegistry.Owner? {
        guard case .accepted(let owner) = processRegistry.register(process: process, input: input, for: id, start: start) else { return nil }
        lock.lock()
        let stale = pendingPermissions.values.filter { $0.sessionID == id }
        pendingPermissions = pendingPermissions.filter { $0.value.sessionID != id }
        lock.unlock()
        stale.forEach { _ = $0.resolve(nil) }
        return owner
    }

    private func setThreadID(_ threadID: String, owner: InteractiveProcessRegistry.Owner, for id: UUID) {
        processRegistry.updateMetadata(owner, sessionID: id) { $0.threadID = threadID }
    }

    private func setTurnID(_ turnID: String, owner: InteractiveProcessRegistry.Owner, for id: UUID) {
        processRegistry.updateMetadata(owner, sessionID: id) { $0.turnID = turnID }
    }

    private func register(_ pending: PendingPermission) {
        guard processRegistry.registerPendingPermission(
            pending.requestID,
            owner: pending.owner,
            sessionID: pending.sessionID
        ) else {
            _ = pending.resolve(nil)
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
            _ = pending.resolve(nil)
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
        pending.forEach { _ = $0.resolve(nil) }
        return result.wasCancelled
    }

    private static func initializeRequest(id: Int) -> [String: Any] {
        ["method": "initialize", "id": id, "params": [
            "clientInfo": ["name": "lattice", "title": "Lattice", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]
        ]]
    }

    static func negotiatedCapabilities(from response: [String: Any]) throws -> CodexAppServerCapabilities {
        if response["error"] != nil {
            let detail = responseError(response, fallback: "The initialize request was rejected.")
            throw CodexHarnessError.message("Codex app-server protocol negotiation failed: \(detail) Update Codex and retry.")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw CodexHarnessError.message("Codex returned a malformed protocol handshake. Update Codex and retry.")
        }
        let identity = (result["userAgent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version: String? = {
            if let value = result["protocolVersion"] as? String { return value }
            if let value = result["protocolVersion"] as? NSNumber { return value.stringValue }
            return nil
        }()
        return CodexAppServerCapabilities(
            serverIdentity: identity?.isEmpty == false ? identity : nil,
            protocolVersion: version,
            imageInput: .unknown
        )
    }

    /// Exact v2 app-server shape generated by the installed schema: text plus localImage path items.
    public static func turnInput(prompt: String, attachments: [ContextAttachment]) -> [[String: Any]] {
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        input += attachments.filter(\.isImage).map { ["type": "localImage", "path": $0.path] }
        return input
    }

    private static func threadID(from result: [String: Any]) -> String? {
        ((result["thread"] as? [String: Any])?["id"] as? String) ?? (result["threadId"] as? String)
    }

    private static func turnID(from result: [String: Any]) -> String? {
        ((result["turn"] as? [String: Any])?["id"] as? String) ?? (result["turnId"] as? String)
    }

    private static func validateEffectiveRoute(
        _ result: [String: Any],
        requested: (approvalPolicy: String, sandbox: String)
    ) throws {
        guard let approvalPolicy = result["approvalPolicy"] as? String,
              let sandbox = effectiveSandbox(from: result) else {
            throw CodexHarnessError.message("Codex did not confirm the requested approval and workspace safety settings. Update Codex before using this connection.")
        }
        guard approvalPolicy == requested.approvalPolicy, sandbox == requested.sandbox else {
            throw CodexHarnessError.message("Codex applied different approval or workspace safety settings than Lattice requested. The turn was not started.")
        }
    }

    private static func effectiveSandbox(from result: [String: Any]) -> String? {
        let raw: String?
        if let value = result["sandbox"] as? String {
            raw = value
        } else if let object = result["sandbox"] as? [String: Any] {
            raw = object["type"] as? String ?? object["mode"] as? String
        } else {
            raw = nil
        }
        switch raw {
        case "readOnly": return "read-only"
        case "workspaceWrite": return "workspace-write"
        case "dangerFullAccess": return "danger-full-access"
        default: return raw
        }
    }

    private static func probeSupport(
        _ response: [String: Any]?,
        validate: ([String: Any]) -> Bool
    ) -> CodexAppServerCapabilities.Support {
        guard let response else { return .unknown }
        if response["error"] == nil,
           let result = response["result"] as? [String: Any],
           validate(result) { return .supported }
        return isUnsupportedMethod(response) ? .unsupported : .unknown
    }

    private static func imageInputSupport(_ response: [String: Any]?) -> CodexAppServerCapabilities.Support {
        guard let response else { return .unknown }
        if isUnsupportedMethod(response) { return .unsupported }
        guard let result = response["result"] as? [String: Any],
              let models = result["data"] as? [[String: Any]] else { return .unknown }
        return models.contains { $0["inputModalities"] is [String] } ? .supported : .unknown
    }

    private static func modelCatalogUnavailableReason(
        for support: CodexAppServerCapabilities.Support
    ) -> String? {
        switch support {
        case .supported: nil
        case .unsupported: "This Codex app-server does not support model discovery. Update Codex and refresh Connections."
        case .unknown: "Codex returned an incomplete model discovery response. Check sign-in, update Codex, and refresh Connections."
        }
    }

    private static func isUnsupportedMethod(_ response: [String: Any]) -> Bool {
        guard let error = response["error"] as? [String: Any] else { return false }
        return (error["code"] as? NSNumber)?.intValue == -32601
    }

    private static func readProbeResponse(id: Int, from reader: BoundedJSONLineReader) throws -> [String: Any] {
        while let object = try reader.next() {
            guard object["method"] == nil, (object["id"] as? NSNumber)?.intValue == id else { continue }
            if object["error"] != nil {
                throw CodexHarnessError.message(responseError(object, fallback: "Codex app-server protocol negotiation failed."))
            }
            return object
        }
        throw CodexHarnessError.message("Codex app-server ended before protocol negotiation completed.")
    }

    private static func executionRoute(policy: ExecutionPolicy, workspaceWrite: Bool) -> (approvalPolicy: String, sandbox: String) {
        switch policy {
        case .ask: ("on-request", workspaceWrite ? "workspace-write" : "read-only")
        case .smart, .acceptEdits: ("on-request", "workspace-write")
        case .yolo: ("never", "danger-full-access")
        }
    }

    private func readResponse(
        id: Int,
        sessionID: UUID,
        owner: InteractiveProcessRegistry.Owner,
        from reader: BoundedJSONLineReader,
        transport: BoundedProcessTransport,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws -> [String: Any] {
        while let object = try reader.next() {
            if object["method"] != nil {
                if object["id"] != nil {
                    try await handleServerRequest(object, sessionID: sessionID, owner: owner, workspace: nil, transport: transport, continuation: continuation)
                }
                continue
            }
            if (object["id"] as? NSNumber)?.intValue == id {
                return object
            }
        }
        throw CodexHarnessError.message("Codex app-server ended before responding.")
    }

    private func readTurn(
        sessionID: UUID,
        owner: InteractiveProcessRegistry.Owner,
        workspace: URL,
        from reader: BoundedJSONLineReader,
        transport: BoundedProcessTransport,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws -> Bool {
        while let object = try reader.next() {
            if object["id"] != nil, object["method"] != nil {
                try await handleServerRequest(object, sessionID: sessionID, owner: owner, workspace: workspace, transport: transport, continuation: continuation)
                continue
            }
            guard let method = object["method"] as? String else { continue }
            if method == "turn/completed" {
                let event = Self.turnCompletionEvent(from: object)
                continuation.yield(event)
                return event == .cancelled
            }
            if let event = Self.appServerEvent(from: object, workspace: workspace) { continuation.yield(event) }
        }
        throw CodexHarnessError.message("Codex app-server ended before completing the turn.")
    }

    private func handleServerRequest(
        _ object: [String: Any],
        sessionID: UUID,
        owner: InteractiveProcessRegistry.Owner,
        workspace: URL?,
        transport: BoundedProcessTransport,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws {
        guard let serverID = object["id"], let method = object["method"] as? String else { return }
        let approvalMethods = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"]
        guard approvalMethods.contains(method) else {
            try Self.write(["id": serverID, "error": ["code": -32601, "message": "Unsupported Codex client request: \(method)"]], to: transport)
            if method.hasSuffix("/requestApproval") {
                throw CodexHarnessError.message("Codex requested approval for a tool this Lattice version cannot safely handle. Update Lattice or Codex and retry.")
            }
            return
        }
        guard let workspace, let request = Self.appServerPermissionRequest(from: object, workspace: workspace), !request.options.isEmpty else {
            try Self.write(["id": serverID, "error": ["code": -32602, "message": "Unsupported or malformed Codex approval request: \(method)"]], to: transport)
            throw CodexHarnessError.message("Codex requested approval using a schema this Lattice version cannot safely handle. Update Lattice or Codex and retry.")
        }
        let decisions = Set(request.options.map(\.id)).union(["cancel"])
        let pending = PendingPermission(sessionID: sessionID, owner: owner, requestID: request.id, serverRequestID: serverID, allowedDecisions: decisions)
        register(pending)
        continuation.yield(.permissionRequested(request))
        let result = await pending.wait(timeoutNanoseconds: permissionTimeoutNanoseconds)
        removePendingPermission(request.id, owner: owner, sessionID: sessionID)
        switch result {
        case .resolved(.selected(let decision)):
            try Self.writeControl(["id": pending.serverRequestID, "result": ["decision": decision]], to: transport)
        case .resolved(.cancelled):
            try Self.writeControl(["id": pending.serverRequestID, "result": ["decision": "cancel"]], to: transport)
        case .timedOut:
            try? Self.writeControl(["id": pending.serverRequestID, "result": ["decision": "cancel"]], to: transport)
            throw CodexHarnessError.message(PermissionTimeout.message)
        }
    }

    public static func appServerPermissionRequest(from object: [String: Any], workspace: URL) -> ApprovalRequest? {
        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else { return nil }
        if method == "item/commandExecution/requestApproval" {
            let command = params["command"] as? String ?? "Command"
            let cwd = params["cwd"] as? String
            let request = ToolRequest(
                kind: .command,
                title: "Codex wants to run a command",
                detail: command.hasPrefix("$") ? command : "$ \(command)",
                workspaceScoped: cwd.map { WorkspacePathScope.isWorkspaceScoped($0, workspace: workspace) } ?? false,
                reversible: false
            )
            let decisions = (params["availableDecisions"] as? [Any])?.compactMap { $0 as? String } ?? ["accept", "decline"]
            return ApprovalRequest(
                title: request.title,
                detail: request.detail,
                options: Self.approvalOptions(decisions),
                toolRequest: request
            )
        }
        if method == "item/fileChange/requestApproval" {
            let root = params["grantRoot"] as? String
            let reason = params["reason"] as? String
            let detail = reason ?? root ?? "Apply the proposed workspace file changes."
            let request = ToolRequest(
                kind: .write,
                title: "Codex wants to change files",
                detail: detail,
                workspaceScoped: root.map { WorkspacePathScope.isWorkspaceScoped($0, workspace: workspace) } ?? false,
                reversible: false
            )
            let decisions = (params["availableDecisions"] as? [Any])?.compactMap { $0 as? String }
                ?? ["accept", "acceptForSession", "decline", "cancel"]
            return ApprovalRequest(
                title: request.title,
                detail: request.detail,
                options: Self.approvalOptions(decisions),
                toolRequest: request
            )
        }
        return nil
    }

    public static func appServerEvent(
        from object: [String: Any],
        workspace: URL,
        applicationSupportRoot: URL = LatticeApplicationSupport.productRootURL(),
        imageProbe: AssistantImageArtifactPolicy.FileProbe = .default
    ) -> AgentEvent? {
        guard let method = object["method"] as? String else { return HarnessToolEventDecoder.diagnostic(provider: "Codex", object: object, reason: "App-server event is missing method.") }
        guard let params = object["params"] as? [String: Any] else { return method == "item/reasoning/textDelta" ? nil : HarnessToolEventDecoder.diagnostic(provider: "Codex", object: object, reason: "App-server event is missing params.") }
        if method == "item/agentMessage/delta" {
            guard let delta = params["delta"] as? String else { return HarnessToolEventDecoder.diagnostic(provider: "Codex", object: object, reason: "Agent message delta is malformed.") }
            return .assistantDelta(delta)
        }
        if method == "item/reasoning/summaryTextDelta",
           let externalID = params["itemId"] as? String,
           let delta = params["delta"] as? String, !delta.isEmpty {
            return .reasoningSummary(id: HarnessToolEventDecoder.stableID(for: "codex:reasoning:\(externalID)"), delta: delta)
        }
        if method == "item/reasoning/summaryTextDelta" { return HarnessToolEventDecoder.diagnostic(provider: "Codex", object: object, reason: "Reasoning summary delta is malformed.") }
        if method == "item/reasoning/textDelta" { return nil }
        if method == "turn/plan/updated",
           let turnID = params["turnId"] as? String,
           let rawSteps = params["plan"] as? [[String: Any]] {
            let explanation = (params["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let steps = rawSteps.enumerated().compactMap { index, value -> AgentPlanStep? in
                guard let step = (value["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty else { return nil }
                let status: AgentPlanStep.Status
                switch value["status"] as? String {
                case "completed": status = .completed
                case "inProgress": status = .inProgress
                default: status = .pending
                }
                return AgentPlanStep(
                    id: HarnessToolEventDecoder.stableID(for: "codex:plan:\(turnID):\(index):\(step)"),
                    title: step,
                    status: status
                )
            }
            guard !steps.isEmpty else { return HarnessToolEventDecoder.diagnostic(provider: "Codex", object: object, reason: "Turn plan update has no usable steps.") }
            return .plan(
                id: HarnessToolEventDecoder.stableID(for: "codex:plan:\(turnID)"),
                title: "Plan",
                explanation: explanation?.isEmpty == false ? explanation : nil,
                steps: steps
            )
        }
        if method == "turn/plan/updated" { return HarnessToolEventDecoder.diagnostic(provider: "Codex", object: object, reason: "Turn plan update is malformed.") }
        if method == "error" {
            let error = params["error"] as? [String: Any]
            return .failed(error?["message"] as? String ?? params["message"] as? String ?? "Codex error")
        }
        guard ["item/started", "item/completed"].contains(method),
              let item = params["item"] as? [String: Any],
              let type = item["type"] as? String,
              let externalID = item["id"] as? String else { return HarnessToolEventDecoder.diagnostic(provider: "Codex", object: object, reason: "Item event is malformed.") }
        let id = HarnessToolEventDecoder.stableID(for: "codex:\(externalID)")
        let completed = method == "item/completed"
        switch type {
        case "commandExecution":
            if completed {
                return terminalToolProgress(id: id, status: item["status"])
            }
            let command = item["command"] as? String ?? "Command"
            let cwd = item["cwd"] as? String
            return .toolRequested(.init(id: id, kind: .command, title: "Run command", detail: "$ \(command)", workspaceScoped: cwd.map { WorkspacePathScope.isWorkspaceScoped($0, workspace: workspace) } ?? false, reversible: false))
        case "fileChange":
            if completed {
                return terminalToolProgress(id: id, status: item["status"])
            }
            let pathEvidence = (item["changes"] as? [[String: Any]] ?? []).map { $0["path"] as? String }
            let paths = pathEvidence.compactMap { $0 }
            return .toolRequested(.init(id: id, kind: .write, title: "Change files", detail: paths.isEmpty ? "Workspace files" : paths.joined(separator: ", "), workspaceScoped: !pathEvidence.isEmpty && pathEvidence.allSatisfy { WorkspacePathScope.isWorkspaceScoped($0, workspace: workspace) }, reversible: false))
        case "webSearch":
            if completed { return terminalToolProgress(id: id, status: item["status"]) }
            return .toolRequested(.init(id: id, kind: .network, title: "Search the web", detail: item["query"] as? String ?? "", workspaceScoped: false, reversible: true))
        case "imageView":
            // Schema: ImageViewThreadItem requires id + path. Project only on completion.
            guard completed else { return nil }
            guard let path = item["path"] as? String else {
                return HarnessToolEventDecoder.diagnostic(
                    provider: "Codex",
                    object: ["type": type],
                    reason: "imageView item is missing path."
                )
            }
            return StructuredAssistantArtifactDecoder.artifactEvent(
                path: path,
                provider: "Codex",
                origin: .codexImageView,
                eventID: externalID,
                workspace: workspace,
                applicationSupportRoot: applicationSupportRoot,
                probe: imageProbe,
                artifactID: HarnessToolEventDecoder.stableID(for: "codex:artifact:imageView:\(externalID)")
            )
        case "imageGeneration":
            // Schema: ImageGenerationThreadItem has required result/status and optional savedPath.
            // Never treat `result` as a file path and never decode base64 from it.
            guard completed else { return nil }
            let status = (item["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard status == "completed" else {
                if status == "failed" || status == "cancelled" || status == "canceled" {
                    return terminalToolProgress(id: id, status: item["status"])
                }
                return HarnessToolEventDecoder.diagnostic(
                    provider: "Codex",
                    object: ["type": type, "status": status ?? "missing"],
                    reason: "imageGeneration completed with an unsupported status."
                )
            }
            guard let savedPath = item["savedPath"] as? String,
                  !savedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Successful generation without a saved path is not a durable local artifact.
                return HarnessToolEventDecoder.diagnostic(
                    provider: "Codex",
                    object: ["type": type, "status": "completed"],
                    reason: "imageGeneration completed without a savedPath."
                )
            }
            return StructuredAssistantArtifactDecoder.artifactEvent(
                path: savedPath,
                provider: "Codex",
                origin: .codexImageGeneration,
                eventID: externalID,
                workspace: workspace,
                applicationSupportRoot: applicationSupportRoot,
                probe: imageProbe,
                artifactID: HarnessToolEventDecoder.stableID(for: "codex:artifact:imageGeneration:\(externalID)")
            )
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "Provider tool"
            let isComputerTool = tool.lowercased().contains("computer")
            if completed, isComputerTool,
               let content = item["contentItems"] as? [[String: Any]],
               let admittedImage = content.compactMap({ value -> (path: String, data: Data)? in
                   guard value["type"] as? String == "inputImage",
                         let raw = value["imageUrl"] as? String,
                         let admitted = ComputerFrame.authorizedImage(
                             from: raw,
                             under: [workspace, applicationSupportRoot]
                         ) else { return nil }
                   return (admitted.url.path, admitted.data)
               }).last {
                return .computerFrame(.init(
                    id: id,
                    provider: "Codex",
                    imagePath: admittedImage.path,
                    imageData: admittedImage.data,
                    sourceIdentity: externalID
                ))
            }
            if completed, isComputerTool,
               let content = item["contentItems"] as? [[String: Any]],
               content.contains(where: { $0["type"] as? String == "inputImage" }) {
                return HarnessToolEventDecoder.diagnostic(
                    provider: "Codex",
                    object: ["type": type, "status": item["status"] as? String ?? "completed"],
                    reason: "Computer frame was outside the workspace or Lattice storage, was not a regular image, or exceeded the frame limit."
                )
            }
            if completed { return terminalToolProgress(id: id, status: item["status"]) }
            return .toolRequested(.init(
                id: id,
                kind: isComputerTool ? .automation : .unknown,
                title: isComputerTool ? "Codex computer activity" : "Codex is using \(tool)",
                detail: isComputerTool
                    ? "Provider-owned computer tool. Lattice will display only structured frames the provider supplies."
                    : tool,
                workspaceScoped: false,
                reversible: false
            ))
        default:
            return HarnessToolEventDecoder.diagnostic(provider: "Codex", object: item, reason: "Unsupported item event.")
        }
    }

    static func turnCompletionEvent(from object: [String: Any]) -> AgentEvent {
        let turn = (object["params"] as? [String: Any])?["turn"] as? [String: Any]
        switch turn?["status"] as? String {
        case "completed": return .completed
        case "interrupted": return .cancelled
        case "failed":
            let error = turn?["error"] as? [String: Any]
            return .failed(error?["message"] as? String ?? "Codex could not complete the turn.")
        default: return .failed("Codex returned malformed turn status.")
        }
    }

    private static func terminalToolProgress(id: UUID, status: Any?) -> AgentEvent {
        let detail: String
        switch status as? String {
        case "completed": detail = "Completed"
        case "failed": detail = "Failed"
        case "cancelled", "canceled", "interrupted", "declined": detail = "Cancelled"
        default: detail = "Failed"
        }
        return .toolProgress(id: id, fraction: 1, detail: detail)
    }

    private static func approvalOptions(_ decisions: [String]) -> [ApprovalOption] {
        decisions.compactMap { decision in
            switch decision {
            case "accept": .init(id: decision, name: "Allow once", kind: "allow_once")
            case "acceptForSession": .init(id: decision, name: "Allow for session", kind: "allow_session")
            case "decline": .init(id: decision, name: "Deny", kind: "reject_once")
            case "cancel": .init(id: decision, name: "Stop", kind: "reject_always")
            default: nil
            }
        }
    }

    private static func responseError(_ object: [String: Any], fallback: String) -> String {
        (object["error"] as? [String: Any])?["message"] as? String ?? fallback
    }

    private static func write(_ object: [String: Any], to transport: BoundedProcessTransport) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try transport.write(data)
    }

    private static func writeControl(_ object: [String: Any], to transport: BoundedProcessTransport) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try transport.writeControl(data)
    }

    fileprivate static func parseModels(_ response: [String: Any]) -> [ProviderModel] {
        guard let result = response["result"] as? [String: Any], let values = result["data"] as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard value["hidden"] as? Bool != true,
                  value["upgrade"] == nil || value["upgrade"] is NSNull,
                  let id = (value["model"] as? String) ?? (value["id"] as? String) else { return nil }
            let name = (value["displayName"] as? String) ?? (value["name"] as? String) ?? id
            let options = (value["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { option -> ReasoningOption? in
                guard let raw = option["reasoningEffort"] as? String, let effort = ReasoningEffort(rawValue: raw) else { return nil }
                return ReasoningOption(effort: effort, description: option["description"] as? String ?? "")
            }
            let defaultEffort = (value["defaultReasoningEffort"] as? String).flatMap(ReasoningEffort.init(rawValue:))
            let inputModalities = (value["inputModalities"] as? [String]).map { values in
                Set(values.compactMap(ModelInputModality.init(rawValue:)))
            }
            return ProviderModel(id: id, name: name, description: value["description"] as? String ?? "", reasoningOptions: options, defaultReasoningEffort: defaultEffort, contextWindow: ProviderModelMetadata.contextWindow(from: value), isDefault: value["isDefault"] as? Bool ?? false, inputModalities: inputModalities)        }
    }

    fileprivate static func parseUsage(_ response: [String: Any]) -> ProviderUsage? {
        guard let result = response["result"] as? [String: Any], let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var windows: [UsageWindow] = []
        for (key, title) in [("primary", "Current window"), ("secondary", "Weekly window")] {
            guard let window = limits[key] as? [String: Any], let used = window["usedPercent"] as? Int else { continue }
            let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(UsageWindow(id: key, name: title, usedPercent: used, resetsAt: reset))
        }
        let credits = (limits["credits"] as? [String: Any])?["balance"] as? String
        return windows.isEmpty && credits == nil ? nil : ProviderUsage(windows: windows, creditsBalance: credits)
    }

    private static func run(_ executable: URL, arguments: [String]) async -> BoundedSubprocessResult {
        await BoundedSubprocess.run(.init(
            executableURL: executable,
            arguments: arguments,
            environment: ChildProcessEnvironmentPolicy.providerOwnedRuntime(),
            deadline: 30,
            maximumOutputBytes: BoundedSubprocessRequest.defaultMaximumOutputBytes
        ))
    }


}

public struct CodexProviderSnapshot: Sendable {
    public let models: [ProviderModel]
    public let usage: ProviderUsage?
    public let catalogStatus: ProviderCatalogStatus
    public let capabilities: CodexAppServerCapabilities
    public let unavailableReason: String?
    public init(
        models: [ProviderModel],
        usage: ProviderUsage?,
        catalogStatus: ProviderCatalogStatus = .unknown,
        capabilities: CodexAppServerCapabilities = .init(),
        unavailableReason: String? = nil
    ) {
        self.models = models
        self.usage = usage
        self.catalogStatus = catalogStatus
        self.capabilities = capabilities
        self.unavailableReason = unavailableReason
    }
    public static let empty = CodexProviderSnapshot(models: [], usage: nil, catalogStatus: .unknown)
}
