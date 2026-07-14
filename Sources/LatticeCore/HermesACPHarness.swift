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

        func arguments(workspace: URL, hermesRoute: LatticeHermesWorkRoute? = nil) -> [String] {
            switch self {
            case .hermes:
                guard let hermesRoute else { return ["acp"] }
                return [
                    "--provider", hermesRoute.provider,
                    "--model", hermesRoute.model,
                    "--toolsets", LatticeHermesProfile.workToolPolicy.enabledToolsets.joined(separator: ","),
                    "acp"
                ]
            case .grok: return ["agent", "--no-leader", "stdio"]
            case .openCode: return ["acp", "--pure", "--cwd", workspace.path]
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
    private let hermesProfile: LatticeHermesProfile?
    private let permissionTimeoutNanoseconds: UInt64
    private let lock = NSLock()
    private let processRegistry = InteractiveProcessRegistry()
    private var pendingPermissions: [UUID: PendingPermission] = [:]

    public init(
        profile: Profile = .hermes,
        executableURL: URL? = nil,
        sandboxExecutableURL: URL? = HarnessSandbox.systemExecutableURL,
        permissionTimeout: TimeInterval = 120,
        hermesProfile: LatticeHermesProfile? = nil
    ) {
        self.profile = profile
        self.executableURL = executableURL ?? ExecutableDiscovery.locate(profile.executableName)
        self.sandboxExecutableURL = sandboxExecutableURL
        self.hermesProfile = profile == .hermes ? (hermesProfile ?? LatticeHermesProfile()) : hermesProfile
        self.permissionTimeoutNanoseconds = PermissionTimeout.nanoseconds(for: permissionTimeout)
    }

    public var isInstalled: Bool { executableURL != nil }

    public func hermesReadiness(
        auth: LatticeHermesReadinessState = .unknown,
        catalog: LatticeHermesReadinessState = .unknown
    ) -> LatticeHermesReadiness {
        guard profile == .hermes, let hermesProfile else {
            return LatticeHermesReadiness(
                runtimePresent: false,
                profileConfigured: false,
                auth: .unknown,
                catalog: .unknown
            )
        }
        return hermesProfile.readiness(runtimePresent: isInstalled, auth: auth, catalog: catalog)
    }

    public var profileReadiness: LatticeHermesReadiness {
        hermesReadiness()
    }

    /// User-triggered, bounded validation against Hermes-owned authentication
    /// state inside Lattice's isolated profile. Lattice never reads auth.json.
    public func validateHermesAuthentication(provider: String) async -> Bool {
        guard profile == .hermes,
              let executableURL,
              let hermesProfile,
              [LatticeHermesProvider.openAICodex.rawValue, LatticeHermesProvider.xAIOAuth.rawValue]
                .contains(provider) else { return false }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-hermes-auth-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: scratch,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: scratch) }
            let environment = try hermesProfile.launchEnvironment(temporaryDirectory: scratch)
            let result = await BoundedSubprocess.run(.init(
                executableURL: executableURL,
                arguments: ["auth", "status", provider],
                environment: environment,
                deadline: 20,
                maximumOutputBytes: 32_000
            ))
            guard result.isSuccess else { return false }
            return LatticeHermesProfile.isLoggedInStatusOutput(
                String(decoding: result.combinedOutput, as: UTF8.self)
            )
        } catch {
            return false
        }
    }

    public func models(workspace: URL) async -> [HarnessModel] {
        await modelsResult(workspace: workspace).models
    }

    public func modelsResult(workspace: URL) async -> ProviderCatalogResult<HarnessModel> {
        await modelsResult(
            workspace: workspace,
            hermesRoute: nil,
            systemIdentity: nil,
            opencodeAPIKey: nil
        )
    }

    /// Catalog probe for a configured Hermes Work route. Inputs are explicit so
    /// tests can use a temporary profile and verify the exact child launch.
    public func modelsResult(
        workspace: URL,
        provider: String,
        model: String,
        systemIdentity: String,
        opencodeAPIKey: String? = nil
    ) async -> ProviderCatalogResult<HarnessModel> {
        await modelsResult(
            workspace: workspace,
            hermesRoute: LatticeHermesWorkRoute(provider: provider, model: model),
            systemIdentity: systemIdentity,
            opencodeAPIKey: opencodeAPIKey
        )
    }

    private func modelsResult(
        workspace: URL,
        hermesRoute: LatticeHermesWorkRoute?,
        systemIdentity: String?,
        opencodeAPIKey: String?
    ) async -> ProviderCatalogResult<HarnessModel> {
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
                scratchDirectory: scratchDirectory,
                hermesRoute: hermesRoute,
                systemIdentity: systemIdentity,
                opencodeAPIKey: opencodeAPIKey
            )
            let environment = try launchEnvironment(
                scratchDirectory: scratchDirectory,
                hermesRoute: hermesRoute,
                opencodeAPIKey: opencodeAPIKey
            )
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

    public func stream(
        prompt: String,
        sessionID: UUID,
        threadID: String?,
        workspace: URL,
        requestedModel: String,
        allowFileModification: Bool = true,
        recoveryPrompt: String? = nil,
        recoveryUsesVisibleTranscriptHandoff: Bool = false,
        recoveryDeliveryIssue: String? = nil
    ) -> AsyncStream<AgentEvent> {
        stream(
            prompt: prompt,
            sessionID: sessionID,
            threadID: threadID,
            workspace: workspace,
            requestedModel: requestedModel,
            hermesRoute: nil,
            systemIdentity: nil,
            opencodeAPIKey: nil,
            allowFileModification: allowFileModification,
            recoveryPrompt: recoveryPrompt,
            recoveryUsesVisibleTranscriptHandoff: recoveryUsesVisibleTranscriptHandoff,
            recoveryDeliveryIssue: recoveryDeliveryIssue
        )
    }

    /// Start one Hermes Work ACP run with caller-owned identity and route.
    /// Provider/model values pass to Hermes unchanged. No `--yolo` or hook
    /// acceptance flag is ever added by this harness.
    public func stream(
        prompt: String,
        sessionID: UUID,
        threadID: String?,
        workspace: URL,
        provider: String,
        model: String,
        systemIdentity: String,
        opencodeAPIKey: String? = nil,
        allowFileModification: Bool = true,
        recoveryPrompt: String? = nil,
        recoveryUsesVisibleTranscriptHandoff: Bool = false,
        recoveryDeliveryIssue: String? = nil
    ) -> AsyncStream<AgentEvent> {
        stream(
            prompt: prompt,
            sessionID: sessionID,
            threadID: threadID,
            workspace: workspace,
            requestedModel: model,
            hermesRoute: LatticeHermesWorkRoute(provider: provider, model: model),
            systemIdentity: systemIdentity,
            opencodeAPIKey: opencodeAPIKey,
            allowFileModification: allowFileModification,
            recoveryPrompt: recoveryPrompt,
            recoveryUsesVisibleTranscriptHandoff: recoveryUsesVisibleTranscriptHandoff,
            recoveryDeliveryIssue: recoveryDeliveryIssue
        )
    }

    private func stream(
        prompt: String,
        sessionID: UUID,
        threadID: String?,
        workspace: URL,
        requestedModel: String,
        hermesRoute: LatticeHermesWorkRoute?,
        systemIdentity: String?,
        opencodeAPIKey: String?,
        allowFileModification: Bool,
        recoveryPrompt: String?,
        recoveryUsesVisibleTranscriptHandoff: Bool,
        recoveryDeliveryIssue: String?
    ) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let start = processRegistry.beginStart(for: sessionID)
            let task = Task.detached(priority: .userInitiated) { [self] in
                guard let executableURL else {
                    _ = processRegistry.abandonStart(start, sessionID: sessionID)
                    continuation.yield(.failed("\(profile.displayName) is not installed.")); continuation.finish(); return
                }
                let scratchDirectory = scratchDirectory(for: sessionID)
                var transport: BoundedProcessTransport?
                var owner: InteractiveProcessRegistry.Owner?
                do {
                    try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
                    let canonicalWorkspace = try HarnessSandbox.canonicalDirectory(workspace)
                    let launch = try sandboxedLaunch(
                        executableURL: executableURL,
                        sandboxExecutableURL: sandboxExecutableURL,
                        workspace: canonicalWorkspace,
                        scratchDirectory: scratchDirectory,
                        allowFileModification: allowFileModification,
                        hermesRoute: hermesRoute,
                        systemIdentity: systemIdentity,
                        opencodeAPIKey: opencodeAPIKey
                    )
                    let environment = try launchEnvironment(
                        scratchDirectory: scratchDirectory,
                        hermesRoute: hermesRoute,
                        opencodeAPIKey: opencodeAPIKey
                    )
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
                    let reader = BoundedJSONLineReader(runningTransport)
                    try Self.write(Self.initializeRequest(id: 1), to: runningTransport)
                    _ = try Self.readResponse(id: 1, from: reader, transport: runningTransport)

                    var sessionRequestID = 2

                    let storedID: String? = {
                        guard let threadID else { return nil }
                        if threadID.hasPrefix(profile.sessionPrefix) { return String(threadID.dropFirst(profile.sessionPrefix.count)) }
                        return profile == .grok || profile == .openCode ? threadID : nil
                    }()
                    var didRecover = false
                    var recoveryPromptForDelivery: String?
                    let method = storedID == nil ? "session/new" : "session/load"
                    try Self.write(Self.sessionRequest(id: sessionRequestID, method: method, workspace: canonicalWorkspace, threadID: storedID), to: runningTransport)
                    var sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, transport: runningTransport)
                    if profile == .grok, Self.isAuthenticationRequired(sessionResponse) {
                        sessionRequestID += 1
                        try Self.write(["jsonrpc": "2.0", "id": sessionRequestID, "method": "authenticate", "params": ["methodId": "cached_token"]], to: runningTransport)
                        let authResponse = try Self.readResponse(id: sessionRequestID, from: reader, transport: runningTransport)
                        if let error = authResponse["error"] as? [String: Any] {
                            throw HarnessError.message(error["message"] as? String ?? "Grok authentication failed.")
                        }
                        sessionRequestID += 1
                        try Self.write(Self.sessionRequest(id: sessionRequestID, method: method, workspace: canonicalWorkspace, threadID: storedID), to: runningTransport)
                        sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, transport: runningTransport)
                    }
                    if storedID != nil, Self.isStaleSessionRejection(sessionResponse) {
                        guard !processRegistry.isCancelled(registeredOwner, sessionID: sessionID) else {
                            throw HarnessError.message("\(profile.displayName) request cancelled.")
                        }
                        guard let validatedRecoveryPrompt = Self.validatedRecoveryPrompt(
                            recoveryPrompt,
                            usesVisibleTranscriptHandoff: recoveryUsesVisibleTranscriptHandoff,
                            deliveryIssue: recoveryDeliveryIssue
                        ) else {
                            if let recoveryDeliveryIssue {
                                throw HarnessError.message("\(profile.displayName) rejected the saved session, but visible transcript handoff could not be delivered: \(recoveryDeliveryIssue)")
                            }
                            throw HarnessError.message("\(profile.displayName) rejected the saved session, but no visible transcript handoff was available for the replacement session.")
                        }
                        didRecover = true
                        recoveryPromptForDelivery = validatedRecoveryPrompt
                        let reason = Self.responseError(sessionResponse, fallback: "saved session was rejected or expired")
                        continuation.yield(.harnessSessionRecovery(recoveryMessage(reason: reason)))
                        sessionRequestID += 1
                        try Self.write(Self.sessionRequest(id: sessionRequestID, method: "session/new", workspace: canonicalWorkspace, threadID: nil), to: runningTransport)
                        sessionResponse = try Self.readResponse(id: sessionRequestID, from: reader, transport: runningTransport)
                    }
                    guard let result = Self.result(from: sessionResponse),
                          let acpID = (result["sessionId"] as? String) ?? (didRecover ? nil : storedID) else {
                        let reason = Self.responseError(sessionResponse, fallback: "\(profile.displayName) did not return a session ID.")
                        if didRecover {
                            throw HarnessError.message("\(profile.displayName) started recovery, but could not create a fresh provider session: \(reason)")
                        }
                        throw HarnessError.message("\(profile.displayName) could not create a session: \(reason)")
                    }

                    let models = Self.models(from: sessionResponse)
                    let matched = hermesRoute == nil
                        ? Self.bestMatch(for: requestedModel, in: models)
                        : Self.exactMatch(for: requestedModel, in: models)
                    guard let matched else {
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
                        try Self.write(request, to: runningTransport)
                        let modelResponse = try Self.readResponse(id: sessionRequestID, from: reader, transport: runningTransport)
                        guard Self.result(from: modelResponse) != nil else {
                            throw HarnessError.message("\(profile.displayName) could not select model \(matched.id) for its provider session.")
                        }
                    }

                    // Registry-only metadata enables graceful protocol cancellation.
                    // Durable AppState persistence remains gated on the started event below.
                    setACPSessionID(acpID, owner: registeredOwner, for: sessionID)

                    sessionRequestID += 1
                    let promptText: String
                    if didRecover {
                        guard let recoveryPromptForDelivery else {
                            throw HarnessError.message("\(profile.displayName) recovery lost its validated visible transcript handoff.")
                        }
                        promptText = recoveryPromptForDelivery
                    } else {
                        promptText = prompt
                    }
                    try Self.write(["jsonrpc": "2.0", "id": sessionRequestID, "method": "session/prompt", "params": ["sessionId": acpID, "prompt": [["type": "text", "text": promptText]]]], to: runningTransport)
                    try await readPromptResponse(id: sessionRequestID, sessionID: sessionID, owner: registeredOwner, workspace: canonicalWorkspace, allowFileModification: allowFileModification, from: reader, transport: runningTransport, continuation: continuation)
                    continuation.yield(.harnessSessionStarted("\(profile.sessionPrefix)\(acpID)"))
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
        cancelPendingPermissions(target.metadata.pendingPermissionIDs)
        if let acpID = target.metadata.providerSessionID {
            try? Self.write(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": acpID]], to: target.process)
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

    /// Strict Work-route lookup. IDs must match exactly; display names and leaf
    /// model names are never accepted for a new Hermes Work run.
    public static func exactMatch(for requestedModel: String, in models: [HarnessModel]) -> HarnessModel? {
        models.first { $0.id == requestedModel }
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
        allowFileModification: Bool = true,
        hermesRoute: LatticeHermesWorkRoute? = nil,
        systemIdentity: String? = nil,
        opencodeAPIKey: String? = nil
    ) throws -> HarnessSandbox.LaunchConfiguration {
        if profile == .hermes {
            guard let hermesProfile else {
                throw LatticeHermesProfileError.invalidHome("missing Lattice Hermes profile")
            }
            if let hermesRoute {
                guard let systemIdentity else {
                    throw LatticeHermesProfileError.emptySystemIdentity
                }
                try hermesProfile.configure(
                    systemIdentity: systemIdentity,
                    route: hermesRoute,
                    opencodeAPIKey: opencodeAPIKey
                )
            } else {
                try hermesProfile.ensureHome()
            }
        }
        let runtimeDirectories = runtimeDirectoryCandidates().filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return try HarnessSandbox.writeRestrictedLaunch(
            command: executableURL,
            arguments: profile.arguments(workspace: workspace, hermesRoute: hermesRoute),
            writableDirectories: (allowFileModification ? [workspace] : []) + [scratchDirectory] + runtimeDirectories,
            writablePaths: runtimeFileCandidates(),
            sandboxExecutableURL: sandboxExecutableURL
        )
    }

    private func launchEnvironment(
        scratchDirectory: URL,
        hermesRoute: LatticeHermesWorkRoute?,
        opencodeAPIKey: String?
    ) throws -> [String: String] {
        if profile == .hermes {
            guard let hermesProfile else {
                throw LatticeHermesProfileError.invalidHome("missing Lattice Hermes profile")
            }
            return try hermesProfile.launchEnvironment(
                temporaryDirectory: scratchDirectory,
                route: hermesRoute,
                opencodeAPIKey: opencodeAPIKey
            )
        }
        return ChildProcessEnvironmentPolicy.providerOwnedRuntime(
            from: ProcessInfo.processInfo.environment,
            temporaryDirectory: scratchDirectory
        )
    }

    private func hermesHome() -> URL {
        hermesProfile?.homeURL ?? LatticeHermesProfile().homeURL
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
            // Hermes owns runtime state below this Lattice-owned HERMES_HOME.
            // The directory itself is the only writable runtime root needed;
            // Hermes may create its own sessions/logs/cache children.
            return [hermesHome()]
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
            let home = hermesHome()
            return [
                LatticeHermesProfile.configFileName,
                LatticeHermesProfile.soulFileName,
                "state.db", "state.db-wal", "state.db-shm", "state.db-journal"
            ].map { home.appendingPathComponent($0) }
        }
    }

    private func scratchDirectory(for sessionID: UUID) -> URL {
        // Hermes Work must not trigger broad legacy-tree migration: that could
        // copy provider auth/session material into a new process boundary.
        if profile != .hermes {
            LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        }
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

    private static func readResponse(id: Int, from reader: BoundedJSONLineReader, transport: BoundedProcessTransport) throws -> [String: Any] {
        while let object = try reader.next() {
            if object["method"] != nil { try answerNoninteractiveServerRequest(object, to: transport); continue }
            if (object["id"] as? NSNumber)?.intValue == id { return object }
        }
        throw HarnessError.message("ACP agent ended before responding.")
    }

    private static func answerNoninteractiveServerRequest(_ object: [String: Any], to transport: BoundedProcessTransport) throws {
        guard let id = object["id"], let method = object["method"] as? String else { return }
        if method == "session/request_permission" {
            try write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]], to: transport)
        } else {
            try write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported client request: \(method)"]], to: transport)
        }
    }

    private func readPromptResponse(id: Int, sessionID: UUID, owner: InteractiveProcessRegistry.Owner, workspace: URL, allowFileModification: Bool, from reader: BoundedJSONLineReader, transport: BoundedProcessTransport, continuation: AsyncStream<AgentEvent>.Continuation) async throws {
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
            if object["method"] != nil { try await answerServerRequest(object, sessionID: sessionID, owner: owner, workspace: workspace, allowFileModification: allowFileModification, to: transport, continuation: continuation); continue }
            if (object["id"] as? NSNumber)?.intValue == id {
                if let error = object["error"] as? [String: Any] { throw HarnessError.message(error["message"] as? String ?? "Hermes prompt failed.") }
                guard object.keys.contains("result") else {
                    throw HarnessError.message("ACP agent returned a malformed prompt response.")
                }
                return
            }
        }
        throw HarnessError.message("ACP agent ended before completing the response.")
    }

    private func answerServerRequest(_ object: [String: Any], sessionID: UUID, owner: InteractiveProcessRegistry.Owner, workspace: URL, allowFileModification: Bool, to transport: BoundedProcessTransport, continuation: AsyncStream<AgentEvent>.Continuation) async throws {
        guard let id = object["id"], let method = object["method"] as? String else { return }
        guard method == "session/request_permission", let request = Self.permissionRequest(from: object, workspace: workspace) else {
            try Self.write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported client request: \(method)"]], to: transport)
            return
        }
        if !allowFileModification, let kind = request.toolRequest?.kind, [.write, .command, .destructive, .credential, .unknown].contains(kind) {
            try Self.write(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]], to: transport)
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
            try? Self.writeControl(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]], to: transport)
            throw HarnessError.message(PermissionTimeout.message)
        }
        try Self.writeControl(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]], to: transport)
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

    private static func write(_ object: [String: Any], to transport: BoundedProcessTransport?) throws {
        guard let transport else { return }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]); data.append(0x0A)
        try transport.write(data)
    }


    private static func writeControl(_ object: [String: Any], to transport: BoundedProcessTransport) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]); data.append(0x0A)
        try transport.writeControl(data)
    }

    private static func result(from response: [String: Any]) -> [String: Any]? {
        if response["error"] != nil { return nil }
        return response["result"] as? [String: Any]
    }

    static func isStaleSessionRejection(_ response: [String: Any]) -> Bool {
        guard let error = response["error"] as? [String: Any],
              let message = error["message"] as? String else { return false }
        let normalized = message.lowercased()
        let staleMarkers = [
            "session not found",
            "unknown session",
            "session expired",
            "session has expired",
            "invalid session",
            "no such session",
            "session does not exist",
            "could not find session"
        ]
        return staleMarkers.contains { normalized.contains($0) }
    }

    static func validatedRecoveryPrompt(
        _ prompt: String?,
        usesVisibleTranscriptHandoff: Bool,
        deliveryIssue: String?
    ) -> String? {
        guard usesVisibleTranscriptHandoff,
              deliveryIssue == nil,
              let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return prompt
    }

    private static func responseError(_ response: [String: Any], fallback: String) -> String {
        (response["error"] as? [String: Any])?["message"] as? String ?? fallback
    }

    private func recoveryMessage(reason: String) -> String {
        "\(profile.displayName) provider session could not be resumed (\(reason)). Rebuilding continuity from a bounded visible-transcript handoff; hidden provider context is not restored."
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
