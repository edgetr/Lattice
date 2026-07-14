import Foundation
import Testing
@testable import LatticeCore

@Suite("Code Work Local compatibility")
struct ModeCompatibilityTests {
    @Test func routeMatrixFiltersByModeAndNeverAutoFallsBack() {
        let catalog = ExecutionRouteResolver.catalog(readiness: .validating)

        #expect(catalog.entries(for: .code).count == 4)
        #expect(catalog.entries(for: .work).count == 3)
        #expect(catalog.entries(for: .local).count == 2)
        #expect(catalog.entries(for: .code).allSatisfy { $0.route.mode == .code })
        #expect(catalog.entries(for: .work).allSatisfy { $0.route.mode == .work })
        #expect(catalog.entries(for: .local).allSatisfy { $0.route.mode == .local })

        let explicit = ExecutionRouteResolver.resolve(
            mode: .work,
            providerID: "opencode",
            modelID: "opencode-go:deepseek-v4"
        )
        #expect(explicit == ExecutionRoute(
            mode: .work,
            providerID: "opencode",
            modelID: "opencode-go:deepseek-v4",
            runtimeID: "hermes"
        ))
        #expect(ExecutionRouteResolver.resolve(mode: .local, providerID: "codex", modelID: "gpt-5.5") == nil)
        #expect(ExecutionRouteResolver.resolve(mode: .work, providerID: "ollama", modelID: "qwen3:8b") == nil)
        #expect(ExecutionRouteResolver.resolve(mode: .code, providerID: "codex") == nil)
        #expect(ExecutionRouteResolver.resolve(mode: .code, providerID: "codex", modelID: "   ") == nil)
    }

    @Test func localOnlyFailsClosedWithoutCloudSubstitution() {
        for backend in [
            ChatBackend.codex(model: "gpt-5.5"),
            .grok(model: "grok-4"),
            .openCode(model: "opencode-go/model"),
            .antigravity(model: "gemini-test")
        ] {
            #expect(!SessionPrivacyPolicy.allows(backend, in: .localOnly))
            #expect(SessionPrivacyPolicy.blockedMessage(for: backend, in: .localOnly) == SessionPrivacyPolicy.cloudBlockedMessage)
        }
        #expect(SessionPrivacyPolicy.allows(.appleIntelligence, in: .localOnly))
        #expect(SessionPrivacyPolicy.allows(.ollama(model: "qwen3:8b"), in: .localOnly))
    }

    @Test func v1ArchivesAndLegacySessionsPreserveDirectCodexAndOpenCode() throws {
        for (backend, runtimeID) in [
            (ChatBackend.codex(model: "gpt-5.5"), "codex"),
            (.openCode(model: "opencode-go/model"), "opencode")
        ] {
            let session = LatticeSession(title: "legacy", backend: backend, harnessID: runtimeID)
            var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
            object["executionRoute"] = nil
            let decoded = try JSONDecoder().decode(
                LatticeSession.self,
                from: try JSONSerialization.data(withJSONObject: object)
            )
            #expect(decoded.executionRoute == ExecutionRoute.legacy(for: backend, harnessID: runtimeID))

            let backendRoute: String = switch backend {
            case .codex: "codex"
            case .openCode: "opencode"
            default: fatalError("Unexpected compatibility backend")
            }
            let model = backend.displayName
            let archive = """
            {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"legacy","backendRoute":"\(backendRoute)","backendModel":"\(model)","harnessID":"\(runtimeID)","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}
            """
            let plan = try SessionPortableArchiveImporter.prepareImport(data: Data(archive.utf8), existingSessions: [])
            #expect(plan.session.executionRoute == ExecutionRoute.legacy(for: backend, harnessID: runtimeID))
            #expect(plan.session.executionRoute.providerID == backendRoute)
            #expect(plan.session.executionRoute.runtimeID == runtimeID)
        }
    }

    @Test func v2ArchivePreservesModeProviderModelAndRuntime() throws {
        let routes = [
            (
                backend: ChatBackend.openCode(model: "opencode-go:deepseek-v4"),
                route: ExecutionRoute(mode: .work, providerID: "opencode", modelID: "opencode-go:deepseek-v4", runtimeID: "hermes")
            ),
            (
                backend: ChatBackend.ollama(model: "qwen3:8b"),
                route: ExecutionRoute(mode: .local, providerID: "ollama", modelID: "qwen3:8b", runtimeID: "lattice")
            )
        ]
        for value in routes {
            let source = LatticeSession(title: "route", backend: value.backend, executionRoute: value.route)
            let data = try SessionPortableArchiveExporter.exportData(from: source)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let chat = try #require(object["chat"] as? [String: Any])
            let route = try #require(chat["executionRoute"] as? [String: Any])
            #expect(chat["mode"] as? String == value.route.mode.rawValue)
            #expect(route["mode"] as? String == value.route.mode.rawValue)
            #expect(route["providerID"] as? String == value.route.providerID)
            #expect(route["modelID"] as? String == value.route.modelID)
            #expect(route["runtimeID"] as? String == value.route.runtimeID)

            let imported = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: []).session
            #expect(imported.executionRoute == value.route)
            #expect(imported.backend == value.backend)
        }
    }

    @Test func piEnvelopeKeepsModeAddOnsTrustHierarchyAndAppliedNames() throws {
        let envelope = try LatticeInstructionEnvelope(
            selectedMode: .work,
            workspaceFacts: ["workspace fact"],
            controlFacts: ["control fact"],
            capabilityFacts: ["capability fact"],
            workspaceInstructionsTrusted: true,
            trustedWorkspaceInstructionNames: ["AGENTS.md", "AGENTS.md", "CLAUDE.MD"],
            codeUserAddOn: "code add-on",
            workUserAddOn: "work add-on"
        )

        #expect(envelope.trustedWorkspaceInstructionNames == ["AGENTS.md", "CLAUDE.MD"])
        #expect(envelope.activeUserAddOn == "work add-on")
        #expect(envelope.renderedSystemInstructions.contains("Lattice system context"))
        #expect(envelope.renderedSystemInstructions.contains("not a permission boundary"))
        #expect(envelope.renderedSystemInstructions.contains("User add-on for Work mode"))
        #expect(!envelope.renderedSystemInstructions.contains("code add-on"))
        #expect(throws: LatticeInstructionEnvelopeError.unsupportedWorkspaceInstructionName("README.md")) {
            try LatticeInstructionEnvelope(selectedMode: .code, workspaceInstructionsTrusted: true, trustedWorkspaceInstructionNames: ["README.md"])
        }
    }

    @Test func modeInstructionContractsStayDistinctAndLocalRemainsLightweight() {
        #expect(LatticeProductInstructions.modeInstructions(for: .code).contains("Lattice Code mode operating contract"))
        #expect(LatticeProductInstructions.modeInstructions(for: .code).contains("smallest correct change"))
        #expect(LatticeProductInstructions.modeInstructions(for: .work).contains("Lattice Work mode SOUL"))
        #expect(LatticeProductInstructions.modeInstructions(for: .work).contains("Never invent browsing"))
        #expect(LatticeProductInstructions.modeInstructions(for: .local) == LatticeProductInstructions.piRuntime)

        let codeEnvelope = try! LatticeInstructionEnvelope.default(
            mode: .code,
            workspace: URL(fileURLWithPath: "/tmp/lattice-test-workspace"),
            allowFileModification: false,
            workspaceInstructionsTrusted: false
        )
        let workEnvelope = try! LatticeInstructionEnvelope.default(
            mode: .work,
            workspace: URL(fileURLWithPath: "/tmp/lattice-test-workspace"),
            allowFileModification: false,
            workspaceInstructionsTrusted: false
        )
        #expect(codeEnvelope.renderedSystemInstructions.contains("Lattice Code mode operating contract"))
        #expect(workEnvelope.renderedSystemInstructions.contains("Lattice Work mode SOUL"))
        #expect(!codeEnvelope.renderedSystemInstructions.contains("Lattice Work mode SOUL"))
    }

    @Test func piLaunchKeepsCredentialsOutOfArgvLogsEventsAndPersistence() throws {
        let fixture = try PiFixture()
        defer { fixture.remove() }
        let secret = "pi-opencode-secret-test-value"
        let harness = PiRPCHarness(
            executableURL: fixture.executable,
            permissionExtensionURL: fixture.root.appendingPathComponent("permission.js"),
            sandboxExecutableURL: fixture.sandbox,
            applicationSupportDirectory: fixture.root.appendingPathComponent("support")
        )
        let plan = try harness.makeLaunchPlan(
            sessionID: UUID(),
            workspace: fixture.workspace,
            provider: "opencode",
            model: "opencode-go/model",
            openCodeAPIKey: secret
        )

        #expect(plan.piArguments.contains("--provider"))
        #expect(plan.piArguments.contains("opencode-go"))
        #expect(!plan.arguments.joined(separator: " ").contains(secret))
        #expect(!plan.logSafeArguments.joined(separator: " ").contains(secret))
        #expect(plan.environment["OPENCODE_API_KEY"] == secret)
        #expect(plan.logSafeEnvironment["OPENCODE_API_KEY"] == "<redacted>")
        #expect(!String(decoding: try Data(contentsOf: plan.instructionFileURL), as: UTF8.self).contains(secret))

        let codexPlan = try harness.makeLaunchPlan(
            sessionID: UUID(),
            workspace: fixture.workspace,
            provider: "codex",
            model: "gpt-5.5",
            openCodeAPIKey: secret
        )
        #expect(codexPlan.environment["OPENCODE_API_KEY"] == nil)

        let diagnostic = ProviderEventDiagnostic(provider: "Pi", reason: "Credential boundary", fields: ["OPENCODE_API_KEY"])
        #expect(!diagnostic.detail.contains(secret))
        let session = LatticeSession(title: "secret-free", backend: .openCode(model: "opencode-go/model"), actions: [
            SessionAction(messageID: UUID(), kind: .diagnostic, title: diagnostic.title, detail: diagnostic.detail, status: .failed)
        ])
        let archive = try SessionPortableArchiveExporter.exportData(from: session)
        #expect(!String(decoding: archive, as: UTF8.self).contains(secret))
    }

    @Test func hermesProfileIsolatedToolsAndReadinessFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-hermes-compat-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = LatticeHermesProfile(hermesHome: root.appendingPathComponent("profile", isDirectory: true))
        let route = LatticeHermesWorkRoute(provider: "opencode-go", model: "opencode-go:deepseek-v4")
        try profile.configure(systemIdentity: "Work identity", route: route)
        let config = try String(contentsOf: profile.configURL, encoding: .utf8)

        #expect(config.contains("provider: \"opencode-go\""))
        #expect(config.contains("default: \"opencode-go:deepseek-v4\""))
        #expect(config.contains("- \"browser\""))
        #expect(config.contains("- \"file\""))
        #expect(config.contains("- \"terminal\""))
        #expect(config.contains("- \"credentials\""))
        #expect(config.contains("- \"secrets\""))
        #expect(config.contains("- \"financial\""))
        #expect(!config.contains("auth.json"))
        #expect(!config.contains("state.db"))
        #expect(profile.readiness(runtimePresent: true, auth: .unknown, catalog: .unknown).isReady == false)
        #expect(profile.readiness(runtimePresent: true, auth: .validated, catalog: .validated).isReady)
        #expect(HermesACPHarness.exactMatch(for: "opencode-go:deepseek-v4", in: [HarnessModel(id: "opencode-go:deepseek-v4", name: "DeepSeek")])?.id == "opencode-go:deepseek-v4")
        #expect(HermesACPHarness.exactMatch(for: "deepseek-v4", in: [HarnessModel(id: "opencode-go:deepseek-v4", name: "DeepSeek")] ) == nil)
    }

    @Test func hermesOpenCodeUsesProviderSpecificCredentialNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-hermes-env-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = LatticeHermesProfile(hermesHome: root.appendingPathComponent("profile", isDirectory: true))
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let go = try profile.launchEnvironment(
            base: ["PATH": "/usr/bin", "OPENAI_API_KEY": "parent-secret"],
            temporaryDirectory: scratch,
            route: LatticeHermesWorkRoute(provider: "opencode-go", model: "opencode-go:model"),
            opencodeAPIKey: "go-secret"
        )
        #expect(go["OPENCODE_GO_API_KEY"] == "go-secret")
        #expect(go["OPENCODE_API_KEY"] == nil)
        #expect(go["OPENAI_API_KEY"] == nil)

        let zen = try profile.launchEnvironment(
            base: ["PATH": "/usr/bin"],
            temporaryDirectory: scratch,
            route: LatticeHermesWorkRoute(provider: "opencode-zen", model: "opencode-zen:model"),
            opencodeAPIKey: "zen-secret"
        )
        #expect(zen["OPENCODE_ZEN_API_KEY"] == "zen-secret")
        #expect(zen["OPENCODE_API_KEY"] == nil)
    }

    @Test func grokAndAntigravityUseVisibleTaskLabelNotSystemPrompt() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Lattice/AppState.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("Lattice task context (visible task guidance; not a system prompt):"))
        #expect(source.contains("session.executionRoute.runtimeID == \"pi\" || session.executionRoute.runtimeID == \"hermes\" || session.executionRoute.mode == .local"))
        #expect(source.contains("taskContext = \"\""))
    }

    @Test func modeAndModelLockAfterFirstUserMessage() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Lattice/AppState.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("var isSelectedSessionRouteLocked"))
        #expect(source.contains("messages.contains(where: { $0.role == .user }) == true"))
        #expect(source.contains("func selectComposerMode(_ mode: ConversationMode)"))
        #expect(source.contains("func selectComposerModel(_ option: ComposerModelOption)"))
        #expect(source.contains("guard !isComposerRouteLocked else { return }"))
    }

    @Test func selfEditCodexIsReadOnlyAndOnRequest() {
        let route = CodexProviderExecutionRoute.resolve(
            policy: SelfEditProviderLaunchPolicy.codexExecutionPolicy,
            workspaceWrite: SelfEditProviderLaunchPolicy.codexWorkspaceWrite
        )
        #expect(SelfEditProviderLaunchPolicy.codexExecutionPolicy == .ask)
        #expect(!SelfEditProviderLaunchPolicy.codexWorkspaceWrite)
        #expect(route.approvalPolicy == "on-request")
        #expect(route.sandbox == "read-only")
    }

    @Test func installerHashFailureInterruptionAndRollbackStayObservable() throws {
        let body = Data("#!/bin/sh\necho install\n".utf8)
        let trust = RemoteInstallerScriptPolicy.trust(for: body, expectedSHA256Hex: String(repeating: "0", count: 64))
        if case .digestMismatch = trust {
            #expect(RemoteInstallerScriptPolicy.executionMessage(for: trust) != nil)
        } else {
            Issue.record("Expected installer digest mismatch")
        }

        let running = SessionAction(messageID: UUID(), kind: .tool, title: "running", detail: "", status: .running)
        let waiting = SessionAction(messageID: UUID(), kind: .approval, title: "waiting", detail: "", status: .waiting)
        let restored = SessionPersistence.restoreRuntimeState([
            LatticeSession(title: "interrupted", backend: .codex(model: "gpt"), actions: [running, waiting], isStreaming: true)
        ])
        #expect(restored.first?.isStreaming == false)
        #expect(restored.first?.actions.allSatisfy { $0.status == .interrupted })

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-rollback-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(id: "com.lattice.rollback", name: "Rollback", version: "1", summary: "Rollback test")
        let data = try JSONEncoder().encode(manifest)
        try store.restoreExtension(manifestID: manifest.id, previousManifestData: data)
        #expect(store.load().first?.version == "1")
        try store.restoreExtension(manifestID: manifest.id, previousManifestData: nil)
        #expect(store.load().isEmpty)
    }

    @Test func ollamaInstallerCancellationEmitsCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-installer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ollama")
        try Data("#!/bin/sh\nprintf 'pulling\\n'\nexec /bin/sleep 60\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let installer = OllamaModelInstaller(executableURL: executable)
        let stream = installer.pull("qwen3:8b")
        let collector = Task { () -> [ModelInstallEvent] in
            var events: [ModelInstallEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        installer.cancel()
        let events = await collector.value
        #expect(events.contains { event in
            if case .cancelled = event { return true }
            return false
        })
    }
}

private struct PiFixture {
    let root: URL
    let workspace: URL
    let executable: URL
    let sandbox: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-pi-compat-" + UUID().uuidString, isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        executable = root.appendingPathComponent("pi")
        sandbox = root.appendingPathComponent("sandbox-exec")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for url in [executable, sandbox] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
