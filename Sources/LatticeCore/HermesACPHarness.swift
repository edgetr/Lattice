import Foundation

public struct HarnessModel: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public final class ACPHarness: @unchecked Sendable {
    public enum Profile: String, Sendable {
        case hermes
        case grok
        case openCode

        var executableName: String {
            switch self {
            case .hermes: "hermes"
            case .grok: "grok"
            case .openCode: "opencode"
            }
        }

        var displayName: String {
            switch self {
            case .hermes: "Hermes"
            case .grok: "Grok"
            case .openCode: "OpenCode"
            }
        }

        var sessionPrefix: String {
            switch self {
            case .hermes: "hermes:"
            case .grok: "grok-acp:"
            case .openCode: "opencode-acp:"
            }
        }

        func arguments(workspace: URL) -> [String] {
            switch self {
            case .hermes: ["acp"]
            case .grok: ["agent", "--no-leader", "stdio"]
            case .openCode: ["acp", "--pure", "--cwd", workspace.path]
            }
        }
    }

    private final class PendingPermission: @unchecked Sendable {
        enum Decision: Sendable { case selected(String), cancelled }

        let sessionID: UUID
        let owner: InteractiveProcessRegistry.Owner
        let requestID: UUID
        let optionIDs: Set<String>
        private let waiter = PermissionWaiter<Decision>()

        init(sessionID: UUID, owner: InteractiveProcessRegistry.Owner, requestID: UUID, optionIDs: Set<String>) {
            self.sessionID = sessionID
            self.owner = owner
            self.requestID = requestID
            self.optionIDs = optionIDs
        }

        @discardableResult
        func resolve(optionID: String?) -> Bool {
            if let optionID {
                guard optionIDs.contains(optionID) else { return false }
                return waiter.resolve(.selected(optionID))
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
    private let sandboxExecutableURL: URL?
    private let profile: Profile
    private let permissionTimeoutNanoseconds: UInt64
    private let lock = NSLock()
    private let processRegistry = InteractiveProcessRegistry()
    private var pendingPermissions: [UUID: PendingPermission] = [:]

    public init(
        profile: Profile = .hermes,
        executableURL: URL? = nil,
        sandboxExecutableURL: URL? = HarnessSandbox.systemExecutableURL,
        permissionTimeout: TimeInterval = 120
    ) {
        self.profile = profile
        self.executableURL = executableURL ?? ExecutableDiscovery.locate(profile.executableName)
        self.sandboxExecutableURL = sandboxExecutableURL
        self.permissionTimeoutNanoseconds = PermissionTimeout.nanoseconds(for: permissionTimeout)
    }

    public var isInstalled: Bool { executableURL != nil }

    public func models(workspace: URL) async -> [HarnessModel] {
        await modelsResult(workspace: workspace).models
    }

    public func modelsResult(workspace: URL) async -> ProviderCatalogResult<HarnessModel> {
        guard let executableURL else { return .unknown() }
        let scratchDirectory = scratchDirectory(for: UUID())
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        do {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            let canonicalWorkspace = try HarnessSandbox.canonicalDirectory(workspace)
            let launch = try sandboxedLaunch(
                executableURL: executableURL,
                sandboxExecutableURL: sandboxExecutableURL,
                workspace: canonicalWorkspace,
                scratchDirectory: scratchDirectory
            )
            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = scratchDirectory.path + "/"
            var stdinData = Data()
            stdinData.append(contentsOf: try Self.serialized(Self.initializeRequest(id: 1)))
            stdinData.append(contentsOf: try Self.serialized(Self.sessionRequest(id: 2, method: "session/new", workspace: canonicalWorkspace, threadID: nil)))
            let result = await BoundedSubprocess.run(
                .init(
                    executableURL: launch.executableURL,
                    arguments: launch.arguments,
                    stdinData: stdinData,
                    currentDirectoryURL: canonicalWorkspace,
                    environment: environment,
                    deadline: 10,
                    maximumOutputBytes: 1_000_000
                ),
                stopWhen: { stdout, _ in !Self.modelsFromOutput(stdout).isEmpty }
            )
            let models = Self.modelsFromOutput(result.stdout)
            return ProviderCatalogResult(models: models, succeeded: result.isSuccess)
        } catch {
            return ProviderCatalogResult(models: [], status: .failed)
        }
    }

    public func stream(prompt: String, sessionID: UUID, threadID: String?, workspace: URL, requestedModel: String, allowFileModification: Bool = true) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    continuation.yield(.failed("\(profile.displayName) is not installed.")); continuation.finish(); return
                }
                let scratchDirectory = scratchDirectory(for: sessionID)
                var transport: BoundedProcessTransport?
                var owner: InteractiveProcessRegistry.Owner?
                let start = processRegistry.beginStart(for: sessionID)
                do {
                    try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
                    let canonicalWorkspace = try HarnessSandbox.canonicalDirectory(workspace)
                    let launch = try sandboxedLaunch(
                        executableURL: executableURL,
                        sandboxExecutableURL: sandboxExecutableURL,
                        workspace: canonicalWorkspace,
                        scratchDirectory: scratchDirectory,
                        allowFileModification: allowFileModification
                    )
                    var environment = ProcessInfo.processInfo.environment
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
                        throw HarnessError.message("\(profile.displayName) request cancelled before process registration.")
                    }
                    owner = registeredOwner
                    let reader = BoundedJSONLineReader(runningTransport.output)
                    try Self.write(Self.initializeRequest(id: 1), to: runningTransport.input)
                    _ = try Self.readResponse(id: 1, from: reader, input: runningTransport.input)

                    var sessionRequestID = 2

                    let storedID: String? = {
                        guard let threadID else { return nil }
                        if threadID.hasPrefix(profile.sessionPrefix) { return String(threadID.dropFirst(profile.sessionPrefix.count)) }
                        return profile == .grok || profile == .openCode ? threadID : nil
                    }()
                    let method = storedID == nil ? "session/new" : "session/load"
                    try Self.write(Self.sessionRequest(id: sessionRequestID, method: method, workspace: canonicalWorkspace, threadID: storedID), to: runningTransport.input)
                    var sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, input: runningTransport.input)
                    if profile == .grok, Self.isAuthenticationRequired(sessionResponse) {
                        sessionRequestID += 1
                        try Self.write(["jsonrpc": "2.0", "id": sessionRequestID, "method": "authenticate", "params": ["methodId": "cached_token"]], to: runningTransport.input)
                        let authResponse = try Self.readResponse(id: sessionRequestID, from: reader, input: runningTransport.input)
                        if let error = authResponse["error"] as? [String: Any] {
                            throw HarnessError.message(error["message"] as? String ?? "Grok authentication failed.")
                        }
                        sessionRequestID += 1
                        try Self.write(Self.sessionRequest(id: sessionRequestID, method: method, workspace: canonicalWorkspace, threadID: storedID), to: runningTransport.input)
                        sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, input: runningTransport.input)
                    }
                    if Self.result(from: sessionResponse) == nil, storedID != nil {
                        sessionRequestID += 1
                        try Self.write(Self.sessionRequest(id: sessionRequestID, method: "session/new", workspace: canonicalWorkspace, threadID: nil), to: runningTransport.input)
                        sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, input: runningTransport.input)
                    }
                    guard let result = Self.result(from: sessionResponse), let acpID = (result["sessionId"] as? String) ?? storedID else {
                        throw HarnessError.message("\(profile.displayName) could not create a session.")
                    }
                    setACPSessionID(acpID, owner: registeredOwner, for: sessionID)
                    continuation.yield(.harnessSessionStarted("\(profile.sessionPrefix)\(acpID)"))

                    let models = Self.models(from: sessionResponse)
                    guard let matched = Self.bestMatch(for: requestedModel, in: models) else {
                        throw HarnessError.message("\(profile.displayName) does not expose \(requestedModel) through its configured provider.")
                    }
                    let current = Self.currentModelID(from: result)
                    if current != matched.id {
                        sessionRequestID += 1
                        let request: [String: Any]
                        if profile == .openCode {
                            request = ["jsonrpc": "2.0", "id": sessionRequestID, "method": "session/set_config_option", "params": ["sessionId": acpID, "configId": "model", "value": matched.id]]
                        } else {
                            request = ["jsonrpc": "2.0", "id": sessionRequestID, "method": "session/set_model", "params": ["sessionId": acpID, "modelId": matched.id]]
                        }
                        try Self.write(request, to: runningTransport.input)
                        _ = try Self.readResponse(id: sessionRequestID, from: reader, input: runningTransport.input)
                    }

                    sessionRequestID += 1
                    try Self.write(["jsonrpc": "2.0", "id": sessionRequestID, "method": "session/prompt", "params": ["sessionId": acpID, "prompt": [["type": "text", "text": prompt]]]], to: runningTransport.input)
                    try await readPromptResponse(id: sessionRequestID, sessionID: sessionID, owner: registeredOwner, workspace: canonicalWorkspace, allowFileModification: allowFileModification, from: reader, input: runningTransport.input, continuation: continuation)
                    runningTransport.finish()
                    let didCancel = unregister(registeredOwner, start: start, sessionID: sessionID)
                    continuation.yield(didCancel ? .cancelled : .completed)
                } catch {
                    let didCancel = unregister(owner, start: start, sessionID: sessionID)
                    transport?.cancel()
                    if didCancel || transport?.terminationReason == .cancelled { continuation.yield(.cancelled) }
                    else if transport?.terminationReason == .timedOut { continuation.yield(.failed("\(profile.displayName) timed out.")) }
                    else if transport?.terminationReason == .outputLimitExceeded { continuation.yield(.failed("\(profile.displayName) output exceeded its limit.")) }
                    else { continuation.yield(.failed((error as? HarnessError)?.text ?? error.localizedDescription)) }
                }
                try? FileManager.default.removeItem(at: scratchDirectory)
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
        cancelPendingPermissions(target.metadata.pendingPermissionIDs)
        if let acpID = target.metadata.providerSessionID {
            try? Self.write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": acpID]], to: target.input)
        }
        target.process?.cancel(after: 0.25)
    }

    @discardableResult
    public func respondToPermission(sessionID: UUID, requestID: UUID, optionID: String?) -> Bool {
        lock.lock()
        let pending = pendingPermissions[requestID]
        lock.unlock()
        guard pending?.sessionID == sessionID else { return false }
        return pending?.resolve(optionID: optionID) == true
    }

    public static func bestMatch(for requestedModel: String, in models: [HarnessModel]) -> HarnessModel? {
        if let exact = models.first(where: {
            $0.id.caseInsensitiveCompare(requestedModel) == .orderedSame
                || $0.name.caseInsensitiveCompare(requestedModel) == .orderedSame
        }) { return exact }
        let requested = modelKey(requestedModel)
        return models.first { modelKey($0.name) == requested || modelKey($0.id) == requested }
    }

    public static func modelKey(_ value: String) -> String {
        let leaf = value.split(separator: "/").last.map(String.init) ?? value
        return leaf.split(separator: ":").last.map(String.init)?.lowercased() ?? leaf.lowercased()
    }

    private func sandboxedLaunch(
        executableURL: URL,
        sandboxExecutableURL: URL?,
        workspace: URL,
        scratchDirectory: URL,
        allowFileModification: Bool = true
    ) throws -> HarnessSandbox.LaunchConfiguration {
        let runtimeDirectories = runtimeDirectoryCandidates().filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return try HarnessSandbox.writeRestrictedLaunch(
            command: executableURL,
            arguments: profile.arguments(workspace: workspace),
            writableDirectories: (allowFileModification ? [workspace] : []) + [scratchDirectory] + runtimeDirectories,
            writablePaths: runtimeFileCandidates(),
            sandboxExecutableURL: sandboxExecutableURL
        )
    }

    private static func hermesHome() -> URL {
        if let override = ProcessInfo.processInfo.environment["HERMES_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes", isDirectory: true)
    }

    private func runtimeDirectoryCandidates() -> [URL] {
        switch profile {
        case .grok:
            let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok", isDirectory: true)
            return ["sessions", "logs", "upload_queue", "docs"].map { home.appendingPathComponent($0, isDirectory: true) }
        case .openCode:
            let home = URL(fileURLWithPath: NSHomeDirectory())
            return [
                home.appendingPathComponent(".local/share/opencode/log", isDirectory: true),
                home.appendingPathComponent(".local/share/opencode/storage", isDirectory: true),
                home.appendingPathComponent(".local/share/opencode/snapshot", isDirectory: true),
                home.appendingPathComponent(".local/share/opencode/tool-output", isDirectory: true),
                home.appendingPathComponent(".local/share/opencode/repos", isDirectory: true),
                home.appendingPathComponent(".local/state/opencode", isDirectory: true)
            ]
        case .hermes:
            let home = Self.hermesHome()
            return ["logs", "sessions", "checkpoints", "cache", "audio_cache", "image_cache", "browser_screenshots", "sandboxes"].map {
                home.appendingPathComponent($0, isDirectory: true)
            }
        }
    }

    private func runtimeFileCandidates() -> [URL] {
        switch profile {
        case .grok:
            let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok", isDirectory: true)
            return [
                "active_sessions.json", "active_sessions.lock", ".config-init.lock",
                "auth.json", "auth.json.lock",
                "worktrees.db", "worktrees.db-wal", "worktrees.db-shm", "worktrees.db-journal"
            ].map { home.appendingPathComponent($0) }
        case .openCode:
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let share = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
            let cache = home.appendingPathComponent(".cache/opencode", isDirectory: true)
            return [
                share.appendingPathComponent("auth.json"),
                share.appendingPathComponent("opencode.db"),
                share.appendingPathComponent("opencode.db-wal"),
                share.appendingPathComponent("opencode.db-shm"),
                share.appendingPathComponent("opencode.db-journal"),
                cache.appendingPathComponent("models.json"),
                cache.appendingPathComponent("version")
            ]
        case .hermes:
            let home = Self.hermesHome()
            return [
                "state.db", "state.db-wal", "state.db-shm", "state.db-journal",
                ".skills_prompt_snapshot.json", ".update_check", "auth.lock",
                "kanban.db", "kanban.db-wal", "kanban.db-shm", "kanban.db-journal"
            ].map { home.appendingPathComponent($0) }
        }
    }

    private func scratchDirectory(for sessionID: UUID) -> URL {
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        return LatticeApplicationSupport.productRootURL().appendingPathComponent("HarnessScratch/\(profile.displayName)/\(sessionID.uuidString.lowercased())", isDirectory: true)
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

    private func setACPSessionID(_ acpID: String, owner: InteractiveProcessRegistry.Owner, for id: UUID) {
        processRegistry.updateMetadata(owner, sessionID: id) { $0.providerSessionID = acpID }
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

    private func register(_ pending: PendingPermission) {
        guard processRegistry.updateMetadata(pending.owner, sessionID: pending.sessionID, {
            $0.pendingPermissionIDs.insert(pending.requestID)
        }) else {
            _ = pending.resolve(optionID: nil)
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

    private func cancelPendingPermissions(_ requestIDs: Set<UUID>) {
        lock.lock()
        let pending = requestIDs.compactMap { pendingPermissions[$0] }
        lock.unlock()
        pending.forEach { $0.resolve(optionID: nil) }
    }

    private static func initializeRequest(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "initialize", "params": [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
            "clientInfo": ["name": "lattice", "title": "Lattice", "version": "0.1.0"]
        ]]
    }

    private static func sessionRequest(id: Int, method: String, workspace: URL, threadID: String?) -> [String: Any] {
        var params: [String: Any] = ["cwd": workspace.path, "mcpServers": []]
        if let threadID { params["sessionId"] = threadID }
        return ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    private static func readResponse(id: Int, from reader: BoundedJSONLineReader, input: FileHandle) throws -> [String: Any] {
        while let object = try reader.next() {
            if object["method"] != nil { try answerNoninteractiveServerRequest(object, to: input); continue }
            if (object["id"] as? NSNumber)?.intValue == id { return object }
        }
        throw HarnessError.message("ACP agent ended before responding.")
    }

    private static func answerNoninteractiveServerRequest(_ object: [String: Any], to input: FileHandle) throws {
        guard let id = object["id"], let method = object["method"] as? String else { return }
        if method == "session/request_permission" {
            try write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]], to: input)
        } else {
            try write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported client request: \(method)"]], to: input)
        }
    }

    private func readPromptResponse(id: Int, sessionID: UUID, owner: InteractiveProcessRegistry.Owner, workspace: URL, allowFileModification: Bool, from reader: BoundedJSONLineReader, input: FileHandle, continuation: AsyncStream<AgentEvent>.Continuation) async throws {
        while let object = try reader.next() {
            if object["method"] as? String == "session/update" {
                let update = ((object["params"] as? [String: Any])?["update"] as? [String: Any])
                if update?["sessionUpdate"] as? String == "agent_message_chunk",
                   let content = update?["content"] as? [String: Any], let text = content["text"] as? String {
                    continuation.yield(.assistantDelta(text))
                }
                if let event = HarnessToolEventDecoder.hermesEvent(from: object, workspace: workspace) {
                    continuation.yield(event)
                }
                continue
            }
            if object["method"] != nil { try await answerServerRequest(object, sessionID: sessionID, owner: owner, workspace: workspace, allowFileModification: allowFileModification, to: input, continuation: continuation); continue }
            if (object["id"] as? NSNumber)?.intValue == id {
                if let error = object["error"] as? [String: Any] { throw HarnessError.message(error["message"] as? String ?? "Hermes prompt failed.") }
                return
            }
        }
        throw HarnessError.message("ACP agent ended before completing the response.")
    }

    private func answerServerRequest(_ object: [String: Any], sessionID: UUID, owner: InteractiveProcessRegistry.Owner, workspace: URL, allowFileModification: Bool, to input: FileHandle, continuation: AsyncStream<AgentEvent>.Continuation) async throws {
        guard let id = object["id"], let method = object["method"] as? String else { return }
        guard method == "session/request_permission", let request = Self.permissionRequest(from: object, workspace: workspace) else {
            try Self.write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported client request: \(method)"]], to: input)
            return
        }
        if !allowFileModification, let kind = request.toolRequest?.kind, [.write, .command, .destructive, .credential, .unknown].contains(kind) {
            try Self.write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]], to: input)
            throw HarnessError.message("Provider file writes and commands are disabled during Lattice self-edit.")
        }
        let pending = PendingPermission(sessionID: sessionID, owner: owner, requestID: request.id, optionIDs: Set(request.options.map(\.id)))
        register(pending)
        continuation.yield(.permissionRequested(request))
        let result = await pending.wait(timeoutNanoseconds: permissionTimeoutNanoseconds)
        removePendingPermission(request.id, owner: owner, sessionID: sessionID)
        let outcome: [String: Any]
        switch result {
        case .resolved(.selected(let optionID)):
            outcome = ["outcome": "selected", "optionId": optionID]
        case .resolved(.cancelled):
            outcome = ["outcome": "cancelled"]
        case .timedOut:
            outcome = ["outcome": "cancelled"]
            try? Self.write(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]], to: input)
            throw HarnessError.message(PermissionTimeout.message)
        }
        try Self.write(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]], to: input)
    }

    public static func permissionRequest(from object: [String: Any], workspace: URL? = nil) -> ApprovalRequest? {
        guard object["method"] as? String == "session/request_permission",
              let params = object["params"] as? [String: Any],
              let toolCall = params["toolCall"] as? [String: Any],
              let rawOptions = params["options"] as? [[String: Any]] else { return nil }
        let options = rawOptions.compactMap { value -> ApprovalOption? in
            guard let id = value["optionId"] as? String,
                  let name = value["name"] as? String,
                  let kind = value["kind"] as? String else { return nil }
            return ApprovalOption(id: id, name: name, kind: kind)
        }
        guard !options.isEmpty else { return nil }
        let title = (toolCall["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestTitle = title?.isEmpty == false ? title! : "Agent permission requested"
        let detail = permissionDetail(toolCall: toolCall)
        return ApprovalRequest(
            title: requestTitle,
            detail: detail,
            options: options,
            toolRequest: toolRequest(from: toolCall, title: requestTitle, detail: detail, workspace: workspace)
        )
    }

    private static func toolRequest(from toolCall: [String: Any], title: String, detail: String, workspace: URL?) -> ToolRequest {
        let rawInput = toolCall["rawInput"] as? [String: Any] ?? [:]
        return ToolRequest(
            kind: toolKind(
                explicitKind: toolCall["kind"] as? String,
                title: title,
                command: rawInput["command"] as? String
            ),
            title: title,
            detail: detail,
            workspaceScoped: WorkspacePathScope.isWorkspaceScoped(toolCall: toolCall, workspace: workspace),
            reversible: false
        )
    }

    private static func toolKind(explicitKind: String?, title: String, command: String?) -> ToolRequest.Kind {
        let explicitName = explicitKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let name = [explicitName, title, command]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if name.contains("credential") || name.contains("secret") || name.contains("password") || name.contains("token") || name.contains("api key") || name.contains("keychain") {
            return .credential
        }
        if name.contains("delete") || name.contains("remove") { return .destructive }
        if name.contains("write") || name.contains("edit") || name.contains("patch") || name.contains("move") { return .write }
        if name.contains("bash") || name.contains("terminal") || name.contains("execute") || name.contains("command") || name.contains("run") { return .command }
        if name.contains("web") || name.contains("fetch") || name.contains("network") { return .network }
        if name.contains("browser") || name.contains("automation") { return .automation }
        if ["read", "read_file", "list", "list_files", "search", "grep", "glob", "find", "stat", "inspect", "view"].contains(explicitName) {
            return .read
        }
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .command
        }
        return .unknown
    }

    private static func permissionDetail(toolCall: [String: Any]) -> String {
        if let rawInput = toolCall["rawInput"] as? [String: Any] {
            let command = rawInput["command"] as? String
            let description = rawInput["description"] as? String
            if let command, !command.isEmpty {
                return [description, "$ \(command)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if JSONSerialization.isValidJSONObject(rawInput),
               let data = try? JSONSerialization.data(withJSONObject: rawInput, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return String(text.prefix(600))
            }
        }
        if let text = firstText(in: toolCall["content"]) { return String(text.prefix(600)) }
        return toolCall["kind"] as? String ?? "The agent requested permission to continue."
    }

    private static func firstText(in value: Any?) -> String? {
        if let dictionary = value as? [String: Any] {
            if let text = dictionary["text"] as? String, !text.isEmpty { return text }
            for child in dictionary.values {
                if let text = firstText(in: child) { return text }
            }
        } else if let values = value as? [Any] {
            for child in values {
                if let text = firstText(in: child) { return text }
            }
        }
        return nil
    }

    private static func serialized(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func modelsFromOutput(_ data: Data) -> [HarnessModel] {
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let values = models(from: object)
            if !values.isEmpty { return values }
        }
        return []
    }

    private static func write(_ object: [String: Any], to handle: FileHandle?) throws {
        guard let handle else { return }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]); data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func result(from response: [String: Any]) -> [String: Any]? {
        if response["error"] != nil { return nil }
        return response["result"] as? [String: Any]
    }

    private static func isAuthenticationRequired(_ response: [String: Any]) -> Bool {
        guard let error = response["error"] as? [String: Any] else { return false }
        let message = (error["message"] as? String ?? "").lowercased()
        return message.contains("auth") || (error["code"] as? NSNumber)?.intValue == -32000
    }

    private static func models(from response: [String: Any]) -> [HarnessModel] {
        guard let result = result(from: response) else { return [] }
        if let configOptions = result["configOptions"] as? [[String: Any]],
           let modelOption = configOptions.first(where: { $0["category"] as? String == "model" || $0["id"] as? String == "model" }),
           let values = modelOption["options"] as? [[String: Any]] {
            return values.compactMap { value in
                guard let id = value["value"] as? String, let name = value["name"] as? String else { return nil }
                return HarnessModel(id: id, name: name)
            }
        }
        let state = (result["models"] as? [String: Any])
            ?? ((result["_meta"] as? [String: Any])?["modelState"] as? [String: Any])
        guard let state, let values = state["availableModels"] as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard let id = value["modelId"] as? String, let name = value["name"] as? String else { return nil }
            return HarnessModel(id: id, name: name)
        }
    }

    private static func currentModelID(from result: [String: Any]) -> String? {
        if let configOptions = result["configOptions"] as? [[String: Any]],
           let modelOption = configOptions.first(where: { $0["category"] as? String == "model" || $0["id"] as? String == "model" }) {
            return modelOption["currentValue"] as? String
        }
        return (result["models"] as? [String: Any])?["currentModelId"] as? String
    }

    private enum HarnessError: Error {
        case message(String)
        var text: String { if case .message(let text) = self { return text }; return "Harness error" }
    }
}

public typealias HermesACPHarness = ACPHarness
