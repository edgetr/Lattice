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
    private final class JSONLineReader {
        private let handle: FileHandle
        private var buffer = Data()

        init(_ handle: FileHandle) {
            self.handle = handle
        }

        func next() throws -> [String: Any]? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    return try JSONSerialization.jsonObject(with: line) as? [String: Any]
                }
                let chunk = handle.availableData
                if chunk.isEmpty {
                    guard !buffer.isEmpty else { return nil }
                    defer { buffer.removeAll(keepingCapacity: true) }
                    return try JSONSerialization.jsonObject(with: buffer) as? [String: Any]
                }
                buffer.append(chunk)
            }
        }
    }

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
        enum Decision { case selected(String), cancelled }

        let sessionID: UUID
        let requestID: UUID
        let optionIDs: Set<String>
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var decision: Decision?

        init(sessionID: UUID, requestID: UUID, optionIDs: Set<String>) {
            self.sessionID = sessionID
            self.requestID = requestID
            self.optionIDs = optionIDs
        }

        @discardableResult
        func resolve(optionID: String?) -> Bool {
            lock.lock()
            guard decision == nil else { lock.unlock(); return false }
            if let optionID {
                guard optionIDs.contains(optionID) else { lock.unlock(); return false }
                decision = .selected(optionID)
            } else {
                decision = .cancelled
            }
            lock.unlock()
            semaphore.signal()
            return true
        }

        func wait() -> Decision {
            semaphore.wait()
            lock.lock(); defer { lock.unlock() }
            return decision ?? .cancelled
        }
    }

    private let executableURL: URL?
    private let sandboxExecutableURL: URL?
    private let profile: Profile
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var inputs: [UUID: FileHandle] = [:]
    private var acpSessionIDs: [UUID: String] = [:]
    private var pendingPermissions: [UUID: PendingPermission] = [:]
    private var cancelled: Set<UUID> = []

    public init(
        profile: Profile = .hermes,
        executableURL: URL? = nil,
        sandboxExecutableURL: URL? = HarnessSandbox.systemExecutableURL
    ) {
        self.profile = profile
        self.executableURL = executableURL ?? ExecutableDiscovery.locate(profile.executableName)
        self.sandboxExecutableURL = sandboxExecutableURL
    }

    public var isInstalled: Bool { executableURL != nil }

    public func models(workspace: URL) async -> [HarnessModel] {
        guard let executableURL else { return [] }
        let sandboxExecutableURL = sandboxExecutableURL
        return await Task.detached {
            let process = Process(); let input = Pipe(); let output = Pipe()
            let scratchDirectory = self.scratchDirectory(for: UUID())
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
                let canonicalWorkspace = try HarnessSandbox.canonicalDirectory(workspace)
                let launch = try self.sandboxedLaunch(
                    executableURL: executableURL,
                    sandboxExecutableURL: sandboxExecutableURL,
                    workspace: canonicalWorkspace,
                    scratchDirectory: scratchDirectory
                )
                process.executableURL = launch.executableURL; process.arguments = launch.arguments
                process.currentDirectoryURL = canonicalWorkspace
                var environment = ProcessInfo.processInfo.environment
                environment["TMPDIR"] = scratchDirectory.path + "/"
                process.environment = environment
                try process.run()
                let reader = JSONLineReader(output.fileHandleForReading)
                try Self.write(Self.initializeRequest(id: 1), to: input.fileHandleForWriting)
                let initializeResponse = try Self.readResponse(id: 1, from: reader, input: input.fileHandleForWriting)
                let initializedModels = Self.models(from: initializeResponse)
                if !initializedModels.isEmpty {
                    if process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    try? FileManager.default.removeItem(at: scratchDirectory)
                    return initializedModels
                }
                try Self.write(Self.sessionRequest(id: 2, method: "session/new", workspace: canonicalWorkspace, threadID: nil), to: input.fileHandleForWriting)
                let response = try Self.readResponse(id: 2, from: reader, input: input.fileHandleForWriting)
                if self.profile == .openCode,
                   let sessionID = Self.result(from: response)?["sessionId"] as? String {
                    try? Self.write(["jsonrpc": "2.0", "id": 3, "method": "session/close", "params": ["sessionId": sessionID]], to: input.fileHandleForWriting)
                    _ = try? Self.readResponse(id: 3, from: reader, input: input.fileHandleForWriting)
                }
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                try? FileManager.default.removeItem(at: scratchDirectory)
                return Self.models(from: response)
            } catch {
                if process.isRunning { process.terminate() }
                if process.isRunning { process.waitUntilExit() }
                try? FileManager.default.removeItem(at: scratchDirectory)
                return []
            }
        }.value
    }

    public func stream(prompt: String, sessionID: UUID, threadID: String?, workspace: URL, requestedModel: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    continuation.yield(.failed("\(profile.displayName) is not installed.")); continuation.finish(); return
                }
                let process = Process(); let input = Pipe(); let output = Pipe()
                let scratchDirectory = scratchDirectory(for: sessionID)
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                do {
                    try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
                    let canonicalWorkspace = try HarnessSandbox.canonicalDirectory(workspace)
                    let launch = try sandboxedLaunch(
                        executableURL: executableURL,
                        sandboxExecutableURL: sandboxExecutableURL,
                        workspace: canonicalWorkspace,
                        scratchDirectory: scratchDirectory
                    )
                    process.executableURL = launch.executableURL; process.arguments = launch.arguments
                    process.currentDirectoryURL = canonicalWorkspace
                    var environment = ProcessInfo.processInfo.environment
                    environment["TMPDIR"] = scratchDirectory.path + "/"
                    process.environment = environment
                    try process.run()
                    register(process: process, input: input.fileHandleForWriting, for: sessionID)
                    let reader = JSONLineReader(output.fileHandleForReading)
                    try Self.write(Self.initializeRequest(id: 1), to: input.fileHandleForWriting)
                    _ = try Self.readResponse(id: 1, from: reader, input: input.fileHandleForWriting)

                    var sessionRequestID = 2

                    let storedID: String? = {
                        guard let threadID else { return nil }
                        if threadID.hasPrefix(profile.sessionPrefix) { return String(threadID.dropFirst(profile.sessionPrefix.count)) }
                        return profile == .grok || profile == .openCode ? threadID : nil
                    }()
                    let method = storedID == nil ? "session/new" : "session/load"
                    try Self.write(Self.sessionRequest(id: sessionRequestID, method: method, workspace: canonicalWorkspace, threadID: storedID), to: input.fileHandleForWriting)
                    var sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, input: input.fileHandleForWriting)
                    if profile == .grok, Self.isAuthenticationRequired(sessionResponse) {
                        sessionRequestID += 1
                        try Self.write(["jsonrpc": "2.0", "id": sessionRequestID, "method": "authenticate", "params": ["methodId": "cached_token"]], to: input.fileHandleForWriting)
                        let authResponse = try Self.readResponse(id: sessionRequestID, from: reader, input: input.fileHandleForWriting)
                        if let error = authResponse["error"] as? [String: Any] {
                            throw HarnessError.message(error["message"] as? String ?? "Grok authentication failed.")
                        }
                        sessionRequestID += 1
                        try Self.write(Self.sessionRequest(id: sessionRequestID, method: method, workspace: canonicalWorkspace, threadID: storedID), to: input.fileHandleForWriting)
                        sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, input: input.fileHandleForWriting)
                    }
                    if Self.result(from: sessionResponse) == nil, storedID != nil {
                        sessionRequestID += 1
                        try Self.write(Self.sessionRequest(id: sessionRequestID, method: "session/new", workspace: canonicalWorkspace, threadID: nil), to: input.fileHandleForWriting)
                        sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, input: input.fileHandleForWriting)
                    }
                    guard let result = Self.result(from: sessionResponse), let acpID = (result["sessionId"] as? String) ?? storedID else {
                        throw HarnessError.message("\(profile.displayName) could not create a session.")
                    }
                    setACPSessionID(acpID, for: sessionID)
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
                        try Self.write(request, to: input.fileHandleForWriting)
                        _ = try Self.readResponse(id: sessionRequestID, from: reader, input: input.fileHandleForWriting)
                    }

                    sessionRequestID += 1
                    try Self.write(["jsonrpc": "2.0", "id": sessionRequestID, "method": "session/prompt", "params": ["sessionId": acpID, "prompt": [["type": "text", "text": prompt]]]], to: input.fileHandleForWriting)
                    try readPromptResponse(id: sessionRequestID, sessionID: sessionID, workspace: canonicalWorkspace, from: reader, input: input.fileHandleForWriting, continuation: continuation)
                    if process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    let didCancel = unregister(sessionID)
                    continuation.yield(didCancel ? .cancelled : .completed)
                } catch {
                    let didCancel = unregister(sessionID)
                    if process.isRunning { process.terminate() }
                    if process.isRunning { process.waitUntilExit() }
                    if didCancel { continuation.yield(.cancelled) }
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
        lock.lock(); cancelled.insert(sessionID); let process = processes[sessionID]; let input = inputs[sessionID]; let acpID = acpSessionIDs[sessionID]; lock.unlock()
        cancelPendingPermissions(for: sessionID)
        if let acpID { try? Self.write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": acpID]], to: input) }
        if let process, process.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning { process.terminate() }
            }
        }
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
        scratchDirectory: URL
    ) throws -> HarnessSandbox.LaunchConfiguration {
        let runtimeDirectories = runtimeDirectoryCandidates().filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return try HarnessSandbox.writeRestrictedLaunch(
            command: executableURL,
            arguments: profile.arguments(workspace: workspace),
            writableDirectories: [workspace, scratchDirectory] + runtimeDirectories,
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

    private func register(process: Process, input: FileHandle, for id: UUID) {
        lock.lock(); processes[id] = process; inputs[id] = input; lock.unlock()
    }

    private func setACPSessionID(_ acpID: String, for id: UUID) {
        lock.lock(); acpSessionIDs[id] = acpID; lock.unlock()
    }

    private func unregister(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        processes[id] = nil; inputs[id] = nil; acpSessionIDs[id] = nil
        pendingPermissions = pendingPermissions.filter { $0.value.sessionID != id }
        return cancelled.remove(id) != nil
    }

    private func register(_ pending: PendingPermission) {
        lock.lock(); pendingPermissions[pending.requestID] = pending; lock.unlock()
    }

    private func removePendingPermission(_ requestID: UUID) {
        lock.lock(); pendingPermissions[requestID] = nil; lock.unlock()
    }

    private func cancelPendingPermissions(for sessionID: UUID) {
        lock.lock()
        let pending = pendingPermissions.values.filter { $0.sessionID == sessionID }
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

    private static func readResponse(id: Int, from reader: JSONLineReader, input: FileHandle) throws -> [String: Any] {
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

    private func readPromptResponse(id: Int, sessionID: UUID, workspace: URL, from reader: JSONLineReader, input: FileHandle, continuation: AsyncStream<AgentEvent>.Continuation) throws {
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
            if object["method"] != nil { try answerServerRequest(object, sessionID: sessionID, workspace: workspace, to: input, continuation: continuation); continue }
            if (object["id"] as? NSNumber)?.intValue == id {
                if let error = object["error"] as? [String: Any] { throw HarnessError.message(error["message"] as? String ?? "Hermes prompt failed.") }
                return
            }
        }
        throw HarnessError.message("ACP agent ended before completing the response.")
    }

    private func answerServerRequest(_ object: [String: Any], sessionID: UUID, workspace: URL, to input: FileHandle, continuation: AsyncStream<AgentEvent>.Continuation) throws {
        guard let id = object["id"], let method = object["method"] as? String else { return }
        guard method == "session/request_permission", let request = Self.permissionRequest(from: object, workspace: workspace) else {
            try Self.write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported client request: \(method)"]], to: input)
            return
        }
        let pending = PendingPermission(sessionID: sessionID, requestID: request.id, optionIDs: Set(request.options.map(\.id)))
        register(pending)
        continuation.yield(.permissionRequested(request))
        let decision = pending.wait()
        removePendingPermission(request.id)
        let outcome: [String: Any]
        switch decision {
        case .selected(let optionID): outcome = ["outcome": "selected", "optionId": optionID]
        case .cancelled: outcome = ["outcome": "cancelled"]
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
        let locations = (toolCall["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        let path = (rawInput["path"] as? String) ?? locations.first
        return ToolRequest(
            kind: toolKind(for: [toolCall["kind"] as? String, title, rawInput["command"] as? String].compactMap { $0 }.joined(separator: " ")),
            title: title,
            detail: detail,
            workspaceScoped: workspace.map { isWorkspaceScoped(path, workspace: $0) } ?? false,
            reversible: false
        )
    }

    private static func toolKind(for value: String) -> ToolRequest.Kind {
        let name = value.lowercased()
        if name.contains("delete") || name.contains("remove") { return .destructive }
        if name.contains("write") || name.contains("edit") || name.contains("patch") || name.contains("move") { return .write }
        if name.contains("bash") || name.contains("terminal") || name.contains("execute") || name.contains("command") || name.contains("run ") { return .command }
        if name.contains("web") || name.contains("fetch") || name.contains("network") { return .network }
        if name.contains("browser") || name.contains("automation") { return .automation }
        return .read
    }

    private static func isWorkspaceScoped(_ path: String?, workspace: URL) -> Bool {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return candidate == root || candidate.hasPrefix(root + "/")
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
