import Foundation

private enum CodexHarnessError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
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
    private let lock = NSLock()
    private let processRegistry = InteractiveProcessRegistry()
    private var pendingPermissions: [UUID: PendingPermission] = [:]

    public init(executableURL: URL? = ExecutableDiscovery.locate("codex"), permissionTimeout: TimeInterval = 120) {
        self.executableURL = executableURL
        self.permissionTimeoutNanoseconds = PermissionTimeout.nanoseconds(for: permissionTimeout)
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
        let messages: [[String: Any]] = [
            ["method": "initialize", "id": 0, "params": ["clientInfo": ["name": "lattice", "title": "Lattice", "version": "0.1.0"], "capabilities": ["experimentalApi": true]]],
            ["method": "initialized", "params": [:]],
            ["method": "model/list", "id": 1, "params": ["includeHidden": false, "limit": 100]],
            ["method": "account/rateLimits/read", "id": 2]
        ]
        let stdinData: Data
        do {
            stdinData = try messages.reduce(into: Data()) { data, message in
                data.append(contentsOf: try JSONSerialization.data(withJSONObject: message))
                data.append(0x0A)
            }
        } catch {
            return CodexProviderSnapshot(models: [], usage: nil, catalogStatus: .failed)
        }
        let accumulator = AppServerAccumulator()
        let result = await BoundedSubprocess.run(
            .init(
                executableURL: executableURL,
                arguments: ["app-server", "-c", "service_tier=\"flex\""],
                stdinData: stdinData,
                deadline: 6
            ),
            stopWhen: { stdout, _ in
                accumulator.append(stdout)
                return accumulator.isComplete
            }
        )
        guard result.outcome == .completed || result.outcome == .exited else {
            return CodexProviderSnapshot(models: [], usage: nil, catalogStatus: .failed)
        }
        accumulator.append(result.stdout)
        return accumulator.snapshot
    }

    public func stream(prompt: String, sessionID: UUID, threadID: String?, workspace: URL, model: String, reasoningEffort: ReasoningEffort? = nil, policy: ExecutionPolicy = .ask, workspaceWrite: Bool = false) -> AsyncStream<AgentEvent> {
        AsyncStream<AgentEvent>(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    continuation.yield(.failed("Codex is not installed.")); continuation.finish(); return
                }
                let transport = BoundedProcessTransport(request: .init(
                    executableURL: executableURL,
                    arguments: ["app-server", "-c", "service_tier=\"flex\""],
                    currentDirectoryURL: workspace,
                    deadline: 30 * 60,
                    maximumOutputBytes: 8_000_000
                ))
                var owner: InteractiveProcessRegistry.Owner?
                let start = processRegistry.beginStart(for: sessionID)
                do {
                    try transport.start()
                    guard let registeredOwner = register(process: transport, input: transport.input, for: sessionID, start: start) else {
                        throw CodexHarnessError.message("Codex request cancelled before process registration.")
                    }
                    owner = registeredOwner
                    let reader = BoundedJSONLineReader(transport.output)
                    try Self.write(Self.initializeRequest(id: 1), to: transport.input)
                    _ = try await readResponse(id: 1, sessionID: sessionID, owner: registeredOwner, from: reader, input: transport.input, continuation: continuation)
                    try Self.write(["method": "initialized", "params": [:]], to: transport.input)

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
                    if let threadID { threadParams["threadId"] = threadID }
                    try Self.write(["method": method, "id": 2, "params": threadParams], to: transport.input)
                    let threadResponse = try await readResponse(id: 2, sessionID: sessionID, owner: registeredOwner, from: reader, input: transport.input, continuation: continuation)
                    guard let result = threadResponse["result"] as? [String: Any],
                          let thread = result["thread"] as? [String: Any],
                          let activeThreadID = thread["id"] as? String else {
                        throw CodexHarnessError.message(Self.responseError(threadResponse, fallback: "Codex did not return a thread ID."))
                    }
                    setThreadID(activeThreadID, owner: registeredOwner, for: sessionID)
                    continuation.yield(.harnessSessionStarted(activeThreadID))

                    var turnParams: [String: Any] = [
                        "threadId": activeThreadID,
                        "input": [["type": "text", "text": prompt]],
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
                    try Self.write(["method": "turn/start", "id": 3, "params": turnParams], to: transport.input)
                    let turnResponse = try await readResponse(id: 3, sessionID: sessionID, owner: registeredOwner, from: reader, input: transport.input, continuation: continuation)
                    guard let turnResult = turnResponse["result"] as? [String: Any],
                          let turn = turnResult["turn"] as? [String: Any],
                          let turnID = turn["id"] as? String else {
                        throw CodexHarnessError.message(Self.responseError(turnResponse, fallback: "Codex did not start the turn."))
                    }
                    setTurnID(turnID, owner: registeredOwner, for: sessionID)
                    let turnReportedCancellation = try await readTurn(sessionID: sessionID, owner: registeredOwner, workspace: workspace, from: reader, input: transport.input, continuation: continuation)
                    transport.finish()
                    let didCancel = unregister(registeredOwner, start: start, sessionID: sessionID)
                    if didCancel && !turnReportedCancellation { continuation.yield(.cancelled) }
                } catch {
                    let didCancel = unregister(owner, start: start, sessionID: sessionID)
                    transport.cancel()
                    if didCancel || transport.terminationReason == .cancelled { continuation.yield(.cancelled) }
                    else if transport.terminationReason == .timedOut { continuation.yield(.failed("Codex timed out.")) }
                    else if transport.terminationReason == .outputLimitExceeded { continuation.yield(.failed("Codex output exceeded its limit.")) }
                    else { continuation.yield(.failed(error.localizedDescription)) }
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
        let target = processRegistry.cancel(sessionID: sessionID)
        let input = target.input
        let threadID = target.metadata.threadID
        let turnID = target.metadata.turnID
        lock.lock()
        let pending = target.metadata.pendingPermissionIDs.compactMap { pendingPermissions[$0] }
        lock.unlock()
        pending.forEach { _ = $0.resolve(nil) }
        if let input, let threadID, let turnID {
            try? Self.write(["method": "turn/interrupt", "id": 99, "params": ["threadId": threadID, "turnId": turnID]], to: input)
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
        guard processRegistry.updateMetadata(pending.owner, sessionID: pending.sessionID, {
            $0.pendingPermissionIDs.insert(pending.requestID)
        }) else {
            _ = pending.resolve(nil)
            return
        }
        lock.lock(); pendingPermissions[pending.requestID] = pending; lock.unlock()
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

    private static func executionRoute(policy: ExecutionPolicy, workspaceWrite: Bool) -> (approvalPolicy: String, sandbox: String) {
        switch policy {
        case .ask: ("on-request", workspaceWrite ? "workspace-write" : "read-only")
        case .smart: ("on-request", "workspace-write")
        case .yolo: ("never", "danger-full-access")
        }
    }

    private func readResponse(
        id: Int,
        sessionID: UUID,
        owner: InteractiveProcessRegistry.Owner,
        from reader: BoundedJSONLineReader,
        input: FileHandle,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws -> [String: Any] {
        while let object = try reader.next() {
            if object["method"] != nil {
                if object["id"] != nil {
                    try await handleServerRequest(object, sessionID: sessionID, owner: owner, workspace: nil, input: input, continuation: continuation)
                }
                continue
            }
            if (object["id"] as? NSNumber)?.intValue == id {
                if object["error"] != nil { throw CodexHarnessError.message(Self.responseError(object, fallback: "Codex app-server request failed.")) }
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
        input: FileHandle,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws -> Bool {
        while let object = try reader.next() {
            if object["id"] != nil, object["method"] != nil {
                try await handleServerRequest(object, sessionID: sessionID, owner: owner, workspace: workspace, input: input, continuation: continuation)
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
        input: FileHandle,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async throws {
        guard let serverID = object["id"], let method = object["method"] as? String else { return }
        guard let workspace,
              ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method),
              let request = Self.appServerPermissionRequest(from: object, workspace: workspace) else {
            try Self.write(["id": serverID, "error": ["code": -32601, "message": "Unsupported Codex client request: \(method)"]], to: input)
            return
        }
        let decisions = Set(request.options.map(\.id)).union(["cancel"])
        let pending = PendingPermission(sessionID: sessionID, owner: owner, requestID: request.id, serverRequestID: serverID, allowedDecisions: decisions)
        register(pending)
        continuation.yield(.permissionRequested(request))
        let result = await pending.wait(timeoutNanoseconds: permissionTimeoutNanoseconds)
        removePendingPermission(request.id, owner: owner, sessionID: sessionID)
        switch result {
        case .resolved(.selected(let decision)):
            try Self.write(["id": pending.serverRequestID, "result": ["decision": decision]], to: input)
        case .resolved(.cancelled):
            try Self.write(["id": pending.serverRequestID, "result": ["decision": "cancel"]], to: input)
        case .timedOut:
            try? Self.write(["id": pending.serverRequestID, "result": ["decision": "cancel"]], to: input)
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
            return ApprovalRequest(
                title: request.title,
                detail: request.detail,
                options: Self.approvalOptions(["accept", "acceptForSession", "decline", "cancel"]),
                toolRequest: request
            )
        }
        return nil
    }

    public static func appServerEvent(from object: [String: Any], workspace: URL) -> AgentEvent? {
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
            var steps: [String] = []
            if let explanation = (params["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !explanation.isEmpty {
                steps.append(explanation)
            }
            steps += rawSteps.compactMap { value in
                guard let step = (value["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !step.isEmpty else { return nil }
                let status = value["status"] as? String
                let label: String
                switch status {
                case "completed": label = "Completed"
                case "inProgress": label = "In progress"
                default: label = "Pending"
                }
                return "\(label) — \(step)"
            }
            guard !steps.isEmpty else { return HarnessToolEventDecoder.diagnostic(provider: "Codex", object: object, reason: "Turn plan update has no usable steps.") }
            return .plan(id: HarnessToolEventDecoder.stableID(for: "codex:plan:\(turnID)"), title: "Plan", steps: steps)
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

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    fileprivate static func parseModels(_ response: [String: Any]) -> [ProviderModel] {
        guard let result = response["result"] as? [String: Any], let values = result["data"] as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard value["hidden"] as? Bool != true,
                  value["upgrade"] == nil || value["upgrade"] is NSNull,
                  let id = value["model"] as? String,
                  let name = value["displayName"] as? String else { return nil }
            let options = (value["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { option -> ReasoningOption? in
                guard let raw = option["reasoningEffort"] as? String, let effort = ReasoningEffort(rawValue: raw) else { return nil }
                return ReasoningOption(effort: effort, description: option["description"] as? String ?? "")
            }
            let defaultEffort = (value["defaultReasoningEffort"] as? String).flatMap(ReasoningEffort.init(rawValue:))
            return ProviderModel(id: id, name: name, description: value["description"] as? String ?? "", reasoningOptions: options, defaultReasoningEffort: defaultEffort, contextWindow: ProviderModelMetadata.contextWindow(from: value), isDefault: value["isDefault"] as? Bool ?? false)
        }
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
            deadline: 30,
            maximumOutputBytes: BoundedSubprocessRequest.defaultMaximumOutputBytes
        ))
    }


}

private final class AppServerAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var frameBuffer = BoundedJSONLineBuffer()
    private var processedInputBytes = 0
    private var models: [ProviderModel] = []
    private var usage: ProviderUsage?
    private var received: Set<Int> = []
    private var failed = false
    private var modelCatalogSucceeded = false

    var isComplete: Bool { lock.withLock { failed || received.isSuperset(of: [1, 2]) } }
    var snapshot: CodexProviderSnapshot {
        lock.withLock {
            if failed { return CodexProviderSnapshot(models: [], usage: nil, catalogStatus: .failed) }
            let status = received.contains(1)
                ? ProviderCatalogStatus.resolved(modelCount: models.count, succeeded: modelCatalogSucceeded)
                : .failed
            return CodexProviderSnapshot(models: models, usage: usage, catalogStatus: status)
        }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            guard !failed, chunk.count >= processedInputBytes else { return }
            let delta = chunk.dropFirst(processedInputBytes)
            processedInputBytes = chunk.count
            do {
                for object in try frameBuffer.append(Data(delta)) {
                    guard let id = object["id"] as? Int else { continue }
                    if id == 1 {
                        modelCatalogSucceeded = object["error"] == nil
                        models = CodexExecHarness.parseModels(object)
                        received.insert(id)
                    }
                    if id == 2 { usage = CodexExecHarness.parseUsage(object); received.insert(id) }
                }
            } catch {
                failed = true
                models.removeAll(keepingCapacity: false)
                usage = nil
                received.removeAll(keepingCapacity: false)
            }
        }
    }
}

public struct CodexProviderSnapshot: Sendable {
    public let models: [ProviderModel]
    public let usage: ProviderUsage?
    public let catalogStatus: ProviderCatalogStatus
    public init(models: [ProviderModel], usage: ProviderUsage?, catalogStatus: ProviderCatalogStatus = .unknown) {
        self.models = models; self.usage = usage; self.catalogStatus = catalogStatus
    }
    public static let empty = CodexProviderSnapshot(models: [], usage: nil, catalogStatus: .unknown)
}
