import Foundation
import Darwin
import LatticeCore

@main
struct CoreVerification {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
            checks += 1
        }

        let connectionCacheNow = Date(timeIntervalSince1970: 1_750_000_000)
        let connectionCache = PersistedConnectionState(
            observedAt: connectionCacheNow,
            providers: ["opencode": .init(installed: true, authenticated: true, catalogStatus: .loaded, runnableModelCount: 1)],
            openCodeCredentialRecorded: true
        )
        if let data = PersistedConnectionStatePolicy.encode(connectionCache) {
            expect(
                PersistedConnectionStatePolicy.hydrate(data, now: connectionCacheNow) == .fresh(connectionCache),
                "Fresh secret-free connection state hydrates for relaunch continuity"
            )
            expect(
                !PersistedConnectionStatePolicy.hydrate(data, now: connectionCacheNow).canAuthorizeExecution,
                "Persisted connection state never authorizes execution"
            )
            expect(
                PersistedConnectionStatePolicy.hydrate(data, now: connectionCacheNow.addingTimeInterval(3_600), maximumAge: 60) == .stale(connectionCache),
                "Stale persisted readiness is invalidated"
            )
        } else {
            expect(false, "Secret-free connection state encodes")
        }

        var scheduler = AgentTaskScheduler(
            limits: .init(global: 1, perWorkspace: 1, providerCaps: ["codex": 1]),
            fairnessInterval: 1
        )
        func scheduledRequest(_ id: UUID, priority: AgentTaskPriority = .normal) -> AgentTaskSchedulerRequest {
            AgentTaskSchedulerRequest(
                id: id,
                sessionID: id,
                resources: .init(workspaceID: "verify-workspace", providerID: "codex", routeID: "codex/openai"),
                priority: priority
            )
        }
        let scheduledFirst = UUID(), scheduledLow = UUID(), scheduledHigh = UUID()
        expect(scheduler.submit(scheduledRequest(scheduledFirst)) == [scheduledFirst], "Scheduler admits within global and workspace limits")
        expect(scheduler.submit(scheduledRequest(scheduledLow, priority: .low)).isEmpty, "Scheduler queues work over its limits")
        expect(scheduler.submit(scheduledRequest(scheduledHigh, priority: .high)).isEmpty, "Scheduler queues priority work without exceeding capacity")
        expect(scheduler.finish(scheduledFirst) == [scheduledHigh], "Scheduler admits high priority work first")
        expect(scheduler.waitForApproval(scheduledHigh, releasesExecutionSlot: true) == [scheduledLow], "Approval waiting safely releases execution capacity")
        expect(scheduler.resolveApproval(scheduledHigh).isEmpty, "Approval resumption waits to reacquire capacity")
        expect(scheduler.finish(scheduledLow) == [scheduledHigh], "Approval resumption reacquires capacity deterministically")
        var recoveredScheduler = AgentTaskScheduler()
        recoveredScheduler.recover(.init(entries: [scheduledRequest(UUID(), priority: .high)]))
        expect(recoveredScheduler.snapshots.allSatisfy { $0.state == .recoveryHeld }, "Recovered queue metadata is held and never automatically replayed")
        expect(HarnessReadinessAuthenticationPhase.afterTerminalOpen(succeeded: true).action == .validate, "Authentication continuation uses typed validation state instead of display copy")
        expect(HarnessReadinessAuthenticationPhase.afterValidation().action == .signIn, "Authentication continuation resets after validation")

        var adjustableScheduler = AgentTaskScheduler(limits: .init(global: 1, perWorkspace: 1))
        let adjustableFirst = UUID(), adjustableSecond = UUID()
        _ = adjustableScheduler.submit(.init(
            id: adjustableFirst,
            sessionID: adjustableFirst,
            resources: .init(workspaceID: "one", providerID: "codex", routeID: "codex/openai")
        ))
        _ = adjustableScheduler.submit(.init(
            id: adjustableSecond,
            sessionID: adjustableSecond,
            resources: .init(workspaceID: "two", providerID: "grok", routeID: "grok/xai")
        ))
        expect(adjustableScheduler.updateLimits(.init(global: 2, perWorkspace: 1)) == [adjustableSecond], "Increasing the global scheduler limit admits queued work")
        expect(adjustableScheduler.updateLimits(.init(global: 1, perWorkspace: 1)).isEmpty, "Lowering scheduler limits never preempts active work")

        let layoutScreen = WorkspaceWindowFrame(x: 0, y: 0, width: 1440, height: 900)
        let defaultLayout = WorkspaceLayoutStatePolicy.restoredState(
            for: "main",
            in: WorkspaceLayoutArchive(),
            visibleScreens: [layoutScreen]
        )
        expect(defaultLayout.selectedPage == "conversations" && defaultLayout.windowFrame == nil, "Workspace layout starts from safe non-sensitive defaults")
        let legacyLayout = Data(#"{"schemaVersion":1,"selectedPage":"models","sidebarVisible":false,"sidebarWidth":205,"inspectorVisible":true,"inspectorWidth":370,"primarySplitWidth":310,"windowFrame":null,"windowIsMaximized":false}"#.utf8)
        let migratedLayout = WorkspaceLayoutStatePolicy.decodeArchive(legacyLayout)
        expect(migratedLayout.windows["main"]?.selectedPage == "models" && migratedLayout.windows["main"]?.sidebarVisibility == "doubleColumn", "Legacy workspace layout migrates into the keyed archive")
        var keyedLayouts = WorkspaceLayoutArchive()
        keyedLayouts = WorkspaceLayoutStatePolicy.updating(keyedLayouts, key: "one", state: .init(selectedPage: "projects"))
        keyedLayouts = WorkspaceLayoutStatePolicy.updating(keyedLayouts, key: "two", state: .init(selectedPage: "connections"))
        let roundTrippedLayouts = WorkspaceLayoutStatePolicy.decodeArchive(WorkspaceLayoutStatePolicy.encodeArchive(keyedLayouts))
        expect(roundTrippedLayouts.windows["one"]?.selectedPage == "projects" && roundTrippedLayouts.windows["two"]?.selectedPage == "connections", "Workspace layout keys remain isolated across persistence")
        let clampedLayout = WorkspaceLayoutStatePolicy.clamped(
            WorkspaceLayoutState(
                sidebarWidth: -1,
                inspectorVisible: true,
                inspectorWidth: 9_000,
                primarySplitSizes: [1],
                windowFrame: .init(x: 3_000, y: -900, width: 2_000, height: 1_200)
            ),
            visibleScreens: [layoutScreen],
            availableContentWidth: 1_000
        )
        expect(clampedLayout.windowFrame == layoutScreen && !clampedLayout.inspectorVisible && clampedLayout.primarySplitSizes == [220], "Workspace frames and split sizes clamp to current usable geometry")

        let transportRoundTrip = await BoundedSubprocess.performOffCooperativeExecutor {
            let transport = BoundedProcessTransport(request: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "IFS= read -r value; printf '%s\\n' \"$value\""],
                deadline: 2,
                maximumOutputBytes: 1024
            ))
            do {
                try transport.start()
                try transport.write(Data("transport-ok\n".utf8))
                let value = try transport.readLine().map { String(decoding: $0, as: UTF8.self) }
                transport.finish()
                return value
            } catch {
                transport.cancel()
                return nil
            }
        }
        expect(transportRoundTrip == "transport-ok", "Interactive transport preserves parent writer and reader")

        let fastExitOutput = await BoundedSubprocess.performOffCooperativeExecutor {
            let transport = BoundedProcessTransport(request: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'buffered-fast-exit\\n'"],
                deadline: 2,
                maximumOutputBytes: 1024
            ))
            do {
                try transport.start()
                let value = try transport.readLine().map { String(decoding: $0, as: UTF8.self) }
                transport.finish()
                return value
            } catch {
                transport.cancel()
                return nil
            }
        }
        expect(fastExitOutput == "buffered-fast-exit", "Fast exit retains buffered interactive output")

        let editChat = UUID()
        let otherChat = UUID()
        let editContext = MessageEditContext(sessionID: editChat, messageID: UUID())
        expect(editContext.belongs(to: editChat), "Message edit remains scoped to its originating chat")
        expect(!editContext.belongs(to: otherChat), "Message edit does not leak into another chat")
        expect(!editContext.belongs(to: nil), "Message edit is cancelled when no chat is selected")
        let editBegin = MessageEditDraftState.begin(sessionID: editChat, messageID: UUID(), messageText: "edited", currentDraft: "prior draft", existing: nil)
        expect(editBegin.draft == "edited" && editBegin.state.preservedComposerDraft == "prior draft", "Edit begin preserves prior composer draft")
        let editSwitch = MessageEditDraftState.begin(sessionID: editChat, messageID: UUID(), messageText: "second", currentDraft: "edited", existing: editBegin.state)
        expect(editSwitch.state.preservedComposerDraft == "prior draft", "Switching edit target keeps original preserved draft")
        expect(MessageEditDraftState.cancel(editSwitch.state) == "prior draft", "Canceling edit restores preserved composer draft")
        expect(MessageEditDraftState.complete(editSwitch.state) == "prior draft", "Successful edit send retains pre-edit ordinary draft")
        expect(ComposerSessionDraftTransition.initialComposerDraft(selectedID: editChat, storedDraftForSelected: "restored\n  exactly  ") == "restored\n  exactly  ", "Initial restored selection loads its exact durable draft")
        expect(ComposerSessionDraftTransition.initialComposerDraft(selectedID: otherChat, storedDraftForSelected: "") == "", "Initial restored selection preserves an exact empty draft")
        expect(ComposerSessionDraftTransition.initialComposerDraft(selectedID: nil, storedDraftForSelected: "must not leak") == "", "No initial selection starts with an empty composer")
        let leaveA = ComposerSessionDraftTransition.selecting(from: editChat, to: otherChat, composerText: "alpha\n  draft  ", edit: nil, storedDraftForNext: "beta")
        expect(leaveA.previousSessionDraft == "alpha\n  draft  " && leaveA.composerDraft == "beta", "Two-chat draft switch preserves exact whitespace")
        let leaveEmpty = ComposerSessionDraftTransition.selecting(from: otherChat, to: editChat, composerText: "", edit: nil, storedDraftForNext: "alpha\n  draft  ")
        expect(leaveEmpty.previousSessionDraft == "" && leaveEmpty.composerDraft == "alpha\n  draft  ", "Empty ordinary draft restores exact empty state")
        let editLeave = ComposerSessionDraftTransition.selecting(
            from: editChat,
            to: otherChat,
            composerText: "transient edit text",
            edit: MessageEditDraftState(context: MessageEditContext(sessionID: editChat, messageID: UUID()), preservedComposerDraft: "ordinary A"),
            storedDraftForNext: "ordinary B"
        )
        expect(editLeave.previousSessionDraft == "ordinary A" && editLeave.composerDraft == "ordinary B" && editLeave.clearsEditState, "Chat switch while editing restores ordinary draft and never writes edit text")
        expect(ComposerSessionDraftTransition.clearingOrdinaryDraft() == "", "Ordinary send/queue clears only the ordinary draft")
        expect(ComposerSessionDraftTransition.preservingOrdinaryDraft("keep") == "keep", "Failed validation preserves ordinary draft")
        let streamingTarget = UUID()
        if case .cancelTargetThenDelete(let id) = SessionDeletionPolicy.decision(forStreamingTarget: streamingTarget, isStreaming: true) {
            expect(id == streamingTarget, "Streaming deletion cancels the target session by its own id")
        } else {
            expect(false, "Streaming deletion cancels the target session by its own id")
        }
        expect(SessionDeletionPolicy.decision(forStreamingTarget: streamingTarget, isStreaming: false) == .deleteIdle, "Idle deletion does not cancel a run")
        expect(LatticeApplicationSupport.productFolderName == "Lattice", "Application Support product folder is Lattice")
        expect(LatticeApplicationSupport.legacyProductFolderName == "Nisa", "Legacy Application Support folder remains documented for migration")
        expect(LatticeLegacyBrandCompatibility.extensionManifestOpeningTag == "<nisa-extension-manifest>", "Legacy extension tag is isolated for compatibility reads")
        let selectionPaletteItems = [
            LatticeCommandPaletteItem(id: "new-chat", title: "New Chat", detail: "Start a fresh conversation"),
            LatticeCommandPaletteItem(id: "continue", title: "Continue Response", detail: "Resume", isEnabled: false, disabledReason: "No response"),
            LatticeCommandPaletteItem(id: "models", title: "Show Models", detail: "Catalog")
        ]
        expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: nil, in: selectionPaletteItems) == "new-chat", "Palette selection defaults to first enabled item")
        expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "continue", in: selectionPaletteItems) == "new-chat", "Palette clamp refuses disabled selection")
        expect(LatticeCommandPaletteSelection.selectionAfterHover(hoveredID: "models", in: selectionPaletteItems) == "models", "Palette hover adopts enabled shared selection")
        expect(LatticeCommandPaletteSelection.selectionAfterHover(hoveredID: "continue", in: selectionPaletteItems) == nil, "Palette hover ignores disabled rows without clearing selection")
        expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "new-chat", in: selectionPaletteItems, delta: 1) == "models", "Palette arrow navigation skips disabled items")
        expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "models", in: selectionPaletteItems, delta: -1) == "new-chat", "Palette arrows continue from hovered/shared selection")
        expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "new-chat", in: selectionPaletteItems, delta: -1) == "new-chat", "Palette up-arrow clamps at first enabled row")
        expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "models", in: selectionPaletteItems, delta: 1) == "models", "Palette down-arrow clamps at last enabled row")
        expect(LatticeCommandPaletteSelection.executableSelection(selectedID: "continue", in: selectionPaletteItems) == nil, "Palette refuses to execute disabled selection")
        expect(LatticeCommandPaletteSelection.executableSelection(selectedID: nil, in: selectionPaletteItems) == nil, "Palette refuses to execute empty selection")
        expect(LatticeCommandPaletteSelection.executableSelection(selectedID: "models", in: selectionPaletteItems)?.id == "models", "Palette executes enabled selection")
        let filteredPalette = LatticeCommandPaletteMatcher.filtered(selectionPaletteItems, query: "models")
        expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "new-chat", in: filteredPalette) == "models", "Palette filter clamps to enabled visible row")
        let configuredModels = ProviderModelConfigurationPolicy.items(
            providerID: "codex",
            discoveredModels: [
                ProviderModel(id: "gpt-fast", name: "Fast", description: "Low latency"),
                ProviderModel(id: "gpt-default", name: "Default", isDefault: true)
            ],
            disabledModelIDs: ["codex:retired"],
            selectedModelIDs: ["retired"]
        )
        expect(ProviderModelConfigurationPolicy.providerDefault(in: configuredModels)?.id == "gpt-default", "Model configuration uses only provider-reported default metadata")
        expect(ProviderModelConfigurationPolicy.filtered(configuredModels, query: "low latency").map(\.id) == ["gpt-fast"], "Model configuration filters names, identifiers, and details")
        expect(configuredModels.first(where: { $0.id == "retired" }).map { $0.isSelected && !$0.isDiscovered && !$0.isEnabled } == true, "Selected unavailable models and their visibility preference remain explicit")
        let preservedModelPreferences = ProviderModelConfigurationPolicy.updatedDisabledModelIDs(
            ["grok:kept", "codex:temporarily-missing"],
            providerID: "codex",
            modelID: "gpt-default",
            enabled: false
        )
        expect(preservedModelPreferences == ["grok:kept", "codex:temporarily-missing", "codex:gpt-default"], "Changing one model preserves unrelated and unavailable preferences")
        var modelDisclosure = ProviderModelDisclosureState()
        modelDisclosure.isExpanded = true
        modelDisclosure.query = "gpt"
        modelDisclosure.isExpanded = false
        expect(!modelDisclosure.isExpanded && modelDisclosure.query == "gpt", "Model disclosure starts independently and preserves its search through collapse")
        expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "antigravity") == ["antigravity"], "Antigravity exposes its direct CLI harness route")
        let antigravityModels = [ProviderModel(id: "Gemini 3.5 Flash (High)", name: "Gemini 3.5 Flash (High)", isDefault: true)]
        let antigravitySnapshot = BackendAvailabilitySnapshot(antigravityModels: antigravityModels, antigravityReady: true)
        expect(BackendAvailabilityPolicy.normalize(.antigravity(model: "Retired"), using: antigravitySnapshot) == .antigravity(model: antigravityModels[0].id), "Antigravity stale models normalize to its available default")
        expect(BackendAvailabilityPolicy.initialSelection(persisted: nil) == .ollama(model: ""), "Cold start remains model-less until discovery")
        let selfEditCodexRoute = CodexProviderExecutionRoute.resolve(
            policy: SelfEditProviderLaunchPolicy.codexExecutionPolicy,
            workspaceWrite: SelfEditProviderLaunchPolicy.codexWorkspaceWrite
        )
        expect(selfEditCodexRoute.approvalPolicy == "on-request" && selfEditCodexRoute.sandbox == "read-only", "Self-edit Codex launch is enforced read-only with approvals")
        let importedSkillStore = LatticeSkillStore(rootURL: FileManager.default.temporaryDirectory, globalRoots: [])
        let longImportedSkill = "# Hatch Pet\n\n" + String(repeating: "Detailed validation workflow.\n", count: 1_200)
        let importedSkillIssues = importedSkillStore.validateExistingSkill(id: "hatch-pet", markdown: longImportedSkill)
        expect(longImportedSkill.count > 24_000 && importedSkillIssues.isEmpty, "Full imported skills are not rejected by the generated-skill size limit")
        let disabledOnlyPalette = [
            LatticeCommandPaletteItem(id: "continue", title: "Continue Response", detail: "Resume", isEnabled: false, disabledReason: "No response")
        ]
        expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "continue", in: disabledOnlyPalette) == nil, "Palette clamp is nil when no enabled rows remain")
        let legacyManifestJSON = "{\"schemaVersion\":1,\"id\":\"com.lattice.legacy\",\"name\":\"Legacy\",\"version\":\"1\",\"summary\":\"Legacy.\"}"
        expect((try? LatticeExtensionManifestEnvelope.decode(from: "<nisa-extension-manifest>\(legacyManifestJSON)</nisa-extension-manifest>"))?.id == "com.lattice.legacy", "Envelope accepts legacy nisa tags")
        expect((try? LatticeExtensionManifestEnvelope.decode(from: "<lattice-extension-manifest>\(legacyManifestJSON)</lattice-extension-manifest>"))?.id == "com.lattice.legacy", "Envelope decodes lattice tags")

        let policy = DeterministicPolicyEngine()
        let read = ToolRequest(kind: .read, title: "Read", detail: "file", workspaceScoped: true, reversible: true)
        let write = ToolRequest(kind: .write, title: "Write", detail: "file", workspaceScoped: true, reversible: true)
        if case .allow = policy.evaluate(read, under: .ask) { expect(true, "Ask read") } else { expect(false, "Ask read") }
        if case .requireApproval = policy.evaluate(write, under: .ask) { expect(true, "Ask write") } else { expect(false, "Ask write") }
        let materialFileChange = ToolRequest(kind: .write, title: "Change files", detail: "Sources/App.swift", workspaceScoped: true, reversible: false)
        if case .requireApproval = policy.evaluate(materialFileChange, under: .smart) {
            expect(true, "Smart gates material file changes without reversible evidence")
        } else {
            expect(false, "Smart gates material file changes without reversible evidence")
        }
        // WorkspacePathScope intentionally fails closed when the workspace root
        // itself does not exist; use a real root for this positive-path fixture.
        let f05CodexWorkspace = FileManager.default.temporaryDirectory
        let f05CodexApprovalObject: [String: Any] = [
            "method": "item/fileChange/requestApproval",
            "params": ["grantRoot": f05CodexWorkspace.path, "reason": "Update Sources/App.swift"]
        ]
        if let approval = CodexExecHarness.appServerPermissionRequest(from: f05CodexApprovalObject, workspace: f05CodexWorkspace),
           let request = approval.toolRequest {
            expect(request.workspaceScoped && !request.reversible, "Codex file-change request defaults non-reversible without undo evidence")
            if case .requireApproval = policy.evaluate(request, under: .smart) {
                expect(true, "Smart gates scoped Codex file-change request")
            } else {
                expect(false, "Smart gates scoped Codex file-change request")
            }
        } else {
            expect(false, "Codex file-change request defaults non-reversible without undo evidence")
        }
        let f05CodexEventObject: [String: Any] = [
            "method": "item/started",
            "params": ["item": [
                "id": "file-change-1",
                "type": "fileChange",
                "changes": [["path": "Sources/App.swift"]]
            ]]
        ]
        if case .toolRequested(let request)? = CodexExecHarness.appServerEvent(from: f05CodexEventObject, workspace: f05CodexWorkspace) {
            expect(request.workspaceScoped && !request.reversible, "Codex file-change event defaults non-reversible without undo evidence")
            if case .requireApproval = policy.evaluate(request, under: .smart) {
                expect(true, "Smart gates scoped Codex file-change event")
            } else {
                expect(false, "Smart gates scoped Codex file-change event")
            }
        } else {
            expect(false, "Codex file-change event defaults non-reversible without undo evidence")
        }
        let f05CodexOutsideObject: [String: Any] = [
            "method": "item/started",
            "params": ["item": [
                "id": "file-change-outside",
                "type": "fileChange",
                "changes": [["path": "/tmp/Other/App.swift"]]
            ]]
        ]
        if case .toolRequested(let request)? = CodexExecHarness.appServerEvent(from: f05CodexOutsideObject, workspace: f05CodexWorkspace) {
            expect(!request.workspaceScoped && !request.reversible, "Codex file-change scope remains fail-closed")
            if case .requireApproval = policy.evaluate(request, under: .smart) {
                expect(true, "Smart gates out-of-workspace Codex file-change event")
            } else {
                expect(false, "Smart gates out-of-workspace Codex file-change event")
            }
        } else {
            expect(false, "Codex file-change scope remains fail-closed")
        }
        let broker = LocalToolBroker(handlers: [
            .write: { request in .toolProgress(id: request.id, fraction: 1, detail: "patched") }
        ])
        if case .requiresApproval(let approval) = await broker.submit(write, policy: .ask) {
            expect(approval.toolRequest == write, "Tool broker returns original gated write request")
            expect(approval.options.map(\.id) == ["allow_once", "reject_once"], "Ask broker exposes only one-shot approval and denial")
        } else { expect(false, "Tool broker gates Ask writes before execution") }
        if case .executed(.toolProgress(let id, let fraction, let detail)) = await broker.submit(write, policy: .smart) {
            expect(id == write.id && fraction == 1 && detail == "patched", "Tool broker executes registered Smart write handler")
        } else { expect(false, "Tool broker executes registered Smart write handler") }
        let credential = ToolRequest(kind: .credential, title: "Token", detail: "Keychain", workspaceScoped: true, reversible: false)
        if case .denied(let reason) = await broker.submit(credential, policy: .yolo) {
            expect(reason.contains("Credential"), "Tool broker denies credentials before handler lookup")
        } else { expect(false, "Tool broker denies credentials before handler lookup") }
        let missingBroker = LocalToolBroker()
        if case .failed(let reason) = await missingBroker.submit(read, policy: .ask) {
            expect(reason.contains("noHandler"), "Tool broker fails closed without a registered handler")
        } else { expect(false, "Tool broker fails closed without a registered handler") }
        let brokerAudit = await broker.auditSnapshot()
        expect(brokerAudit.map(\.decision) == [.approvalRequired, .allowed, .executed, .denied], "Tool broker records authorization and execution audit")
        let brokerAuditData = try! JSONEncoder().encode(brokerAudit)
        expect((try! JSONDecoder().decode([ToolAuditRecord].self, from: brokerAuditData)).map(\.decision) == brokerAudit.map(\.decision), "Tool broker audit is durable data")

        // Route capability disclosure (P0): truthful controls before run; live providers are unbrokered.
        let codexAskRoute = CodexProviderExecutionRoute.resolve(policy: .ask)
        expect(codexAskRoute.approvalPolicy == "on-request" && codexAskRoute.sandbox == "read-only", "Codex Ask maps to on-request + read-only")
        let codexAskWriteRoute = CodexProviderExecutionRoute.resolve(policy: .ask, workspaceWrite: true)
        expect(codexAskWriteRoute.sandbox == "workspace-write", "Codex Ask with explicit workspaceWrite maps to workspace-write")
        let codexSmartRoute = CodexProviderExecutionRoute.resolve(policy: .smart)
        expect(codexSmartRoute.approvalPolicy == "on-request" && codexSmartRoute.sandbox == "workspace-write", "Codex Smart maps to on-request + workspace-write")
        let codexYoloRoute = CodexProviderExecutionRoute.resolve(policy: .yolo)
        expect(codexYoloRoute.approvalPolicy == "never" && codexYoloRoute.sandbox == "danger-full-access", "Codex YOLO maps to never + danger-full-access")
        let codexYoloCapability = RouteCapability.resolve(harnessID: "codex", policy: .yolo)
        expect(codexYoloCapability.brokerMediation == .notMediated, "Codex YOLO is not LocalToolBroker-mediated")
        expect(codexYoloCapability.writeContainmentKind == .none && codexYoloCapability.writeContainment.assurance == .absent, "Codex YOLO write containment is absent")
        expect(codexYoloCapability.approvalBehaviorKind == .disabled, "Codex YOLO approvals are disabled")
        expect(codexYoloCapability.writeContainment.detail.contains(codexYoloRoute.sandbox), "Codex capability derives from the same provider route mapping")
        let grokSmart = RouteCapability.resolve(harnessID: "grok", policy: .smart)
        expect(grokSmart.executionOwner == .providerOwned && grokSmart.brokerMediation == .notMediated, "Grok ACP remains provider-owned and unbrokered")
        expect(grokSmart.writeContainmentKind == .latticeMacOSWriteContainment, "Grok ACP uses Lattice macOS write containment")
        expect(grokSmart.fileReadRestriction.assurance == .absent && grokSmart.networkRestriction.assurance == .absent, "Grok ACP does not claim read/network restriction")
        let piAsk = RouteCapability.resolve(harnessID: "pi", policy: .ask)
        expect(piAsk.writeContainmentKind == .latticeMacOSWriteContainment && piAsk.brokerMediation == .notMediated, "Pi uses Lattice write containment but remains unbrokered")
        expect(piAsk.fileReadRestriction.assurance == .absent && piAsk.networkRestriction.assurance == .absent, "Pi does not claim read/network restriction")
        let antigravityAsk = RouteCapability.resolve(harnessID: "antigravity", policy: .ask)
        expect(antigravityAsk.approvalBehaviorKind == .planOnly && antigravityAsk.writeContainmentKind == .providerDeclaredSandbox, "Antigravity Ask is plan-only with provider-declared sandbox")
        expect(antigravityAsk.structuredEvents.assurance == .unknown, "Antigravity structured event support remains runtime-probed")
        let antigravityYolo = RouteCapability.resolve(harnessID: "antigravity", policy: .yolo)
        expect(antigravityYolo.approvalBehaviorKind == .disabled, "Antigravity YOLO disables provider permissions")
        let latticeLocal = RouteCapability.resolve(harnessID: "lattice", policy: .smart)
        expect(latticeLocal.executionOwner == .noDelegatedTools && latticeLocal.brokerMediation == .notApplicable, "Local lattice routes have no delegated tools and are not broker-mediated")
        let unknownRoute = RouteCapability.resolve(harnessID: "mystery-agent", policy: .ask)
        expect(unknownRoute.brokerMediation == .notMediated && unknownRoute.writeContainment.assurance == .unknown, "Unknown harness falls back conservatively")
        let livePiRoute = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")
        let unavailablePiReadiness = RouteReadinessEvaluator.evaluate(
            route: livePiRoute,
            requirements: .init(runtimePresent: false, authenticationValidated: false, modelValidated: false, sandboxAvailable: true)
        )
        let unavailablePiCapabilities = HarnessCapabilitySnapshot.resolve(
            route: livePiRoute,
            policy: .ask,
            readiness: unavailablePiReadiness,
            hasProviderSession: false,
            isRunning: false,
            routeCredentialEnabled: false
        )
        expect(unavailablePiCapabilities.protocolTransport.summary.contains("Pi RPC"), "Live capability surface identifies Pi protocol and transport")
        expect(unavailablePiCapabilities.providerAvailability.assurance == .absent && unavailablePiCapabilities.modelAvailability.assurance == .unknown, "Live capability surface derives unavailable and unknown discovery states")
        let readyPiReadiness = RouteReadinessEvaluator.evaluate(
            route: livePiRoute,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: true, sandboxAvailable: true)
        )
        let recoveredPi = HarnessCapabilitySnapshot.resolve(
            route: livePiRoute,
            policy: .ask,
            readiness: readyPiReadiness,
            hasProviderSession: true,
            isRunning: false,
            routeCredentialEnabled: true
        )
        expect(recoveredPi.providerAvailability.assurance == .present && recoveredPi.modelAvailability.assurance == .present, "Live capability surface recovers with current runtime discovery")
        expect(recoveredPi.resumeState == .resumable && recoveredPi.resume.summary == "Ready to resume", "Live capability surface derives current resume state without exposing the handle")
        expect(recoveredPi.sandboxOwner.summary == "Lattice" && recoveredPi.routeCapability.fileReadRestriction.assurance == .absent, "Live capability surface names Lattice write-only containment honestly")
        expect(RouteConnectionCaption.caption(forHarnessID: "codex") == "Provider-owned tools · policy-dependent sandbox", "Codex Connections caption is policy-agnostic")
        expect(RouteConnectionCaption.caption(forHarnessID: "grok") == "Lattice write containment · provider-owned tools", "ACP Connections caption is truthful and invariant")
        expect(RouteConnectionCaption.caption(forHarnessID: "antigravity") == "Provider sandbox option · runtime-probed events", "Antigravity Connections caption is truthful and invariant")
        let privacyBody = LatticeSettingsCopy.privacySecurityBody
        expect(privacyBody.localizedCaseInsensitiveContains("LocalToolBroker") && privacyBody.localizedCaseInsensitiveContains("route- and policy-dependent"), "Privacy copy discloses unbrokered provider tools and non-universal containment")
        expect(!privacyBody.localizedCaseInsensitiveContains("tool writes are limited to the selected workspace"), "Privacy copy no longer claims universal workspace write limits")
        for harnessID in RouteCapability.knownHarnessIDs {
            for policy in ExecutionPolicy.allCases {
                let capability = RouteCapability.resolve(harnessID: harnessID, policy: policy)
                expect(capability.brokerMediation != .mediatedByLocalToolBroker, "No known live harness claims LocalToolBroker mediation (\(harnessID)/\(policy.rawValue))")
                expect(!capability.warnings.isEmpty, "Every known route surfaces a conservative warning (\(harnessID)/\(policy.rawValue))")
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let responseMessage = ChatMessage(role: .assistant, text: "Done")
        let persistedAction = SessionAction(messageID: responseMessage.id, kind: .tool, toolKind: .write, title: "Edit App.swift", detail: "Sources/App.swift", status: .completed, workspaceScoped: true)
        let session = LatticeSession(title: "Real session", messages: [.init(role: .user, text: "Hello"), responseMessage], backend: .codex(model: "gpt-5.4"), harnessID: "pi", harnessThreadID: "thread", attachments: [.init(path: "/tmp/a")], actions: [persistedAction], draft: "keep me\nexactly", isPinned: true)
        try! store.save([session])
        expect(store.load() == [session], "Session round trip")
        expect(store.load().first?.actions == [persistedAction], "Canonical action trail round trip")
        expect(store.load().first?.attachments.first?.name == "a", "Attachment metadata round trip")
        expect(store.load().first?.harnessID == "pi", "Harness selection round trip")
        expect(store.load().first?.isPinned == true, "Pinned chat state round trip")
        expect(store.load().first?.draft == "keep me\nexactly", "Per-chat ordinary draft round trip")
        let draftChatA = LatticeSession(title: "Draft A", backend: .codex(model: "gpt-5.4"), draft: "alpha\n  spaced  ")
        let draftChatB = LatticeSession(title: "Draft B", backend: .codex(model: "gpt-5.4"), draft: "")
        try! store.save([draftChatA, draftChatB])
        let restoredDrafts = store.load()
        expect(restoredDrafts.first(where: { $0.id == draftChatA.id })?.draft == "alpha\n  spaced  ", "Two-chat drafts restore independently with whitespace")
        expect(restoredDrafts.first(where: { $0.id == draftChatB.id })?.draft == "", "Empty chat draft restores exact empty state")
        var legacyDraftObject = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(LatticeSession(title: "Legacy", backend: .codex(model: "gpt-5.4")))) as! [String: Any]
        legacyDraftObject["draft"] = nil
        let legacyDraftDecoded = try! JSONDecoder().decode(LatticeSession.self, from: JSONSerialization.data(withJSONObject: legacyDraftObject))
        expect(legacyDraftDecoded.draft == "", "Legacy Codable sessions default draft to empty")
        let draftBranchSource = LatticeSession(title: "Source", messages: [.init(role: .user, text: "First")], backend: .codex(model: "gpt-5.4"), draft: "source draft")
        let draftBranch = SessionTranscriptMutation.branchFromMessage(messageID: draftBranchSource.messages[0].id, in: draftBranchSource)
        expect(draftBranch?.draft == "", "Branch starts with empty ordinary draft and does not copy source draft")
        let privateSession = LatticeSession(title: "Private", backend: .ollama(model: "llama3.2:latest"), privacyMode: .localOnly)
        try! store.save([privateSession])
        expect(store.load().first?.privacyMode == .localOnly, "Session privacy mode round trip")
        let olderPinned = LatticeSession(title: "Older pinned", backend: .codex(model: "gpt-5.4"), isPinned: true, lastUpdated: Date(timeIntervalSince1970: 1))
        let newerUnpinned = LatticeSession(title: "Newer unpinned", backend: .codex(model: "gpt-5.4"), lastUpdated: Date(timeIntervalSince1970: 2))
        expect(LatticeSessionListOrdering.sorted([newerUnpinned, olderPinned]).map(\.id) == [olderPinned.id, newerUnpinned.id], "Pinned chats sort before newer unpinned chats")
        let queuedFollowUp = QueuedFollowUp(text: "Then compare the calmer logo options")
        let queuedSession = LatticeSession(title: "Queued chat", messages: [.init(role: .user, text: "Start")], backend: .codex(model: "gpt-5.4"), queuedFollowUps: [queuedFollowUp])
        try! store.save([queuedSession])
        expect(store.load().first?.queuedFollowUps == [queuedFollowUp], "Queued follow-ups round trip with the session")
        expect(queuedFollowUp.context == nil && queuedFollowUp.lifecycle == .blocked(.missingCapturedContext), "Legacy queued follow-ups without context require explicit review")

        // Session input outbox: secret-free context, FIFO claim/dequeue, restart review, no auto-advance past head failure.
        let outboxSecretSentinel = "sk-outbox-verify-secret-sentinel"
        let outboxRoute = ExecutionRoute(mode: .code, providerID: "codex", modelID: "gpt-5.4", runtimeID: "codex")
        let outboxContext = SessionInputOutboxContext.capture(
            executionRoute: outboxRoute,
            workspacePath: "/Users/dev/project",
            policy: .ask,
            privacyMode: .cloudAllowed,
            reasoningEffort: .medium,
            attachments: [ContextAttachment(path: "/Users/dev/project/a.swift")]
        )
        var outboxEntries: [QueuedFollowUp] = []
        var outboxLedger = SessionInputOutboxReceiptLedger()
        let outboxHeadID = UUID(), outboxTailID = UUID(), outboxAttempt = UUID()
        SessionInputOutboxPolicy.enqueue(text: "head", context: outboxContext, into: &outboxEntries, id: outboxHeadID)
        SessionInputOutboxPolicy.enqueue(text: "tail", context: outboxContext, into: &outboxEntries, id: outboxTailID)
        expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(of: outboxTailID, currentContext: outboxContext, in: outboxEntries) == .ineligible(.notHead),
            "Outbox FIFO rejects non-head automatic dispatch"
        )
        expect(
            SessionInputOutboxPolicy.claimDispatch(entryID: outboxHeadID, currentContext: outboxContext, in: &outboxEntries, attemptID: outboxAttempt) == .claimed(attemptID: outboxAttempt),
            "Outbox claims the eligible head with a durable attempt id"
        )
        expect(
            SessionInputOutboxPolicy.claimDispatch(entryID: outboxHeadID, currentContext: outboxContext, in: &outboxEntries, attemptID: UUID()) == .alreadyClaimed(attemptID: outboxAttempt),
            "Outbox claim is duplicate-safe for an in-flight head"
        )
        let outboxFailure = QueuedFollowUpFailureReason(code: .providerUnavailable, detail: "route offline")
        expect(
            SessionInputOutboxPolicy.recordFailure(entryID: outboxHeadID, attemptID: outboxAttempt, reason: outboxFailure, in: &outboxEntries) == .applied,
            "Outbox records typed failure without removing the FIFO head"
        )
        expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(of: outboxTailID, currentContext: outboxContext, in: outboxEntries) == .ineligible(.notHead),
            "Outbox head failure blocks automatic advancement"
        )
        expect(
            SessionInputOutboxPolicy.acceptExplicitReview(entryID: outboxHeadID, currentContext: outboxContext, in: &outboxEntries) == .applied,
            "Outbox explicit review re-arms a failed head with current context"
        )
        expect(
            SessionInputOutboxPolicy.claimDispatch(entryID: outboxHeadID, currentContext: outboxContext, in: &outboxEntries, attemptID: outboxAttempt) == .claimed(attemptID: outboxAttempt),
            "Outbox re-claims after explicit review"
        )
        expect(
            SessionInputOutboxPolicy.completeLocalDequeue(entryID: outboxHeadID, attemptID: outboxAttempt, in: &outboxEntries, ledger: &outboxLedger) == .dequeued,
            "Outbox completes exactly-once local dequeue"
        )
        expect(
            SessionInputOutboxPolicy.completeLocalDequeue(entryID: outboxHeadID, attemptID: outboxAttempt, in: &outboxEntries, ledger: &outboxLedger) == .alreadyDequeued,
            "Outbox local dequeue completion is idempotent via receipt ledger"
        )
        expect(outboxEntries.map(\.id) == [outboxTailID], "Outbox dequeue removes only the claimed head")
        SessionInputOutboxPolicy.recoverAfterRestart(&outboxEntries)
        expect(outboxEntries[0].lifecycle == .blocked(.restartRecovery), "Outbox restart recovery requires explicit review for pending work")
        let mismatched = SessionInputOutboxContext(
            executionRoute: outboxRoute,
            workspacePath: "/tmp/elsewhere",
            policy: .ask,
            privacyMode: .cloudAllowed,
            reasoningEffort: .medium,
            attachmentPathIdentities: outboxContext.attachmentPathIdentities
        )
        var reviewEntries = outboxEntries
        expect(
            SessionInputOutboxPolicy.acceptExplicitReview(entryID: outboxTailID, currentContext: outboxContext, in: &reviewEntries) == .applied,
            "Outbox review restores pending after restart recovery"
        )
        expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(of: outboxTailID, currentContext: mismatched, in: reviewEntries) == .ineligible(.contextMismatch),
            "Outbox eligibility rejects workspace path mismatch"
        )
        let credentialAuthorityChanged = SessionInputOutboxContext(
            executionRoute: outboxRoute,
            workspacePath: outboxContext.workspacePath,
            policy: .ask,
            privacyMode: .cloudAllowed,
            reasoningEffort: .medium,
            providerCredentialInjectionEnabled: true,
            attachmentPathIdentities: outboxContext.attachmentPathIdentities
        )
        expect(
            credentialAuthorityChanged != outboxContext,
            "Outbox context detects changed provider credential-injection authority without storing credentials"
        )
        let hostileFailure = QueuedFollowUpFailureReason(
            code: .providerUnavailable,
            detail: "provider\u{0000}\n\t" + String(repeating: "x", count: 300)
        )
        let hostileFailureDecoded = try! JSONDecoder().decode(
            QueuedFollowUpFailureReason.self,
            from: JSONEncoder().encode(hostileFailure)
        )
        expect(
            hostileFailureDecoded.detail?.contains("\n") == false
                && (hostileFailureDecoded.detail?.count ?? 0) <= QueuedFollowUpFailureReason.maxDetailLength,
            "Outbox failure details remain sanitized and bounded after decoding"
        )
        let legacyOutboxJSON = """
        {"id":"\(UUID().uuidString)","text":"legacy queue","date":0}
        """
        let legacyOutboxDecoded = try! JSONDecoder().decode(QueuedFollowUp.self, from: Data(legacyOutboxJSON.utf8))
        expect(legacyOutboxDecoded.context == nil && legacyOutboxDecoded.lifecycle == .blocked(.missingCapturedContext), "Legacy outbox JSON migrates into explicit review")
        let outboxEncoded = try! JSONEncoder().encode(outboxContext)
        let outboxEncodedText = String(decoding: outboxEncoded, as: UTF8.self)
        expect(!outboxEncodedText.contains(outboxSecretSentinel), "Outbox context encoding never contains a supplied secret sentinel")
        expect(!outboxEncodedText.contains("apiKey") && !outboxEncodedText.contains("providerSession"), "Outbox context encoding stays free of credential field names")
        var olderContextObject = try! JSONSerialization.jsonObject(with: outboxEncoded) as! [String: Any]
        olderContextObject["providerCredentialInjectionEnabled"] = nil
        let migratedContext = try! JSONDecoder().decode(
            SessionInputOutboxContext.self,
            from: JSONSerialization.data(withJSONObject: olderContextObject)
        )
        expect(!migratedContext.providerCredentialInjectionEnabled, "Older outbox context JSON defaults new credential authority fields safely")

        // Fast-switch projection cache: deterministic reuse and an objective local microbenchmark.
        let projectionSessions = (0..<200).map { index in
            LatticeSession(
                title: "Projection \(index)",
                backend: .codex(model: "gpt-5.4"),
                lastUpdated: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
            )
        }
        var projectionCache = SessionProjectionCache()
        let projectionIDs = projectionCache.orderedSessionIDs(for: projectionSessions)
        let projectionStart = Date()
        for _ in 0..<1_000 {
            expect(
                projectionCache.orderedSessionIDs(for: projectionSessions) == projectionIDs,
                "Fast-switch projection cache preserves deterministic order"
            )
        }
        let projectionElapsedMilliseconds = Date().timeIntervalSince(projectionStart) * 1_000
        expect(projectionCache.rebuildCount == 1, "Fast-switch projection cache avoids unchanged rebuilds")
        expect(projectionIDs.count == projectionSessions.count, "Fast-switch projection cache retains every session")
        print(String(format: "Session projection benchmark: 1,000 refreshes / 200 sessions = %.2f ms, rebuilds = %d", projectionElapsedMilliseconds, projectionCache.rebuildCount))

        var streamingProjection = LatticeSession(
            title: "Streaming projection",
            messages: [.init(role: .user, text: "Prompt"), .init(role: .assistant, text: "")],
            backend: .codex(model: "gpt-5.4"),
            isStreaming: true,
            lastUpdated: Date(timeIntervalSinceReferenceDate: 1)
        )
        var streamingProjectionCache = SessionProjectionCache()
        _ = streamingProjectionCache.refresh([streamingProjection])
        for index in 0..<100 {
            streamingProjection.messages[1].text += "x"
            streamingProjection.lastUpdated = Date(timeIntervalSinceReferenceDate: TimeInterval(index + 2))
            _ = streamingProjectionCache.refresh([streamingProjection])
        }
        expect(streamingProjectionCache.rebuildCount == 1, "Streaming token deltas do not rebuild session-list projections")

        let longMessages = (0..<350).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "lazy-message-\($0)") }
        let longSession = LatticeSession(title: "Long chat", messages: longMessages, backend: .codex(model: "gpt-5.4"))
        try! store.save([longSession])
        if case .loaded(let lazySnapshot) = store.loadLazyResult(), var lazySession = lazySnapshot.sessions.first {
            expect(lazySession.messages.isEmpty && !lazySession.isTranscriptLoaded, "Lazy session load leaves transcript bytes on disk")
            expect(lazySession.totalMessageCount == 350, "Lazy session metadata preserves exact message count")
            expect(lazySession.lastMessagePreview == "lazy-message-349", "Lazy session metadata preserves bounded list preview")
            expect(lazySnapshot.searchIndex.candidateSessionIDs(for: "message-349", allSessionIDs: [longSession.id]) == [longSession.id], "Hashed index finds transcript without eager decode")
            if let storage = lazySession.transcriptStorage {
                let hydrationSession = lazySession
                let request = TranscriptHydrationRequest(sessionID: lazySession.id, storage: storage)
                let coordinator = TranscriptHydrationCoordinator()
                let outcome = await coordinator.hydrate(request) { store.hydrationResult(for: hydrationSession) }
                if case .loaded(let loadedRequest, let content) = outcome {
                    expect(loadedRequest == request && content.messages == longMessages, "Asynchronous transcript hydration preserves exact content")
                } else {
                    expect(false, "Asynchronous transcript hydration preserves exact content")
                }
                expect(TranscriptHydrationApplyPolicy.shouldApply(request: request, selectedSessionID: lazySession.id, currentSession: lazySession), "Clean selected transcript accepts current hydration generation")
                var hydrationLRU = TranscriptHydrationLRU(maximumCount: 2)
                let cachedIDs = [UUID(), UUID(), UUID()]
                cachedIDs.forEach { hydrationLRU.recordAccess($0) }
                expect(hydrationLRU.evictionCandidates(protectedIDs: [cachedIDs[0]]) == [cachedIDs[1]], "Hydration LRU evicts the oldest disposable transcript")
            } else {
                expect(false, "Lazy transcript retains durable hydration reference")
            }
            try! store.materializeTranscript(in: &lazySession)
            expect(lazySession.messages == longMessages && !lazySession.isTranscriptDirty, "Selected transcript materializes exactly and remains clean")
        } else {
            expect(false, "Lazy split session store loads")
        }
        let indexBytes = try! Data(contentsOf: store.searchIndexURL)
        expect(!String(decoding: indexBytes, as: UTF8.self).contains("lazy-message-349"), "Derived search index does not duplicate plaintext transcript")
        var renderWindows = TranscriptRenderWindowCache(pageSize: 50, maximumThreadCount: 2, maximumVisibleMessageCount: 100)
        expect(renderWindows.activate(sessionID: longSession.id, messageCount: 350).range == 300..<350, "Render cache starts with bounded tail page")
        expect(renderWindows.loadEarlier(sessionID: longSession.id, messageCount: 350).range == 250..<350, "Render cache pages backward deterministically")
        let anotherWindowID = UUID()
        _ = renderWindows.activate(sessionID: anotherWindowID, messageCount: 350)
        expect(renderWindows.cachedVisibleMessageCount <= 100, "Render cache enforces aggregate visible-message bound")

        // Durable store recovery: missing vs corrupt vs unreadable, backup/reset, write gate.
        let recoveryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let missingURL = recoveryRoot.appendingPathComponent("missing-sessions.json")
        if case .missing = SessionPersistence(fileURL: missingURL).loadResult() {
            expect(true, "Missing sessions file is normal empty load result")
        } else {
            expect(false, "Missing sessions file is normal empty load result")
        }
        let corruptURL = recoveryRoot.appendingPathComponent("sessions.json")
        let corruptBytes = Data("{not-valid-json".utf8)
        try! corruptBytes.write(to: corruptURL)
        let corruptStore = SessionPersistence(fileURL: corruptURL)
        if case .failed(let issue) = corruptStore.loadResult() {
            expect(issue.kind == .corrupt, "Corrupt sessions JSON is .corrupt failure")
            expect(issue.storeID == SessionPersistence.storeID, "Corrupt issue names sessions store")
            expect((try? Data(contentsOf: corruptURL)) == corruptBytes, "Corrupt load never mutates original bytes")
            expect(corruptStore.load().isEmpty, "Compatibility load still returns empty for corrupt without writing")
        } else {
            expect(false, "Corrupt sessions JSON is .corrupt failure")
        }
        let permissionError = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        let unreadableIO = DurableStoreFileIO(
            fileExists: { _ in true },
            attributesOfItem: { _ in [.size: 4, .modificationDate: Date(timeIntervalSince1970: 42)] },
            readData: { _ in throw permissionError },
            readDataUpTo: { _, _ in throw permissionError }
        )
        if case .failed(let unreadableIssue) = SessionPersistence(fileURL: corruptURL, io: unreadableIO).loadResult() {
            expect(unreadableIssue.kind == .unreadable, "Permission denial classifies as unreadable")
            expect(unreadableIssue.observedFileSize == 4, "Unreadable issue captures observed size")
        } else {
            expect(false, "Permission denial classifies as unreadable")
        }
        let inaccessibleIO = DurableStoreFileIO(
            fileExists: { _ in false },
            attributesOfItem: { _ in throw permissionError },
            readData: { _ in throw permissionError },
            readDataUpTo: { _, _ in throw permissionError }
        )
        if case .failed(let inaccessibleIssue) = SessionPersistence(fileURL: corruptURL, io: inaccessibleIO).loadResult() {
            expect(inaccessibleIssue.kind == .unreadable, "Failed existence probe does not hide permission denial as missing")
        } else {
            expect(false, "Failed existence probe does not hide permission denial as missing")
        }
        expect(DurableStoreRecovery.isUnreadableError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), "Cocoa no-permission is unreadable")
        expect(DurableStoreRecovery.isNotFoundError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)), "Cocoa no-such-file is not-found")
        let backupNow = Date(timeIntervalSince1970: 1_800_000_000)
        let backupResult = try! DurableStoreRecovery.preserveCopy(of: corruptURL, kind: .backup, now: backupNow, uniqueToken: "aabbccdd")
        expect(backupResult.preservedURL.lastPathComponent.contains(".corrupt-"), "Backup uses corrupt-timestamp suffix")
        expect(backupResult.preservedURL.pathExtension == "backup", "Backup uses .backup extension")
        expect((try? Data(contentsOf: backupResult.preservedURL)) == corruptBytes, "Backup preserves original bytes")
        expect((try? Data(contentsOf: corruptURL)) == corruptBytes, "Backup leaves original in place")
        let collisionBackup = try! DurableStoreRecovery.preserveCopy(of: corruptURL, kind: .backup, now: backupNow, uniqueToken: "aabbccdd")
        expect(collisionBackup.preservedURL.path != backupResult.preservedURL.path, "Backup never replaces existing backup name")
        expect(FileManager.default.fileExists(atPath: backupResult.preservedURL.path), "Prior backup survives collision-safe naming")
        let backupPartials = (try? FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path))?.filter { $0.contains(".partial-") } ?? []
        expect(backupPartials.isEmpty, "Successful backup leaves no partial artifacts")
        let exportDest = recoveryRoot.appendingPathComponent("export-existing.json")
        try! Data("taken".utf8).write(to: exportDest)
        do {
            try DurableStoreRecovery.exportCopy(of: corruptURL, to: exportDest)
            expect(false, "Export refuses existing destination")
        } catch DurableStoreRecoveryError.destinationExists {
            expect((try? String(contentsOf: exportDest, encoding: .utf8)) == "taken", "Refused export leaves destination unchanged")
            expect((try? Data(contentsOf: corruptURL)) == corruptBytes, "Refused export leaves source unchanged")
        } catch {
            expect(false, "Export refuses existing destination")
        }
        let freeExport = recoveryRoot.appendingPathComponent("export-free.json")
        try! DurableStoreRecovery.exportCopy(of: corruptURL, to: freeExport)
        expect((try? Data(contentsOf: freeExport)) == corruptBytes, "Export copies original bytes to free destination")
        let jobsCorruptURL = recoveryRoot.appendingPathComponent("self-edit-jobs.json")
        let previewsCorruptURL = recoveryRoot.appendingPathComponent("self-edit-previews.json")
        try! Data("bad-jobs".utf8).write(to: jobsCorruptURL)
        try! Data("bad-previews".utf8).write(to: previewsCorruptURL)
        if case .failed(let jobIssue) = LatticeExtensionJobStore(fileURL: jobsCorruptURL).loadResult() {
            expect(jobIssue.kind == .corrupt && jobIssue.storeID == LatticeExtensionJobStore.storeID, "Self-edit jobs report corrupt independently")
        } else {
            expect(false, "Self-edit jobs report corrupt independently")
        }
        if case .failed(let previewIssue) = LatticeExtensionPreviewStore(fileURL: previewsCorruptURL).loadResult() {
            expect(previewIssue.kind == .corrupt && previewIssue.storeID == LatticeExtensionPreviewStore.storeID, "Self-edit previews report corrupt independently")
        } else {
            expect(false, "Self-edit previews report corrupt independently")
        }
        expect((try? Data(contentsOf: jobsCorruptURL)) == Data("bad-jobs".utf8), "Jobs corrupt load preserves original")
        expect((try? Data(contentsOf: previewsCorruptURL)) == Data("bad-previews".utf8), "Previews corrupt load preserves original")
        let gate = DurableStoreWriteGate()
        let gatedStore = SessionPersistence(fileURL: recoveryRoot.appendingPathComponent("gated.json"), writeGate: gate)
        gate.block()
        do {
            try gatedStore.save([])
            expect(false, "Write gate blocks session saves during recovery")
        } catch {
            expect(true, "Write gate blocks session saves during recovery")
        }
        gate.unblock()
        try! gatedStore.save([])
        expect(FileManager.default.fileExists(atPath: gatedStore.fileURL.path), "Write gate allows saves after unblock")
        let resetURL = recoveryRoot.appendingPathComponent("reset-me.json")
        let resetOriginal = Data("reset-source".utf8)
        try! resetOriginal.write(to: resetURL)
        let resetResult = try! DurableStoreRecovery.resetReplacingWithEmptyArray(at: resetURL)
        expect((try? Data(contentsOf: resetResult.preservedURL)) == resetOriginal, "Reset preserves original in quarantine backup")
        expect(String(data: try! Data(contentsOf: resetURL), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "[]", "Reset installs empty JSON array")
        if case .loaded(let emptySessions) = SessionPersistence(fileURL: resetURL).loadResult() {
            expect(emptySessions.isEmpty, "Reset sessions store loads as empty success")
        } else {
            expect(false, "Reset sessions store loads as empty success")
        }
        let staleURL = recoveryRoot.appendingPathComponent("stale.json")
        try! Data("v1".utf8).write(to: staleURL)
        let staleIssue: DurableStoreIssue
        if case .failed(let issue) = DurableStoreRecovery.loadJSONArray(from: staleURL, as: LatticeSession.self, storeID: "sessions", storeName: "Chat sessions") {
            staleIssue = issue
        } else {
            staleIssue = DurableStoreIssue(storeID: "sessions", storeName: "Chat sessions", filePath: staleURL.path, kind: .corrupt, summary: "x", technicalDetails: "x")
            expect(false, "Stale protection fixture starts corrupt")
        }
        try! Data("v2-changed".utf8).write(to: staleURL)
        do {
            _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: staleURL, expected: staleIssue)
            expect(false, "Reset rejects stale source that changed after failure")
        } catch DurableStoreRecoveryError.sourceChanged {
            expect((try? String(contentsOf: staleURL, encoding: .utf8)) == "v2-changed", "Rejected stale reset leaves changed original")
        } catch {
            expect(false, "Reset rejects stale source that changed after failure")
        }
        let disappearedURL = recoveryRoot.appendingPathComponent("disappeared.json")
        try! Data("corrupt".utf8).write(to: disappearedURL)
        if case .failed(let disappearedIssue) = DurableStoreRecovery.loadJSONArray(from: disappearedURL, as: LatticeSession.self, storeID: "sessions", storeName: "Chat sessions") {
            try! FileManager.default.removeItem(at: disappearedURL)
            do {
                _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: disappearedURL, expected: disappearedIssue)
                expect(false, "Reset refuses when the observed original disappeared")
            } catch DurableStoreRecoveryError.sourceMissing {
                expect(!FileManager.default.fileExists(atPath: disappearedURL.path), "Missing observed original is not silently replaced")
            } catch {
                expect(false, "Reset reports disappeared observed original as sourceMissing")
            }
        } else {
            expect(false, "Disappearing reset fixture starts corrupt")
        }
        let failBackupURL = recoveryRoot.appendingPathComponent("fail-backup.json")
        let failBackupOriginal = Data("must-remain".utf8)
        try! failBackupOriginal.write(to: failBackupURL)
        let copyFailIO = DurableStoreFileIO(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            attributesOfItem: { try FileManager.default.attributesOfItem(atPath: $0) },
            readData: { try Data(contentsOf: $0) },
            writeDataAtomically: { data, url in try data.write(to: url, options: .atomic) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            copyItem: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "I/O error"]) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            replaceItem: { original, replacement in _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement) }
        )
        do {
            _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: failBackupURL, io: copyFailIO)
            expect(false, "Reset fails closed when backup cannot be created")
        } catch {
            expect((try? Data(contentsOf: failBackupURL)) == failBackupOriginal, "Failed reset leaves original bytes unchanged")
            let failedBackupPartials = (try? FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path))?.filter { $0.contains(".partial-") } ?? []
            expect(failedBackupPartials.isEmpty, "Failed backup cleans temporary artifacts")
        }
        let failVerificationURL = recoveryRoot.appendingPathComponent("fail-verification.json")
        let failVerificationOriginal = Data("must-remain-unverified".utf8)
        try! failVerificationOriginal.write(to: failVerificationURL)
        let verificationFailIO = DurableStoreFileIO(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            attributesOfItem: { try FileManager.default.attributesOfItem(atPath: $0) },
            readData: { url in
                if url.lastPathComponent.contains(".partial-") {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "Verification read failed"])
                }
                return try Data(contentsOf: url)
            },
            writeDataAtomically: { data, url in try data.write(to: url, options: .atomic) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            replaceItem: { original, replacement in _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement) }
        )
        do {
            _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: failVerificationURL, io: verificationFailIO)
            expect(false, "Reset fails closed when backup verification cannot complete")
        } catch {
            expect((try? Data(contentsOf: failVerificationURL)) == failVerificationOriginal, "Unverified backup never permits original replacement")
            let remainingRecoveryFiles = (try? FileManager.default.contentsOfDirectory(atPath: recoveryRoot.path)) ?? []
            expect(!remainingRecoveryFiles.contains { $0.hasPrefix("fail-verification.json.corrupt-") && $0.hasSuffix(".backup") }, "Failed backup verification removes the unusable copy")
            expect(!remainingRecoveryFiles.contains { $0.contains(".partial-") }, "Failed backup verification removes temporary copy")
        }
        // Retry after external repair restores runtime interrupted state.
        let repairURL = recoveryRoot.appendingPathComponent("repair.json")
        try! Data("{bad".utf8).write(to: repairURL)
        let repairStore = SessionPersistence(fileURL: repairURL)
        expect({ if case .failed = repairStore.loadResult() { return true }; return false }(), "Repair fixture starts failed")
        let repairResponse = ChatMessage(role: .assistant, text: "Partial")
        let repairAction = SessionAction(messageID: repairResponse.id, kind: .tool, toolKind: .command, title: "Build", detail: "$ build", status: .running)
        let repairSession = LatticeSession(title: "Repair", messages: [repairResponse], backend: .codex(model: "gpt-5.4"), actions: [repairAction], isStreaming: true)
        try! JSONEncoder().encode([repairSession]).write(to: repairURL, options: .atomic)
        if case .loaded(let repaired) = repairStore.loadResult() {
            expect(repaired.first?.isStreaming == false, "Repaired sessions restore non-streaming runtime state")
            expect(repaired.first?.actions.first?.status == .interrupted, "Repaired sessions mark pending actions interrupted")
        } else {
            expect(false, "Repaired sessions restore non-streaming runtime state")
        }
        try? FileManager.default.removeItem(at: recoveryRoot)

        expect(LatticeContinuationPolicy.prompt == "Continue from where you left off.", "Continuation prompt is explicit transcript text")
        let productContext = LatticeProductInstructions.current
        expect(
            productContext.contains("Extensions & Skills")
            && productContext.contains("right sidebar/inspector")
            && productContext.contains("native auto-compaction where the CLI supports it")
            && productContext.contains("visible-transcript handoff")
            && productContext.contains("Review Lattice change")
            && productContext.contains("Apply/Discard")
            && productContext.contains("matching YAML frontmatter")
            && productContext.contains("Antigravity")
            && productContext.contains("roadmap features")
            && productContext.localizedCaseInsensitiveContains("LocalToolBroker")
            && productContext.localizedCaseInsensitiveContains("route-specific"),
            "Backend product instructions explain current Lattice surfaces, context handling, self-edit review behavior, generated skill standards, truthful route controls, and roadmap limits"
        )
        expect(LatticeContinuationPolicy.canContinue(session), "Continuation is available after a visible assistant response")
        expect(!LatticeContinuationPolicy.canContinue(LatticeSession(title: "Streaming", messages: session.messages, backend: .codex(model: "gpt-5.4"), isStreaming: true)), "Continuation is hidden while streaming")
        expect(!LatticeContinuationPolicy.canContinue(LatticeSession(title: "Empty assistant", messages: [.init(role: .user, text: "Start"), .init(role: .assistant, text: " ")], backend: .codex(model: "gpt-5.4"))), "Continuation is hidden for empty assistant placeholders")
        expect(!LatticeContinuationPolicy.canContinue(LatticeSession(title: "User ended", messages: [.init(role: .user, text: "Start")], backend: .codex(model: "gpt-5.4"))), "Continuation is hidden when the last turn is not assistant")
        let contextSession = LatticeSession(
            title: "Budget",
            messages: [.init(role: .user, text: String(repeating: "a", count: 40))],
            backend: .codex(model: "gpt-5.4"),
            attachments: [.init(path: "/tmp/Lattice/PLAN.md")]
        )
        let contextEstimate = LatticeContextBudgetEstimator.estimate(session: contextSession, draft: String(repeating: "b", count: 20), tokenLimit: 100)
        expect(contextEstimate.transcriptTokens > 0 && contextEstimate.draftTokens == 5, "Context budget estimates visible transcript and draft text")
        expect(contextEstimate.attachmentTokens > 8, "Context budget accounts for attached path metadata")
        expect(contextEstimate.status == .comfortable, "Context budget classifies comfortable usage")
        expect(LatticeContextBudgetEstimate(tokenLimit: 100, transcriptTokens: 75, draftTokens: 0, attachmentTokens: 0).status == .tight, "Context budget classifies tight usage")
        expect(LatticeContextBudgetEstimate(tokenLimit: 100, transcriptTokens: 90, draftTokens: 0, attachmentTokens: 0).status == .nearLimit, "Context budget classifies near-limit usage")
        expect(LatticeContextBudgetEstimate(tokenLimit: 100, transcriptTokens: 101, draftTokens: 0, attachmentTokens: 0).status == .overLimit, "Context budget classifies over-limit usage")
        expect(ProviderModelMetadata.contextWindow(from: ["limit": ["context": 200_000]]) == 200_000, "Provider model metadata parses nested context windows")
        expect(ProviderModelMetadata.contextWindow(from: ["contextWindow": "128k"]) == 128_000, "Provider model metadata parses abbreviated context windows")
        expect(
            LatticeContextBudgetEstimator.tokenLimit(for: .openCode(model: "opencode/qwen3-coder"), openCodeModels: [.init(id: "opencode/qwen3-coder", name: "Qwen3 Coder", contextWindow: 64_000)]) == 64_000,
            "Context budget uses model-specific provider context windows when available"
        )
        let healthyResumedCLI = LatticeSession(
            title: "Resumed CLI",
            messages: [.init(role: .user, text: "Previous"), .init(role: .assistant, text: "Answer"), .init(role: .user, text: "Next"), .init(role: .assistant, text: "")],
            backend: .codex(model: "gpt-5.4"),
            harnessThreadID: "thread-1"
        )
        let rawContextPlan = LatticeContextHandoffPlanner.plan(session: healthyResumedCLI, submittedText: "Next", existingHarnessThreadID: healthyResumedCLI.harnessThreadID, compactionThreshold: 0.95)
        expect(rawContextPlan.prompt == "Next" && !rawContextPlan.resetsHarnessSession, "Context handoff leaves healthy resumed CLI sessions on raw prompt path")
        let restoredCLI = LatticeSession(
            title: "Restored CLI",
            messages: [.init(role: .user, text: "Original request"), .init(role: .assistant, text: "Original answer"), .init(role: .user, text: "Continue"), .init(role: .assistant, text: "")],
            backend: .openCode(model: "opencode/model")
        )
        let missingThreadPlan = LatticeContextHandoffPlanner.plan(session: restoredCLI, submittedText: "Continue", additionalContext: "\n\nAttached paths:\n/tmp/a.swift", existingHarnessThreadID: nil)
        expect(missingThreadPlan.usesVisibleTranscriptHandoff && missingThreadPlan.resetsHarnessSession && !missingThreadPlan.didCompact, "Context handoff sends full visible transcript when CLI thread is missing")
        expect(missingThreadPlan.prompt.contains("[User] Original request") && missingThreadPlan.prompt.contains("[Assistant] Original answer") && missingThreadPlan.prompt.contains("/tmp/a.swift"), "Context handoff prompt contains prior transcript and attachments")
        let oversizedFullHandoffPlan = LatticeContextHandoffPlanner.plan(
            session: restoredCLI,
            submittedText: "Continue",
            tokenLimit: 70,
            existingHarnessThreadID: nil,
            compactionThreshold: 0.99
        )
        expect(oversizedFullHandoffPlan.usesVisibleTranscriptHandoff && !oversizedFullHandoffPlan.didCompact, "Context preflight can identify an oversized full handoff without auto-compacting")
        expect(
            oversizedFullHandoffPlan.deliveryIssue?.contains("visible transcript handoff") == true
            && oversizedFullHandoffPlan.deliveryIssue?.contains("compacted") == false,
            "Context preflight reports oversized full handoffs without claiming compaction"
        )
        let oversizedCurrentPlan = LatticeContextHandoffPlanner.plan(
            session: LatticeSession(title: "Oversized skill", messages: [.init(role: .user, text: "Run skill"), .init(role: .assistant, text: "")], backend: .ollama(model: "small")),
            submittedText: String(repeating: "large injected skill workflow ", count: 220),
            tokenLimit: 1_000,
            existingHarnessThreadID: "structured-message-list"
        )
        expect(oversizedCurrentPlan.deliveryIssue?.contains("does not leave usable room") == true, "Context preflight blocks a current skill or self-edit payload that cannot fit even without prior history")
        expect(!oversizedCurrentPlan.didCompact, "Context preflight does not misrepresent an oversized current payload as successfully compacted")
        let largeContext = String(repeating: "older context ", count: 120)
        let nearLimitCLI = LatticeSession(
            title: "Near limit CLI",
            messages: [
                .init(role: .user, text: largeContext),
                .init(role: .assistant, text: largeContext),
                .init(role: .user, text: largeContext),
                .init(role: .assistant, text: largeContext),
                .init(role: .user, text: largeContext),
                .init(role: .assistant, text: "Recent answer"),
                .init(role: .user, text: "Now answer this"),
                .init(role: .assistant, text: "")
            ],
            backend: .grok(model: "grok-code-fast-1"),
            harnessThreadID: "grok-acp:existing"
        )
        let compactPlan = LatticeContextHandoffPlanner.plan(session: nearLimitCLI, submittedText: "Now answer this", tokenLimit: 120, existingHarnessThreadID: nearLimitCLI.harnessThreadID, compactionThreshold: 0.5)
        expect(compactPlan.prompt == "Now answer this" && !compactPlan.usesVisibleTranscriptHandoff && !compactPlan.didCompact && !compactPlan.resetsHarnessSession, "Near-limit resumed CLI sessions stay intact so the provider owns its native context lifecycle")
        let recoveredCompactPlan = LatticeContextHandoffPlanner.plan(session: nearLimitCLI, submittedText: "Now answer this", tokenLimit: 120, existingHarnessThreadID: nil, compactionThreshold: 0.5)
        expect(recoveredCompactPlan.usesVisibleTranscriptHandoff && recoveredCompactPlan.didCompact && recoveredCompactPlan.resetsHarnessSession, "Missing CLI sessions receive a bounded compacted visible handoff")
        expect(recoveredCompactPlan.prompt.contains("Older messages condensed by Lattice") && recoveredCompactPlan.prompt.contains("Current user request:\nNow answer this"), "Recovered CLI handoff preserves condensed history and current request")
        let healthyStructuredPlan = LatticeContextHandoffPlanner.plan(session: nearLimitCLI, submittedText: "Now answer this", tokenLimit: 20_000, existingHarnessThreadID: "structured-message-list", managementMode: .latticeManagedVisibleTranscript, compactionThreshold: 0.95)
        let healthyStructuredMessages = LatticeBackendMessageBuilder.structuredMessages(session: nearLimitCLI, submittedText: "Now answer this", contextPlan: healthyStructuredPlan)
        expect(!healthyStructuredPlan.usesVisibleTranscriptHandoff && healthyStructuredMessages.count == nearLimitCLI.messages.count - 1, "Structured backends keep normal message history while under context budget")
        let compactStructuredPlan = LatticeContextHandoffPlanner.plan(session: nearLimitCLI, submittedText: "Now answer this", tokenLimit: 120, existingHarnessThreadID: "structured-message-list", managementMode: .latticeManagedVisibleTranscript, compactionThreshold: 0.5)
        let compactStructuredMessages = LatticeBackendMessageBuilder.structuredMessages(session: nearLimitCLI, submittedText: "Now answer this", contextPlan: compactStructuredPlan)
        expect(compactStructuredPlan.didCompact && compactStructuredMessages.count == 1 && compactStructuredMessages.first?.role == .user, "Structured backends switch to one compacted handoff message near the context limit")
        expect(compactStructuredMessages.first?.text.contains("Lattice visible transcript handoff (compacted)") == true && compactStructuredMessages.first?.text.contains("Current user request:\nNow answer this") == true, "Structured backend compaction sends the same bounded handoff prompt")
        expect(LatticeBackendMessageBuilder.transcript(session: nearLimitCLI, submittedText: "Now answer this", contextPlan: compactStructuredPlan) == compactStructuredPlan.prompt, "Transcript backends use the compacted handoff prompt near the context limit")
        let hugeVisibleHistory = String(repeating: "Detailed old context that should be summarized or omitted safely. ", count: 500)
        let adaptiveCompactionSession = LatticeSession(
            title: "Adaptive compaction",
            messages: [
                .init(role: .user, text: hugeVisibleHistory),
                .init(role: .assistant, text: hugeVisibleHistory),
                .init(role: .user, text: hugeVisibleHistory),
                .init(role: .assistant, text: hugeVisibleHistory),
                .init(role: .user, text: "Current request"),
                .init(role: .assistant, text: "")
            ],
            backend: .ollama(model: "small")
        )
        let adaptivePlan = LatticeContextHandoffPlanner.plan(
            session: adaptiveCompactionSession,
            submittedText: "Please continue with the current task and preserve only the context needed to answer correctly.",
            tokenLimit: 260,
            existingHarnessThreadID: "structured-message-list",
            managementMode: .latticeManagedVisibleTranscript,
            compactionThreshold: 0.5
        )
        expect(adaptivePlan.didCompact && adaptivePlan.deliveryIssue == nil, "Adaptive visible-transcript compaction fits when the current request itself fits")
        expect(LatticeContextBudgetEstimator.estimateTokens(in: adaptivePlan.prompt) < 260, "Adaptive compaction reserves room for the current request and handoff instructions")
        let injectedBackendPrompt = "Lattice skill invocation: /subagents\n" + String(repeating: "large injected skill instructions ", count: 90)
        let smallVisibleSkillSession = LatticeSession(
            title: "Injected prompt estimate",
            messages: [
                .init(role: .user, text: "Earlier compact request"),
                .init(role: .assistant, text: "Earlier compact answer"),
                .init(role: .user, text: "/subagents do this"),
                .init(role: .assistant, text: "")
            ],
            backend: .ollama(model: "qwen3:8b")
        )
        let visibleOnlyEstimate = LatticeContextBudgetEstimator.estimate(session: smallVisibleSkillSession, draft: "/subagents do this", tokenLimit: 220)
        let backendPayloadEstimate = LatticeContextBudgetEstimator.estimateBackendPayload(session: smallVisibleSkillSession, submittedText: injectedBackendPrompt, tokenLimit: 220)
        expect(visibleOnlyEstimate.status == .comfortable && backendPayloadEstimate.status == .overLimit, "Backend payload context estimate accounts for injected prompts hidden behind short visible commands")
        let injectedPlan = LatticeContextHandoffPlanner.plan(
            session: smallVisibleSkillSession,
            submittedText: injectedBackendPrompt,
            tokenLimit: 220,
            existingHarnessThreadID: "structured-message-list",
            managementMode: .latticeManagedVisibleTranscript
        )
        expect(injectedPlan.didCompact && injectedPlan.usesVisibleTranscriptHandoff, "Context planner counts injected backend prompts, not only the short visible slash command")
        expect(injectedPlan.prompt.contains("Lattice skill invocation: /subagents"), "Compacted handoff preserves injected backend prompt as the current request")
        let encodedSession = try! JSONEncoder().encode(session)
        var legacyObject = try! JSONSerialization.jsonObject(with: encodedSession) as! [String: Any]
        legacyObject["actions"] = nil
        legacyObject["queuedFollowUps"] = nil
        legacyObject["isPinned"] = nil
        legacyObject["privacyMode"] = nil
        let legacyData = try! JSONSerialization.data(withJSONObject: legacyObject)
        expect((try! JSONDecoder().decode(LatticeSession.self, from: legacyData)).actions.isEmpty, "Legacy sessions migrate with an empty action trail")
        expect((try! JSONDecoder().decode(LatticeSession.self, from: legacyData)).queuedFollowUps.isEmpty, "Legacy sessions migrate with an empty follow-up queue")
        expect((try! JSONDecoder().decode(LatticeSession.self, from: legacyData)).isPinned == false, "Legacy sessions migrate as unpinned")
        expect((try! JSONDecoder().decode(LatticeSession.self, from: legacyData)).privacyMode == .cloudAllowed, "Legacy sessions default to cloud-allowed privacy")
        expect(ChatBackend.appleIntelligence.isLocal && ChatBackend.ollama(model: "llama3.2:latest").isLocal, "Local chat backends identify as local")
        expect(!ChatBackend.codex(model: "gpt-5.5").isLocal && !ChatBackend.grok(model: "grok").isLocal && !ChatBackend.openCode(model: "opencode").isLocal, "Cloud chat backends identify as non-local")
        expect(SessionPrivacyPolicy.allows(.codex(model: "gpt-5.5"), in: .cloudAllowed), "Cloud-allowed privacy accepts provider routes")
        expect(!SessionPrivacyPolicy.allows(.codex(model: "gpt-5.5"), in: .localOnly), "Local-only privacy rejects provider routes")
        expect(SessionPrivacyPolicy.allows(.ollama(model: "llama3.2:latest"), in: .localOnly), "Local-only privacy accepts local models")
        expect(SessionPrivacyPolicy.blockedMessage(for: .grok(model: "grok"), in: .localOnly)?.contains("Local-only") == true, "Local-only privacy gives a route-specific blocked reason")
        let pinnedMessage = ChatMessage(role: .assistant, text: "Important answer", isPinned: true)
        let pinnedMessageData = try! JSONEncoder().encode(pinnedMessage)
        expect((try! JSONDecoder().decode(ChatMessage.self, from: pinnedMessageData)).isPinned, "Pinned message state round trip")
        var legacyMessageObject = try! JSONSerialization.jsonObject(with: pinnedMessageData) as! [String: Any]
        legacyMessageObject["isPinned"] = nil
        let legacyMessageData = try! JSONSerialization.data(withJSONObject: legacyMessageObject)
        expect((try! JSONDecoder().decode(ChatMessage.self, from: legacyMessageData)).isPinned == false, "Legacy messages migrate as unpinned")
        var trail = [persistedAction]
        let waitingApproval = SessionAction(messageID: responseMessage.id, kind: .approval, title: "Allow edit", detail: "Sources/App.swift", status: .waiting)
        SessionActionTrail.upsert(waitingApproval, in: &trail)
        expect(SessionActionTrail.update(id: persistedAction.id, status: .failed, in: &trail), "Action trail correlates status by ID")
        expect(trail.first?.status == .failed, "Action trail status updates")
        expect(SessionActionTrail.finishPending(for: responseMessage.id, as: .cancelled, in: &trail) == 1 && trail.last?.status == .cancelled, "Pending action lifecycle closes truthfully")
        SessionActionTrail.prune(in: &trail, keepingMessageIDs: [])
        expect(trail.isEmpty, "Rerun pruning removes orphaned actions")
        let firstUser = ChatMessage(role: .user, text: "First")
        let firstAssistant = ChatMessage(role: .assistant, text: "First reply", isPinned: true)
        let secondUser = ChatMessage(role: .user, text: "Second")
        let secondAssistant = ChatMessage(role: .assistant, text: "Second reply")
        let retainedAction = SessionAction(messageID: firstAssistant.id, kind: .tool, title: "Read", detail: "README.md", status: .completed)
        let removedAction = SessionAction(messageID: secondAssistant.id, kind: .tool, title: "Write", detail: "README.md", status: .completed)
        var deletionSession = LatticeSession(
            title: "First",
            messages: [firstUser, firstAssistant, secondUser, secondAssistant],
            backend: .codex(model: "gpt-5.4"),
            harnessID: "pi",
            harnessThreadID: "provider-thread",
            workspacePath: "/tmp/Lattice",
            attachments: [.init(path: "/tmp/Lattice/PLAN.md")],
            policy: .smart,
            privacyMode: .localOnly,
            actions: [retainedAction, removedAction],
            queuedFollowUps: [.init(text: "Later")],
            isPinned: true
        )
        let branch = SessionTranscriptMutation.branchFromMessage(messageID: secondUser.id, in: deletionSession)!
        expect(branch.id != deletionSession.id && branch.title.hasPrefix("Branch:"), "Branching creates a separate visible chat")
        expect(branch.messages.map(\.id) == [firstUser.id, firstAssistant.id, secondUser.id], "Branching copies visible transcript up to the selected message")
        expect(branch.messages.first(where: { $0.id == firstAssistant.id })?.isPinned == true, "Branching preserves retained pinned messages")
        expect(branch.actions == [retainedAction] && branch.harnessThreadID == nil, "Branching prunes later actions and resets hidden provider context")
        expect(branch.backend == deletionSession.backend && branch.harnessID == deletionSession.harnessID && branch.workspacePath == deletionSession.workspacePath && branch.policy == deletionSession.policy && branch.privacyMode == deletionSession.privacyMode, "Branching preserves route, workspace, policy, and privacy")
        expect(branch.attachments == deletionSession.attachments && branch.queuedFollowUps.isEmpty && !branch.isPinned && !branch.isStreaming, "Branching preserves context but clears queue, pin, and streaming state")
        expect(SessionTranscriptMutation.branchFromMessage(messageID: UUID(), in: deletionSession) == nil, "Branching ignores stale message identifiers")
        expect(SessionTranscriptMutation.branchFromMessage(messageID: firstUser.id, in: LatticeSession(title: "Running", messages: [firstUser], backend: .codex(model: "gpt-5.4"), isStreaming: true)) == nil, "Branching is disabled while streaming")
        expect(SessionTranscriptMutation.deleteMessageAndFollowing(messageID: secondUser.id, in: &deletionSession), "Message deletion truncates a transcript branch")
        expect(deletionSession.messages.map(\.id) == [firstUser.id, firstAssistant.id], "Message deletion removes the selected message and every later message")
        expect(deletionSession.actions == [retainedAction] && deletionSession.harnessThreadID == nil, "Message deletion prunes orphaned actions and resets hidden provider context")
        expect(!SessionTranscriptMutation.deleteMessageAndFollowing(messageID: UUID(), in: &deletionSession), "Message deletion ignores stale message identifiers")
        expect(SessionTranscriptMutation.deleteMessageAndFollowing(messageID: firstUser.id, in: &deletionSession) && deletionSession.messages.isEmpty && deletionSession.title == "New chat" && deletionSession.intent == nil, "Deleting the first user turn restores a clean unstarted chat")
        let searchAssistant = ChatMessage(role: .assistant, text: "I checked the build.")
        let searchAction = SessionAction(messageID: searchAssistant.id, kind: .tool, toolKind: .command, title: "Run verifier", detail: "swift verify_core emitted sandbox denial details", status: .completed, workspaceScoped: true)
        let searchSession = LatticeSession(title: "Release audit", messages: [.init(role: .user, text: "Ship check"), searchAssistant], backend: .openCode(model: "opencode/qwen3-coder"), harnessID: "hermes", workspacePath: "/tmp/Lattice", attachments: [.init(path: "/tmp/Lattice/PLAN.md")], actions: [searchAction])
        expect(searchSession.matchesSearch("release audit"), "Session search matches title tokens")
        expect(searchSession.matchesSearch("sandbox denial"), "Session search matches action detail/tool output tokens")
        expect(searchSession.matchesSearch("PLAN.md"), "Session search matches attachment names")
        expect(searchSession.matchesSearch("hermes qwen3"), "Session search matches route and model tokens")
        expect(!searchSession.matchesSearch("unrelated token"), "Session search rejects unrelated token sets")
        expect(session.matchesSearch("pinned"), "Session search matches pinned state")
        let pinnedMessageSearchSession = LatticeSession(title: "Pinned transcript", messages: [.init(role: .assistant, text: "Keep this answer", isPinned: true)], backend: .codex(model: "gpt-5.4"))
        expect(pinnedMessageSearchSession.matchesSearch("pinned answer"), "Session search matches pinned message state")
        let queuedSearchSession = LatticeSession(title: "Queued search", messages: [], backend: .codex(model: "gpt-5.4"), queuedFollowUps: [.init(text: "Remember the lavender follow-up")])
        expect(queuedSearchSession.matchesSearch("lavender follow-up"), "Session search matches queued follow-up text")
        expect(LatticeSession(title: "Privacy", backend: .ollama(model: "llama3.2:latest"), privacyMode: .localOnly).matchesSearch("local-only private"), "Session search matches local-only privacy state")
        var completedTurnActions = [
            SessionAction(messageID: responseMessage.id, kind: .tool, toolKind: .command, title: "Build", detail: "$ swift build", status: .running),
            SessionAction(messageID: responseMessage.id, kind: .approval, title: "Allow edit", detail: "Sources/App.swift", status: .waiting),
            SessionAction(messageID: responseMessage.id, kind: .tool, toolKind: .write, title: "Patch", detail: "Sources/App.swift", status: .failed)
        ]
        expect(SessionActionTrail.finishCompletedTurn(for: responseMessage.id, in: &completedTurnActions) == 2, "Completed turn closes only open actions")
        expect(completedTurnActions.map(\.status) == [.completed, .cancelled, .failed], "Completed turn marks tools complete and stale approvals cancelled")
        let interruptedAction = SessionAction(messageID: responseMessage.id, kind: .tool, toolKind: .command, title: "Build", detail: "$ swift build", status: .running)
        try! store.save([LatticeSession(title: "Interrupted action", messages: [responseMessage], backend: .codex(model: "gpt-5.4"), actions: [interruptedAction], isStreaming: true)])
        let recovered = store.load().first
        expect(recovered?.isStreaming == false && recovered?.actions.first?.status == .interrupted, "Restoration closes orphaned running actions")
        let selfEditSession = LatticeSession(title: "Lattice self-edit", backend: .grok(model: "grok"), intent: .selfEdit)
        try! store.save([selfEditSession])
        expect(store.load().first?.intent == .selfEdit, "Self-edit intent round trip")
        expect(LatticeSelfEditCommand.prompt(in: "/self-edit make the composer calmer") == "make the composer calmer", "Self-edit slash command parses prompt")
        expect(LatticeSelfEditCommand.prompt(in: "/self-editor nope") == nil, "Self-edit slash command requires exact command")
        expect(LatticeSelfEditCommand.prompt(in: "make Lattice glassy") == nil, "Plain Lattice wording does not trigger self-edit")
        expect(LatticeAppCommandCatalog.suggestions(for: "/").first?.invocation == "/self-edit", "Slash command catalog exposes self-edit")
        expect(LatticeAppCommandCatalog.suggestions(for: "/self").first?.id == "self-edit", "Slash command catalog filters self-edit")
        expect(LatticeAppCommandCatalog.completion(for: "/")?.id == "self-edit", "Slash command catalog completes single command")
        expect(LatticeAppCommandCatalog.completion(for: "/self")?.id == "self-edit", "Slash command catalog completes typed prefix")
        expect(LatticeAppCommandCatalog.suggestions(for: "/self-edit ").isEmpty, "Slash command catalog hides after inserted command")
        expect(LatticeAppCommandCatalog.completion(for: "/self-edit ") == nil, "Slash command catalog does not complete after separator")
        expect(LatticeAppCommandCatalog.suggestions(for: "/self-edit make it calmer").isEmpty, "Slash command catalog hides after command token")
        expect(LatticeAppCommandCatalog.suggestions(for: "self-edit").isEmpty, "Slash command catalog requires slash prefix")
        expect(CommandSuggestionLayoutPolicy.height(resultCount: 0) == 0, "Empty slash suggestions reserve no height")
        expect(CommandSuggestionLayoutPolicy.height(resultCount: 100) == 378, "Large slash catalogs use a bounded viewport")
        let modeScopedOpenCodeRoute = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")
        expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: modeScopedOpenCodeRoute, enabledModes: [.code]), "OpenCode key may be injected only after Code consent")
        expect(!OpenCodeCredentialPolicy.allowsKeychainCredential(for: modeScopedOpenCodeRoute, enabledModes: [.work]), "OpenCode Work consent does not authorize Code injection")
        expect(RuntimeInstallDescriptor.pi.installReference.hasSuffix("@0.80.6"), "Pi first-use setup is pinned")
        expect(RuntimeArtifactVerification.registryIntegrityMatches(reported: "\"\(RuntimeInstallDescriptor.pi.registryIntegrity!)\"", expected: RuntimeInstallDescriptor.pi.registryIntegrity!), "Pi registry integrity accepts only exact pinned metadata")
        expect(!RuntimeArtifactVerification.registryIntegrityMatches(reported: "sha512-wrong", expected: RuntimeInstallDescriptor.pi.registryIntegrity!), "Pi registry integrity mismatch fails closed")
        expect(RuntimeLifecycleTransition.phaseAfterCancellation(from: .installing) == .cancelled, "First-use install cancellation stays cancelled")
        expect(RuntimeLifecycleTransition.phaseAfterCancellation(from: .updating) == .updateInterrupted, "Update cancellation is reported as interrupted")
        expect(RuntimeLifecycleTransition.rollbackPhase(previousVersion: nil) == .failed, "Rollback without recorded prior version fails closed")
        expect(RuntimeLifecyclePresentationPolicy.actionTitle(for: .firstUseInstall) == "Install", "Missing runtimes use the Install action")
        expect(RuntimeLifecyclePresentationPolicy.actionTitle(for: .update, installedVersion: "0.79.3", targetVersion: "0.80.6") == "Update", "Newer runtime targets use the Update action")
        expect(RuntimeLifecyclePresentationPolicy.actionTitle(for: .update, installedVersion: "0.80.6", targetVersion: "0.80.6") == "Repair", "Same-version runtime reinstalls use the Repair action")
        expect(RuntimeLifecyclePresentationPolicy.actionTitle(for: .uninstall) == "Remove", "Runtime uninstall uses the Remove action")
        expect(ExecutionRouteReadiness.loading.detail == "Checking availability…", "Loading routes use the shared availability wording")
        expect(ExecutionRouteReadiness.authenticationRequired.detail == "Sign in required.", "Authentication blockers use the Sign in wording")
        expect(ExecutionRouteReadiness.runnable.detail == "Available", "Runnable routes use the Available state")
        expect(ExecutionRouteReadiness.loading.conciseStatus == "checking", "Compact loading state is explicit")
        expect(ExecutionRouteReadiness.missingRuntime.conciseStatus == "setup needed", "Compact setup state is explicit")
        expect(ExecutionRouteReadiness.authenticationRequired.conciseStatus == "sign-in needed", "Compact sign-in state is explicit")
        expect(ExecutionRouteReadiness.runnable.conciseStatus == "ready", "Compact ready state is explicit")
        expect(ExecutionRouteReadiness.failed("offline").conciseStatus == "unavailable", "Compact failure state is explicit")
        let unavailableProviderCopy = ProviderReadinessPresentationPolicy.copy(providerName: "Codex", readiness: .init(installed: true, authenticated: true, catalogStatus: .failed, runnableModelCount: 0))
        expect(unavailableProviderCopy.detail == "Signed in · models unavailable", "Provider model failures use the shared Unavailable state")
        expect(!RuntimeOwnershipPolicy.canUninstall(.pi, managedRuntimeIDs: []), "External runtimes cannot be removed by Lattice")
        expect(!RuntimeOwnershipPolicy.shouldRecordOwnership(after: .update, status: 0, executableAvailable: true), "Updating an external runtime does not transfer ownership")
        let safeProviderEnvironment = ChildProcessEnvironmentPolicy.providerOwnedRuntime(
            from: ["PATH": "/usr/bin", "HOME": "/Users/example", "OPENAI_API_KEY": "synthetic-secret"],
            temporaryDirectory: URL(fileURLWithPath: "/tmp/lattice-provider")
        )
        expect(safeProviderEnvironment["PATH"] == "/usr/bin", "Provider child environment preserves required executable search path")
        expect(safeProviderEnvironment["OPENAI_API_KEY"] == nil, "Provider child environment excludes ambient credentials")
        let legacyOpenCodeRoute = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "legacy", runtimeID: "opencode")
        expect(LegacyOpenCodeBridgePolicy.allows(legacyOpenCodeRoute), "OpenCode bridge remains limited to direct legacy routes")
        expect(!LegacyOpenCodeBridgePolicy.allows(modeScopedOpenCodeRoute), "New Pi OpenCode routes cannot use legacy auth-file bridge")
        expect(RuntimeInstallDescriptor.hermes.pinnedSourceCommit == "b7751df34688835a108e0d630f3495fc11f3df79", "Hermes first-use setup pins an immutable commit")
        expect(OllamaClient.deleteTimeout > 0, "Local model deletion has a bounded request timeout")
        expect(OllamaModelDeletionResult.deleted == .deleted, "Local model deletion result represents confirmed success")
        let templateCommand = LatticePromptTemplate(invocation: "/brief", title: "Brief", detail: "Make concise", prompt: "Make this concise.").command
        expect(LatticeAppCommandCatalog.suggestions(for: "/b", commands: LatticeAppCommandCatalog.all + [templateCommand]).first?.invocation == "/brief", "Extension prompt template appears in slash suggestions")
        expect(LatticeAppCommandCatalog.completion(for: "/b", commands: LatticeAppCommandCatalog.all + [templateCommand])?.replacementText == "Make this concise.", "Extension prompt template inserts prompt text")
        let duplicateTemplateCommand = LatticePromptTemplate(invocation: "/brief", title: "Brief Again", detail: "Other prompt", prompt: "Use this other prompt.").command
        let deduplicatedTemplateSuggestions = LatticeAppCommandCatalog.suggestions(for: "/b", commands: LatticeAppCommandCatalog.all + [templateCommand, duplicateTemplateCommand])
        expect(deduplicatedTemplateSuggestions.map(\.replacementText) == ["Make this concise."], "Duplicate extension prompt template invocation keeps first command")
        expect(LatticeAppCommandCatalog.completion(for: "/b", commands: LatticeAppCommandCatalog.all + [templateCommand, duplicateTemplateCommand])?.replacementText == "Make this concise.", "Duplicate extension prompt template still completes")
        let skillBriefCommand = LatticeAppCommand(id: "skill:brief", invocation: "/brief", title: "Brief Skill", detail: "Run the skill")
        let skillFirstCompletion = LatticeAppCommandCatalog.completion(for: "/b", commands: LatticeAppCommandCatalog.all + [skillBriefCommand, templateCommand])
        expect(skillFirstCompletion?.id == "skill:brief" && skillFirstCompletion?.replacementText == nil, "Slash command suggestions prefer enabled skills over colliding prompt templates")
        let paletteItems = [
            LatticeCommandPaletteItem(id: "new-chat", title: "New Chat", detail: "Start a fresh conversation", keywords: ["session"]),
            LatticeCommandPaletteItem(id: "continue", title: "Continue Response", detail: "Resume the selected assistant answer", keywords: ["more"], isEnabled: false, disabledReason: "No completed assistant response"),
            LatticeCommandPaletteItem(id: "models", title: "Show Models", detail: "Review connected provider models", keywords: ["provider catalog"]),
            LatticeCommandPaletteItem(id: "open-skills-folder", title: "Open Skills Folder", detail: "Show Lattice’s shared SKILL.md folder", keywords: ["skills", "agents", "application support"])
        ]
        expect(LatticeCommandPaletteMatcher.filtered(paletteItems, query: "").map(\.id) == ["new-chat", "continue", "models", "open-skills-folder"], "Command palette keeps source order for empty search")
        expect(LatticeCommandPaletteMatcher.filtered(paletteItems, query: "provider models").map(\.id) == ["models"], "Command palette matches multi-token detail and keyword search")
        expect(LatticeCommandPaletteMatcher.filtered(paletteItems, query: "fresh session").map(\.id) == ["new-chat"], "Command palette matches keyword-backed commands")
        expect(LatticeCommandPaletteMatcher.filtered(paletteItems, query: "skill md").map(\.id) == ["open-skills-folder"], "Command palette exposes the shared skills folder")
        expect(LatticeCommandPaletteMatcher.firstEnabled(in: paletteItems, query: "response") == nil, "Command palette does not auto-run disabled matches")
        expect(LatticeCommandPaletteMatcher.firstEnabled(in: paletteItems, query: "show")?.id == "models", "Command palette selects first enabled filtered command")
        let quickChatID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let quickChat = LatticeSession(
            id: quickChatID,
            title: "Repair navigation",
            backend: .codex(model: "gpt-5"),
            workspacePath: "/tmp/Lattice",
            lastUpdated: Date(timeIntervalSince1970: 10)
        )
        var quickChatLanes = ThreadActivityLaneStore()
        quickChatLanes.apply(.failed("Provider exited"), to: quickChatID)
        let quickChatItems = LatticeCommandPaletteChatNavigation.items(
            sessions: [quickChat],
            activityLanes: quickChatLanes,
            selectedSessionID: nil
        )
        expect(quickChatItems.first?.kind == .chat(quickChatID), "Command palette exposes durable chats as navigation targets")
        expect(quickChatItems.first?.chatState?.activityStatus == .failed && quickChatItems.first?.chatState?.requiresAttention == true, "Command palette exposes truthful chat failure attention")
        expect(LatticeCommandPaletteChatNavigation.visibleItems(chats: quickChatItems, commands: paletteItems, query: "repair").map(\.kind) == [.chat(quickChatID)], "Command palette searches chat titles alongside commands")
        expect(LatticeCommandPaletteChatNavigation.visibleItems(chats: quickChatItems, commands: paletteItems, query: "lattice").contains(where: { $0.kind == .chat(quickChatID) }), "Command palette searches workspace metadata without transcript hydration")
        quickChatLanes.apply(.started, to: quickChatID)
        let recoveredQuickChat = LatticeCommandPaletteChatNavigation.items(sessions: [quickChat], activityLanes: quickChatLanes, selectedSessionID: quickChatID)[0]
        expect(recoveredQuickChat.chatState?.activityStatus == .running && recoveredQuickChat.chatState?.requiresAttention == false, "Command palette chat status recovers when work restarts")
        let route = EngineHarnessSelection(engineID: "codex", harnessID: "codex")
        let routeData = try! JSONEncoder().encode(route)
        expect((try! JSONDecoder().decode(EngineHarnessSelection.self, from: routeData)) == route, "Engine harness route round trip")
        let staleRoute = EngineHarnessSelection(engineID: "xai", harnessID: "hermes")
        let staleRouteData = try! JSONEncoder().encode(staleRoute)
        expect((try! JSONDecoder().decode(EngineHarnessSelection.self, from: staleRouteData)).harnessID == "hermes", "Legacy route remains decodable")
        let normalizedRoute = ExecutionRoutePolicy.normalize(staleRoute, fallbackEngineID: "codex", fallbackHarnessID: "codex")
        expect(normalizedRoute == EngineHarnessSelection(engineID: "codex", harnessID: "codex"), "Unqualified execution route normalized")
        expect(ExecutionRoutePolicy.normalize(route, fallbackEngineID: "codex", fallbackHarnessID: "codex") == route, "Qualified execution route preserved")
        expect(ExecutionRoutePolicy.normalize(EngineHarnessSelection(engineID: "codex", harnessID: "grok"), fallbackEngineID: "opencode", fallbackHarnessID: "opencode") == EngineHarnessSelection(engineID: "codex", harnessID: "codex"), "Incompatible execution route normalized")
        let modeCatalog = ExecutionRouteResolver.catalog(readiness: .validating)
        expect(modeCatalog.entries(for: .code).count == 4, "Code route catalog filters by mode")
        expect(modeCatalog.entries(for: .work).count == 3, "Work route catalog filters by mode")
        expect(modeCatalog.entries(for: .local).count == 2, "Local route catalog filters by mode")
        expect(ExecutionRouteResolver.resolve(mode: .local, providerID: "codex", modelID: "gpt-5.5") == nil, "Local route never falls back to cloud")
        expect(ExecutionRouteResolver.resolve(mode: .work, providerID: "ollama", modelID: "qwen3:8b") == nil, "Work route never falls back to local")
        expect(ExecutionRouteResolver.resolve(mode: .work, providerID: "opencode", modelID: "opencode-go:deepseek-v4") == ExecutionRoute(mode: .work, providerID: "opencode", modelID: "opencode-go:deepseek-v4", runtimeID: "hermes"), "Explicit Work route stays exact")
        let setupReadinessAction = HarnessReadinessActionPolicy.resolve(readiness: .missingRuntime, modeName: "Code", runtimeName: "Pi")
        expect(setupReadinessAction.kind == .setupRuntime && setupReadinessAction.title == "Set Up Code" && setupReadinessAction.isEnabled, "Missing runtime resolves to an enabled exact setup action")
        let readyReadinessAction = HarnessReadinessActionPolicy.resolve(readiness: .runnable, modeName: "Code", runtimeName: "Pi")
        expect(readyReadinessAction.kind == .stateOnly && !readyReadinessAction.isInteractive, "Ready status remains non-interactive state")
        let busyFailureAction = HarnessReadinessActionPolicy.resolve(readiness: .failed("Offline"), modeName: "Work", runtimeName: "Hermes", actionAvailable: false)
        expect(busyFailureAction.kind == .diagnostics && !busyFailureAction.isEnabled, "Failed readiness resolves to diagnostics and rejects duplicate activation while busy")
        expect(!SessionPrivacyPolicy.allows(.codex(model: "gpt-5.5"), in: .localOnly), "Local-only blocks cloud route")
        expect(SessionPrivacyPolicy.allows(.ollama(model: "qwen3:8b"), in: .localOnly), "Local-only accepts local route")
        let instructionEnvelope = try! LatticeInstructionEnvelope(selectedMode: .work, workspaceInstructionsTrusted: true, trustedWorkspaceInstructionNames: ["AGENTS.md"], workUserAddOn: "work")
        expect(instructionEnvelope.activeUserAddOn == "work" && instructionEnvelope.renderedSystemInstructions.contains("not a permission boundary"), "Instruction envelope preserves Work guidance hierarchy")
        let installerTrust = RemoteInstallerScriptPolicy.trust(for: Data("#!/bin/sh\n".utf8), expectedSHA256Hex: String(repeating: "0", count: 64))
        expect(!installerTrust.isAuthenticated && RemoteInstallerScriptPolicy.executionMessage(for: installerTrust) != nil, "Installer hash failure blocks execution")
        let interrupted = SessionPersistence.restoreRuntimeState([LatticeSession(title: "interrupted", backend: .codex(model: "gpt"), actions: [SessionAction(messageID: UUID(), kind: .tool, title: "running", detail: "", status: .running)], isStreaming: true)])
        expect(interrupted.first?.isStreaming == false && interrupted.first?.actions.first?.status == .interrupted, "Interrupted session state restores fail-closed")
        // Work-mode projection foundation: typed payload migration, ranking, restore reconciliation,
        // and portable archive exclusion (native suite not executed in fallback mode).
        let workMessageID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let workApprovalID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let workTaskID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let workArtifactID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let workLegacyObject: [String: Any] = [
            "id": workTaskID.uuidString,
            "messageID": workMessageID.uuidString,
            "kind": "plan",
            "title": "Legacy step",
            "detail": "",
            "status": "waiting",
            "workspaceScoped": false,
            "createdAt": Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate,
            "updatedAt": Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate
        ]
        let workLegacyDecoded = try! JSONDecoder().decode(SessionAction.self, from: try! JSONSerialization.data(withJSONObject: workLegacyObject))
        expect(workLegacyDecoded.work == nil, "Legacy SessionAction JSON migrates without work payload")
        let workApproval = SessionAction(
            id: workApprovalID,
            messageID: workMessageID,
            kind: .approval,
            title: "Allow",
            detail: "path",
            status: .waiting,
            work: SessionWorkSemantics(kind: .approval, ownership: .providerBound)
        )
        let workTask = SessionAction(
            id: workTaskID,
            messageID: workMessageID,
            kind: .plan,
            title: "Confirm",
            detail: "",
            status: .waiting,
            work: SessionWorkSemantics(kind: .taskStep, ownership: .userOwned, stepKey: "t1", taskMark: .unchecked)
        )
        let workArtifact = SessionAction(
            id: workArtifactID,
            messageID: workMessageID,
            kind: .tool,
            title: "Report",
            detail: "/secret/must-not-infer",
            status: .completed,
            work: SessionWorkSemantics(kind: .artifact, ownership: .userOwned, artifactLocator: "out/report.md")
        )
        let workRoundTrip = try! JSONDecoder().decode(SessionAction.self, from: try! JSONEncoder().encode(workTask))
        expect(workRoundTrip.work == workTask.work, "Work semantics round-trip through SessionAction JSON")
        let workLive = WorkProjection.project(
            mode: .work,
            actions: [workArtifact, workTask, workApproval],
            liveApprovalIDs: [workApprovalID]
        )
        expect(workLive.depth == .rich && workLive.actionable?.id == workApprovalID && workLive.actionable?.kind == .liveApproval, "Work projection ranks live approval first")
        let workNoLive = WorkProjection.project(mode: .work, actions: [workArtifact, workTask, workApproval])
        expect(workNoLive.actionable?.id == workTaskID && workNoLive.actionable?.allowsMarkConfirm == true, "Without live IDs, user-owned task is actionable and markable")
        expect(WorkProjection.project(mode: .code, actions: [workApproval], liveApprovalIDs: [workApprovalID]).actionable == nil, "Code mode stays concise")
        expect(WorkProjection.project(mode: .local, actions: [workApproval], liveApprovalIDs: [workApprovalID]).depth == .collapsed, "Local mode is not expanded")
        expect(WorkProjection.canMarkOrConfirm(workTask) && !WorkProjection.canMarkOrConfirm(workApproval), "Mark/confirm only for user-owned task steps")
        let workRestored = SessionPersistence.restoreRuntimeState([
            LatticeSession(
                title: "work-restore",
                backend: .openCode(model: "m"),
                executionRoute: ExecutionRoute(mode: .work, providerID: "opencode", modelID: "m", runtimeID: "hermes"),
                actions: [workApproval, workTask, workArtifact],
                isStreaming: true
            )
        ])
        expect(workRestored.first?.isStreaming == false, "Work restore clears streaming")
        expect(workRestored.first?.actions.first(where: { $0.id == workApprovalID })?.status == .interrupted, "Restored provider approval is interrupted")
        expect(workRestored.first?.actions.first(where: { $0.id == workTaskID })?.status == .waiting, "Restored user-owned pending task is preserved")
        expect(workRestored.first?.actions.first(where: { $0.id == workArtifactID })?.status == .completed, "Terminal artifact status is preserved")
        let workAfterRestore = WorkProjection.project(mode: .work, actions: workRestored.first?.actions ?? [])
        expect(workAfterRestore.actionable?.kind != .liveApproval && workAfterRestore.actionable?.kind != .liveQuestion, "Restored approvals/questions are never actionable without live IDs")
        var completedTurnWork = [workTask, workApproval]
        _ = SessionActionTrail.finishCompletedTurn(for: workMessageID, in: &completedTurnWork, at: Date(timeIntervalSince1970: 1_700_000_010))
        expect(completedTurnWork.first(where: { $0.id == workTaskID })?.status == .interrupted, "Pending plan work is explicit interrupted after turn completion")
        expect(completedTurnWork.first(where: { $0.id == workApprovalID })?.status == .cancelled, "Pending approval is cancelled after turn completion")
        let workQuestion = SessionAction(
            messageID: workMessageID,
            kind: .harness,
            title: "Choose format",
            detail: "PDF or Markdown",
            status: .waiting,
            work: SessionWorkSemantics(kind: .question, ownership: .userOwned)
        )
        let workAnswerID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let answeredWorkQuestion = WorkProjection.applyingAnswer(messageID: workAnswerID, to: workQuestion)
        expect(answeredWorkQuestion?.status == .completed && answeredWorkQuestion?.work?.resolutionMessageID == workAnswerID, "User-owned question records one durable answer link")
        expect(answeredWorkQuestion.flatMap { WorkProjection.applyingAnswer(messageID: UUID(), to: $0) } == nil, "Answered work question cannot be answered twice")
        let workCopy = WorkItemPresentationPolicy.presentation(
            for: WorkProjection.project(mode: .work, actions: [workApproval], liveApprovalIDs: [workApprovalID]).actionable!,
            action: workApproval
        )
        expect(workCopy.accessibilityLabel.contains("Approval required") && workCopy.status == "Waiting for your decision", "Work request accessibility copy names status")
        let workRoot = URL(fileURLWithPath: "/tmp")
        expect(WorkArtifactAccessPolicy.canOpen(locator: "Lattice/Deliverables/report.pdf", workspace: workRoot) && !WorkArtifactAccessPolicy.canOpen(locator: "/Applications/Unsafe.app", workspace: workRoot), "Artifact policy opens only safe workspace documents")
        expect(WorkDockLayoutPolicy.actionLayout(forAvailableWidth: 360) == .stacked && WorkDockLayoutPolicy.actionLayout(forAvailableWidth: 760) == .horizontal, "Work dock layout responds at compact widths")
        let workPortable = try! SessionPortableArchiveExporter.exportData(
            from: LatticeSession(
                title: "portable-work",
                messages: [ChatMessage(id: workMessageID, role: .assistant, text: "done", date: Date(timeIntervalSince1970: 1_700_000_000))],
                backend: .openCode(model: "m"),
                actions: [workTask, workArtifact]
            ),
            options: .init(includeQueuedFollowUps: false, format: .jsonArchive, exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        )
        let workPortableText = String(decoding: workPortable, as: UTF8.self)
        expect(!workPortableText.contains("out/report.md") && !workPortableText.contains("\"work\""), "Portable archives omit work payload and artifact locators")
        let hermesRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-hermes-verifier-\(UUID().uuidString)")
        let hermesProfile = LatticeHermesProfile(hermesHome: hermesRoot.appendingPathComponent("profile"))
        let hermesScratch = hermesRoot.appendingPathComponent("scratch")
        try! FileManager.default.createDirectory(at: hermesScratch, withIntermediateDirectories: true)
        let hermesEnvironment = try! hermesProfile.launchEnvironment(base: ["PATH": "/usr/bin"], temporaryDirectory: hermesScratch, route: LatticeHermesWorkRoute(provider: "opencode-go", model: "opencode-go:model"), opencodeAPIKey: "verifier-secret")
        expect(hermesEnvironment["OPENCODE_GO_API_KEY"] == "verifier-secret" && hermesEnvironment["OPENCODE_API_KEY"] == nil, "Hermes OpenCode Go credential name is provider-specific")
        try? FileManager.default.removeItem(at: hermesRoot)
        let visibleFallback = BackendAvailabilitySnapshot(
            codexModels: [],
            grokModels: [.init(id: "grok-1", name: "Grok 1", isDefault: true)],
            codexCatalogKnown: true,
            grokCatalogKnown: true,
            codexInstalled: true
        )
        expect(BackendAvailabilityPolicy.normalize(.codex(model: "hidden"), using: visibleFallback) == .grok(model: "grok-1"), "Hidden Codex model falls back to visible provider model")
        let unknownCatalog = BackendAvailabilitySnapshot(codexModels: [], codexCatalogKnown: false, codexInstalled: true)
        expect(BackendAvailabilityPolicy.normalize(.codex(model: "gpt-5.5"), using: unknownCatalog) == .codex(model: "gpt-5.5"), "Unknown Codex catalog preserves explicit model provenance")
        expect(BackendAvailabilityPolicy.normalize(.codex(model: ""), using: unknownCatalog) == .codex(model: ""), "Unknown Codex catalog preserves empty model sentinel without inventing a slug")
        expect(unknownCatalog.preferredBackend == .ollama(model: ""), "Missing Codex catalog does not invent a preferred Codex model")
        let allHidden = BackendAvailabilitySnapshot(codexModels: [], codexCatalogKnown: true, codexInstalled: true)
        expect(BackendAvailabilityPolicy.normalize(.codex(model: "hidden"), using: allHidden) == .ollama(model: ""), "All hidden cloud models produce non-runnable fallback")
        expect(BackendAvailabilityPolicy.normalize(.codex(model: ""), using: allHidden) == .codex(model: ""), "Known empty Codex catalog preserves the explicit no-model selection")
        let discoveredCatalog = BackendAvailabilitySnapshot(
            codexModels: [
                .init(id: "gpt-discovered", name: "Discovered", isDefault: true),
                .init(id: "gpt-other", name: "Other")
            ],
            codexCatalogKnown: true,
            codexInstalled: true
        )
        expect(BackendAvailabilityPolicy.normalize(.codex(model: ""), using: discoveredCatalog) == .codex(model: ""), "Discovered Codex catalog preserves the explicit no-model selection")
        expect(BackendAvailabilityPolicy.normalize(.codex(model: "retired"), using: discoveredCatalog) == .codex(model: "gpt-discovered"), "Discovered Codex catalog replaces stale selection with preferred model")
        expect(BackendAvailabilityPolicy.normalize(.codex(model: "gpt-other"), using: discoveredCatalog) == .codex(model: "gpt-other"), "Discovered Codex catalog preserves known membership without version heuristics")
        let disconnectedCloud = BackendAvailabilitySnapshot(
            codexModels: [.init(id: "gpt-5.5", name: "GPT-5.5", isDefault: true)],
            grokModels: [.init(id: "grok-4", name: "Grok 4", isDefault: true)],
            openCodeModels: [.init(id: "opencode/model", name: "OpenCode Model", isDefault: true)],
            codexReady: false,
            grokReady: false,
            openCodeReady: false,
            codexCatalogKnown: true,
            grokCatalogKnown: true,
            openCodeCatalogKnown: true,
            ollamaModelNames: ["llama3.2:latest"],
            codexInstalled: true
        )
        expect(BackendAvailabilityPolicy.normalize(.codex(model: "gpt-5.5"), using: disconnectedCloud) == .ollama(model: "llama3.2:latest"), "Disconnected provider catalog falls back to runnable local model")
        expect(BackendAvailabilityPolicy.normalize(.codex(model: "gpt-5.4"), using: disconnectedCloud) == .ollama(model: "llama3.2:latest"), "Disconnected stale Codex model does not migrate to disconnected preferred model")
        expect(BackendAvailabilityPolicy.normalize(.openCode(model: "opencode/model"), using: disconnectedCloud) == .ollama(model: "llama3.2:latest"), "Disconnected OpenCode catalog is not treated as runnable")
        let localOnly = BackendAvailabilitySnapshot(ollamaModelNames: ["llama3.2:latest"])
        expect(BackendAvailabilityPolicy.normalize(.ollama(model: ""), using: localOnly) == .ollama(model: ""), "Empty local backend stays unresolved")
        let modelLessArchive = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","chat":{"title":"Model-less","backendRoute":"ollama","policy":"Ask","privacyMode":"cloudAllowed"}}
        """
        let modelLessImport = try! SessionPortableArchiveImporter.prepareImport(data: Data(modelLessArchive.utf8), existingSessions: [])
        expect(modelLessImport.session.backend == .ollama(model: ""), "Model-less archive preserves empty Ollama provenance")
        let discoveredOllama = BackendAvailabilitySnapshot(ollamaModelNames: ["qwen3:8b"])
        expect(BackendAvailabilityPolicy.normalize(.ollama(model: "qwen3:8b"), using: discoveredOllama) == .ollama(model: "qwen3:8b"), "Discovered Ollama model recovers exact route")
        expect(ExecutionRoutePolicy.defaultHarnessID(for: "ollama") == "lattice", "Ollama defaults to Lattice harness")
        expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "ollama") == ["lattice"], "Ollama only exposes its implemented Lattice route")
        expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "codex").contains("pi"), "Codex can execute through Pi RPC")
        expect(ExecutionRoutePolicy.compatibleHarnessIDs(for: "opencode").contains("hermes"), "Compatible OpenCode models can execute through Hermes ACP")
        expect(!ExecutionRoutePolicy.compatibleHarnessIDs(for: "apple").contains("codex"), "Apple does not expose Codex harness")
        try? FileManager.default.removeItem(at: root)

        let codexWorkspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: codexWorkspace, withIntermediateDirectories: true)
        let codexApprovalObject: [String: Any] = [
            "method": "item/commandExecution/requestApproval",
            "id": 77,
            "params": [
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "command-1",
                "startedAtMs": 1,
                "command": "swift build",
                "cwd": codexWorkspace.path,
                "availableDecisions": ["accept", "acceptForSession", "decline", "cancel"]
            ]
        ]
        let codexApproval = CodexExecHarness.appServerPermissionRequest(from: codexApprovalObject, workspace: codexWorkspace)
        expect(codexApproval?.toolRequest?.kind == .command && codexApproval?.toolRequest?.workspaceScoped == true, "Codex command approval is workspace classified")
        expect(codexApproval?.options.map(\.id) == ["accept", "acceptForSession", "decline", "cancel"], "Codex approval decisions preserve server capabilities")
        expect(codexApproval?.options.first(where: { $0.id == "acceptForSession" })?.kind == "allow_session", "Codex session approval is classified as session-scoped")
        expect(ApprovalOptionPolicy.visibleOptions(codexApproval?.options ?? [], under: .smart).map(\.id) == ["accept", "acceptForSession", "decline"], "Smart exposes Codex session approval")
        let outsideCodexApprovalObject: [String: Any] = [
            "method": "item/commandExecution/requestApproval",
            "id": 78,
            "params": ["command": "open /tmp", "cwd": "/tmp", "availableDecisions": ["accept", "decline"]]
        ]
        expect(CodexExecHarness.appServerPermissionRequest(from: outsideCodexApprovalObject, workspace: codexWorkspace)?.toolRequest?.workspaceScoped == false, "Codex command approval detects out-of-workspace execution")
        let missingRootCodexApprovalObject: [String: Any] = [
            "method": "item/fileChange/requestApproval",
            "params": ["reason": "Apply patch"]
        ]
        expect(CodexExecHarness.appServerPermissionRequest(from: missingRootCodexApprovalObject, workspace: codexWorkspace)?.toolRequest?.workspaceScoped == false, "Codex file approval fails closed without grantRoot")
        let emptyRootCodexApprovalObject: [String: Any] = [
            "method": "item/fileChange/requestApproval",
            "params": ["grantRoot": "", "reason": "Apply patch"]
        ]
        expect(CodexExecHarness.appServerPermissionRequest(from: emptyRootCodexApprovalObject, workspace: codexWorkspace)?.toolRequest?.workspaceScoped == false, "Codex file approval fails closed with empty grantRoot")
        let emptyCodexFileChange: [String: Any] = [
            "method": "item/started",
            "params": ["item": ["type": "fileChange", "id": "file-empty", "changes": []]]
        ]
        if case .toolRequested(let request)? = CodexExecHarness.appServerEvent(from: emptyCodexFileChange, workspace: codexWorkspace) {
            expect(!request.workspaceScoped, "Codex empty file-change metadata fails closed")
        } else { expect(false, "Codex empty file-change event is projected") }
        let outsideScopeParent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outsideScopeDirectory = outsideScopeParent.appendingPathComponent("outside", isDirectory: true)
        try! FileManager.default.createDirectory(at: outsideScopeDirectory, withIntermediateDirectories: true)
        let outsideScopeSibling = outsideScopeParent.appendingPathComponent("sibling.txt")
        try! Data("outside".utf8).write(to: outsideScopeSibling)
        let outsideScopeLink = codexWorkspace.appendingPathComponent("escape")
        try! FileManager.default.createSymbolicLink(at: outsideScopeLink, withDestinationURL: outsideScopeDirectory)
        expect(!WorkspacePathScope.isScoped("escape/new.txt", under: codexWorkspace), "Workspace scope resolves outside symlink before nonexistent child")
        expect(!WorkspacePathScope.isScoped("escape/../sibling.txt", under: codexWorkspace), "Workspace scope resolves symlink before dot-dot traversal")
        try? FileManager.default.removeItem(at: outsideScopeParent)
        let codexDeltaObject: [String: Any] = ["method": "item/agentMessage/delta", "params": ["delta": "Hello"]]
        if case .assistantDelta(let delta)? = CodexExecHarness.appServerEvent(from: codexDeltaObject, workspace: codexWorkspace) {
            expect(delta == "Hello", "Codex app-server text delta")
        } else { expect(false, "Codex app-server text delta") }
        let codexCommandStart: [String: Any] = ["method": "item/started", "params": ["item": ["type": "commandExecution", "id": "command-1", "command": "swift build", "cwd": codexWorkspace.path, "status": "inProgress"]]]
        let codexCommandEnd: [String: Any] = ["method": "item/completed", "params": ["item": ["type": "commandExecution", "id": "command-1", "command": "swift build", "cwd": codexWorkspace.path, "status": "completed"]]]
        var codexCommandID: UUID?
        if case .toolRequested(let request)? = CodexExecHarness.appServerEvent(from: codexCommandStart, workspace: codexWorkspace) {
            codexCommandID = request.id
            expect(request.detail == "$ swift build" && request.workspaceScoped, "Codex command activity starts with scoped detail")
        } else { expect(false, "Codex command activity starts") }
        if case .toolProgress(let id, let fraction, let detail)? = CodexExecHarness.appServerEvent(from: codexCommandEnd, workspace: codexWorkspace) {
            expect(id == codexCommandID && fraction == 1 && detail == "Completed", "Codex command activity correlates completion")
        } else { expect(false, "Codex command activity completes") }
        let codexReasoningSummary: [String: Any] = ["method": "item/reasoning/summaryTextDelta", "params": ["itemId": "reasoning-1", "delta": "Inspecting the affected view."]]
        if case .reasoningSummary(_, let delta)? = CodexExecHarness.appServerEvent(from: codexReasoningSummary, workspace: codexWorkspace) {
            expect(delta == "Inspecting the affected view.", "Codex visible reasoning summary is projected")
        } else { expect(false, "Codex visible reasoning summary is projected") }
        let codexPrivateReasoning: [String: Any] = ["method": "item/reasoning/textDelta", "params": ["itemId": "reasoning-1", "delta": "private chain of thought"]]
        expect(CodexExecHarness.appServerEvent(from: codexPrivateReasoning, workspace: codexWorkspace) == nil, "Codex private reasoning text is not projected")
        let codexPlanUpdate: [String: Any] = [
            "method": "turn/plan/updated",
            "params": [
                "turnId": "turn-1",
                "explanation": "Update the chat surface",
                "plan": [["step": "Inspect", "status": "completed"], ["step": "Verify", "status": "inProgress"]]
            ]
        ]
        if case .plan(_, let title, let explanation, let steps)? = CodexExecHarness.appServerEvent(from: codexPlanUpdate, workspace: codexWorkspace) {
            expect(
                title == "Plan"
                    && explanation == "Update the chat surface"
                    && steps.map(\.title) == ["Inspect", "Verify"]
                    && steps.map(\.status) == [.completed, .inProgress],
                "Codex plan updates preserve typed step status"
            )
        } else { expect(false, "Codex plan updates are projected") }

        // Durable assistant image artifacts (metadata only; no base64 in transcript or records).
        let oneByOnePNG = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
            0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        let artifactRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let artifactWorkspace = artifactRoot.appendingPathComponent("workspace", isDirectory: true)
        let artifactAppSupport = artifactRoot.appendingPathComponent("Application Support/Lattice", isDirectory: true)
        try! FileManager.default.createDirectory(at: artifactWorkspace, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: artifactAppSupport, withIntermediateDirectories: true)
        let workspacePNG = artifactWorkspace.appendingPathComponent("view.png")
        let generatedPNG = artifactAppSupport.appendingPathComponent("gen.png")
        try! oneByOnePNG.write(to: workspacePNG)
        try! oneByOnePNG.write(to: generatedPNG)
        if case .accepted(let image) = AssistantImageArtifactPolicy.validate(path: workspacePNG.path, workspace: artifactWorkspace, applicationSupportRoot: artifactAppSupport) {
            expect(image.status == .available && image.mimeType == "image/png" && image.pixelWidth == 1, "Workspace PNG validates by signature")
        } else { expect(false, "Workspace PNG validates by signature") }
        if case .rejected = AssistantImageArtifactPolicy.validate(path: "https://example.com/x.png", workspace: artifactWorkspace, applicationSupportRoot: artifactAppSupport) {
            expect(true, "URL schemes are rejected for image artifacts")
        } else { expect(false, "URL schemes are rejected for image artifacts") }
        if case .rejected = AssistantImageArtifactPolicy.validate(path: "data:image/png;base64,AAAA", workspace: artifactWorkspace, applicationSupportRoot: artifactAppSupport) {
            expect(true, "data: payloads are rejected for image artifacts")
        } else { expect(false, "data: payloads are rejected for image artifacts") }
        let missingPNG = artifactWorkspace.appendingPathComponent("later.png")
        if case .accepted(let missing) = AssistantImageArtifactPolicy.validate(path: missingPNG.path, workspace: artifactWorkspace, applicationSupportRoot: artifactAppSupport) {
            expect(missing.status == .missing, "Authorized missing image paths become .missing")
        } else { expect(false, "Authorized missing image paths become .missing") }
        try! oneByOnePNG.write(to: missingPNG)
        if case .accepted(let recovered) = AssistantImageArtifactPolicy.validate(path: missingPNG.path, workspace: artifactWorkspace, applicationSupportRoot: artifactAppSupport) {
            expect(recovered.status == .available, "Missing image paths revalidate when the file appears")
        } else { expect(false, "Missing image paths revalidate when the file appears") }
        let inlineImagePart1 = AssistantTranscriptMediaPolicy.appending("image: data:image/png;base", to: "", isSuppressingPayload: false)
        let inlineImagePart2 = AssistantTranscriptMediaPolicy.appending("64,iVBORw0KGgo", to: inlineImagePart1.text, isSuppressingPayload: inlineImagePart1.isSuppressingPayload)
        let inlineImagePart3 = AssistantTranscriptMediaPolicy.appending("==. retained", to: inlineImagePart2.text, isSuppressingPayload: inlineImagePart2.isSuppressingPayload)
        expect(
            inlineImagePart3.text == "image: [Inline image data omitted]. retained"
                && !inlineImagePart3.text.contains("iVBOR")
                && !inlineImagePart3.isSuppressingPayload,
            "Streaming inline image base64 never enters transcript prose"
        )
        let codexImageView: [String: Any] = [
            "method": "item/completed",
            "params": ["item": ["type": "imageView", "id": "view-1", "path": workspacePNG.path]]
        ]
        if case .artifact(let observation)? = CodexExecHarness.appServerEvent(from: codexImageView, workspace: artifactWorkspace, applicationSupportRoot: artifactAppSupport) {
            expect(observation.provenance.origin == .codexImageView && observation.mimeType == "image/png", "Codex imageView decodes a validated artifact")
        } else { expect(false, "Codex imageView decodes a validated artifact") }
        let codexImageGeneration: [String: Any] = [
            "method": "item/completed",
            "params": ["item": [
                "type": "imageGeneration",
                "id": "gen-1",
                "status": "completed",
                "result": "IGNORED_BASE64_OR_BLOB",
                "savedPath": generatedPNG.path
            ]]
        ]
        let generationEvent = CodexExecHarness.appServerEvent(from: codexImageGeneration, workspace: artifactWorkspace, applicationSupportRoot: artifactAppSupport)
        if case .artifact(let generated)? = generationEvent {
            expect(
                generated.provenance.origin == .codexImageGeneration
                    && generated.canonicalPath.hasSuffix("/gen.png")
                    && generated.status == .available,
                "Codex imageGeneration uses savedPath only"
            )
        } else if case .providerDiagnostic(let diagnostic)? = generationEvent {
            expect(false, "Codex imageGeneration uses savedPath only (diagnostic: \(diagnostic.reason))")
        } else {
            expect(false, "Codex imageGeneration uses savedPath only (unexpected: \(String(describing: generationEvent)))")
        }
        let unsafeImageView: [String: Any] = [
            "method": "item/completed",
            "params": ["item": ["type": "imageView", "id": "bad", "path": "https://cdn.example/x.png"]]
        ]
        if case .providerDiagnostic(let diagnostic)? = CodexExecHarness.appServerEvent(from: unsafeImageView, workspace: artifactWorkspace, applicationSupportRoot: artifactAppSupport) {
            expect(!diagnostic.detail.contains("cdn.example") && diagnostic.reason.contains("rejected"), "Unsafe Codex image paths become metadata-only diagnostics")
        } else { expect(false, "Unsafe Codex image paths become metadata-only diagnostics") }
        expect(StructuredAssistantArtifactDecoder.explicitImagePath(in: ["nested": ["imagePath": workspacePNG.path]]) == nil, "Shared decoder does not recurse nested path discovery")
        let toolResultEnvelope: [String: Any] = [
            "type": "tool_result",
            "tool_id": "tool-artifact-1",
            "status": "success",
            "imagePath": workspacePNG.path
        ]
        let antigravityArtifactEvents = AntigravityCLIHarness.structuredEvent(
            from: try! JSONSerialization.data(withJSONObject: toolResultEnvelope),
            workspace: artifactWorkspace,
            applicationSupportRoot: artifactAppSupport
        )
        expect(antigravityArtifactEvents.contains {
            if case .artifact(let artifact) = $0 { return artifact.provenance.origin == .structuredToolResult }
            return false
        }, "Antigravity tool_result emits artifact only for explicit imagePath")
        let assistantForArtifact = ChatMessage(role: .assistant, text: "diagram ready")
        let durableArtifact = AssistantArtifact(
            messageID: assistantForArtifact.id,
            status: .available,
            displayName: "view.png",
            mimeType: "image/png",
            byteCount: oneByOnePNG.count,
            pixelWidth: 1,
            pixelHeight: 1,
            canonicalPath: workspacePNG.path,
            provenance: .init(provider: "Codex", origin: .codexImageView, eventID: "view-1")
        )
        let artifactSession = LatticeSession(
            title: "Artifacts",
            messages: [.init(role: .user, text: "draw"), assistantForArtifact],
            artifacts: [durableArtifact],
            backend: .codex(model: "gpt-5.4")
        )
        let artifactStore = SessionPersistence(fileURL: artifactRoot.appendingPathComponent("sessions.json"))
        try! artifactStore.save([artifactSession])
        if case .loaded(let lazyArtifactLoad) = artifactStore.loadLazyResult(), var lazyArtifactSession = lazyArtifactLoad.sessions.first {
            expect(lazyArtifactSession.messages.isEmpty && lazyArtifactSession.artifacts.isEmpty, "Artifact split store leaves metadata off the manifest payload")
            expect(lazyArtifactSession.artifactStorage?.artifactCount == 1, "Artifact storage reference is retained on the session manifest")
            try! artifactStore.materializeSessionContent(in: &lazyArtifactSession)
            expect(lazyArtifactSession.artifacts.count == 1 && lazyArtifactSession.artifacts[0].canonicalPath == workspacePNG.path, "Artifact metadata hydrates from the split store")
            let transcriptBytes = try! Data(contentsOf: artifactStore.transcriptDirectoryURL.appendingPathComponent(lazyArtifactSession.transcriptStorage!.fileName))
            expect(!String(decoding: transcriptBytes, as: UTF8.self).contains("view.png"), "Transcript sidecar does not carry artifact path metadata")
            let artifactBytes = try! Data(contentsOf: artifactStore.artifactDirectoryURL.appendingPathComponent(lazyArtifactSession.artifactStorage!.fileName))
            expect(!artifactBytes.contains(oneByOnePNG) && !String(decoding: artifactBytes, as: UTF8.self).contains(oneByOnePNG.base64EncodedString()), "Artifact sidecar never stores image bytes or base64")
        } else { expect(false, "Artifact split store loads") }
        let textOnlyArtifactStore = SessionPersistence(fileURL: artifactRoot.appendingPathComponent("text-only-sessions.json"))
        try! textOnlyArtifactStore.save([LatticeSession(title: "Text only", messages: [.init(role: .assistant, text: "done")], backend: .codex(model: "gpt-5.4"))])
        if case .loaded(let textOnlyLazy) = textOnlyArtifactStore.loadLazyResult() {
            expect(textOnlyLazy.sessions.first?.artifactStorage == nil, "Text-only chats do not create empty artifact sidecars")
        } else { expect(false, "Text-only chats do not create empty artifact sidecars") }
        let artifactSecondAssistant = ChatMessage(role: .assistant, text: "second")
        let secondArtifact = AssistantArtifact(
            messageID: artifactSecondAssistant.id,
            status: .available,
            displayName: "gone.png",
            mimeType: "image/png",
            byteCount: 10,
            canonicalPath: "/tmp/gone.png",
            provenance: .init(provider: "Codex", origin: .codexImageGeneration)
        )
        var pruneSession = LatticeSession(
            title: "Prune",
            messages: [.init(role: .user, text: "a"), assistantForArtifact, .init(role: .user, text: "b"), artifactSecondAssistant],
            artifacts: [durableArtifact, secondArtifact],
            backend: .codex(model: "gpt-5.4")
        )
        expect(SessionTranscriptMutation.deleteMessageAndFollowing(messageID: pruneSession.messages[2].id, in: &pruneSession), "Delete truncates transcript for artifact ownership test")
        expect(pruneSession.artifacts.map { $0.id } == [durableArtifact.id], "Delete prunes artifacts for removed messages")
        let artifactBranch = SessionTranscriptMutation.branchFromMessage(messageID: pruneSession.messages[0].id, in: pruneSession)
        expect(artifactBranch?.artifacts.isEmpty == true, "Branch prunes artifacts not owned by retained messages")
        var legacyArtifactObject = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(LatticeSession(title: "LegacyArtifacts", backend: .codex(model: "gpt-5.4")))) as! [String: Any]
        legacyArtifactObject["artifacts"] = nil
        legacyArtifactObject["artifactStorage"] = nil
        if let legacyDecoded = try? JSONDecoder().decode(LatticeSession.self, from: JSONSerialization.data(withJSONObject: legacyArtifactObject)) {
            expect(legacyDecoded.artifacts.isEmpty && legacyDecoded.isArtifactsLoaded && legacyDecoded.artifactStorage == nil, "Legacy sessions without artifacts decode as empty loaded metadata")
        } else { expect(false, "Legacy sessions without artifacts decode as empty loaded metadata") }
        try? FileManager.default.removeItem(at: artifactRoot)

        let reasoningAction = SessionAction(messageID: responseMessage.id, kind: .reasoning, title: "Reasoning summary", detail: "Inspect", status: .running)
        var reasoningActions = [reasoningAction]
        expect(SessionActionTrail.appendDetail(id: reasoningAction.id, delta: " then verify", in: &reasoningActions) && reasoningActions[0].detail == "Inspect then verify", "Reasoning summary deltas append to durable activity")

        let codexDecisionURL = codexWorkspace.appendingPathComponent("approval-response.json")
        let codexThreadRequestURL = codexWorkspace.appendingPathComponent("thread-request.json")
        let codexTurnRequestURL = codexWorkspace.appendingPathComponent("turn-request.json")
        let fakeCodexURL = codexWorkspace.appendingPathComponent("codex")
        let fakeCodexScript = """
        #!/bin/zsh
        IFS= read -r initialize
        print -r -- '{"id":1,"result":{"userAgent":"fake-codex"}}'
        IFS= read -r initialized
        IFS= read -r thread_request
        print -r -- "$thread_request" > "\(codexThreadRequestURL.path)"
        print -r -- '{"id":2,"result":{"thread":{"id":"thread-native","turns":[]},"approvalPolicy":"on-request","sandbox":"workspace-write"}}'
        IFS= read -r turn_request
        print -r -- "$turn_request" > "\(codexTurnRequestURL.path)"
        print -r -- '{"id":3,"result":{"turn":{"id":"turn-native","status":"inProgress","items":[]}}}'
        print -r -- '{"method":"item/agentMessage/delta","params":{"threadId":"thread-native","turnId":"turn-native","itemId":"message-1","delta":"Native reply"}}'
        print -r -- '{"method":"item/started","params":{"threadId":"thread-native","turnId":"turn-native","item":{"type":"commandExecution","id":"command-native","command":"swift build","cwd":"\(codexWorkspace.path)","processId":null,"source":"agent","status":"inProgress","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null}}}'
        print -r -- '{"method":"item/commandExecution/requestApproval","id":77,"params":{"threadId":"thread-native","turnId":"turn-native","itemId":"command-native","startedAtMs":1,"command":"swift build","cwd":"\(codexWorkspace.path)","availableDecisions":["accept","decline","cancel"]}}'
        IFS= read -r approval
        print -r -- "$approval" > "\(codexDecisionURL.path)"
        print -r -- '{"method":"item/completed","params":{"threadId":"thread-native","turnId":"turn-native","item":{"type":"commandExecution","id":"command-native","command":"swift build","cwd":"\(codexWorkspace.path)","processId":null,"source":"agent","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":2}}}'
        print -r -- '{"method":"turn/completed","params":{"threadId":"thread-native","turn":{"id":"turn-native","status":"completed","items":[],"error":null}}}'
        """
        try! Data(fakeCodexScript.utf8).write(to: fakeCodexURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodexURL.path)
        let fakeCodex = CodexExecHarness(executableURL: fakeCodexURL)
        let fakeCodexSessionID = UUID()
        var sawNativeThread = false
        var sawNativeDelta = false
        var sawNativePermission = false
        var sawNativeToolStart = false
        var sawNativeToolEnd = false
        var sawNativeCompletion = false
        var nativeToolID: UUID?
        for await event in fakeCodex.stream(prompt: "Reply and build", sessionID: fakeCodexSessionID, threadID: nil, workspace: codexWorkspace, model: "gpt-test", reasoningEffort: .high, policy: .smart) {
            if case .harnessSessionStarted(let id) = event { sawNativeThread = id == "thread-native" }
            if case .assistantDelta(let delta) = event { sawNativeDelta = delta == "Native reply" }
            if case .toolRequested(let request) = event { nativeToolID = request.id; sawNativeToolStart = request.detail == "$ swift build" }
            if case .toolProgress(let id, let fraction, _) = event { sawNativeToolEnd = id == nativeToolID && fraction == 1 }
            if case .permissionRequested(let request) = event {
                sawNativePermission = true
                expect(!fakeCodex.respondToPermission(sessionID: UUID(), requestID: request.id, optionID: "accept"), "Codex rejects cross-session permission response")
                expect(!fakeCodex.respondToPermission(sessionID: fakeCodexSessionID, requestID: request.id, optionID: "unknown"), "Codex rejects unknown permission option")
                expect(fakeCodex.respondToPermission(sessionID: fakeCodexSessionID, requestID: request.id, optionID: "accept"), "Codex accepts active permission option")
            }
            if case .completed = event { sawNativeCompletion = true }
        }
        expect(sawNativeThread && sawNativeDelta, "Codex app-server thread and streaming lifecycle")
        expect(sawNativePermission, "Codex app-server approval forwarded")
        expect(sawNativeToolStart && sawNativeToolEnd, "Codex app-server tool activity forwarded")
        expect(sawNativeCompletion, "Codex app-server turn completion forwarded")
        let codexPermissionResponse = try! String(contentsOf: codexDecisionURL, encoding: .utf8)
        expect(codexPermissionResponse.contains("\"decision\":\"accept\""), "Codex app-server approval response written")
        let codexThreadRequest = try! JSONSerialization.jsonObject(with: Data(contentsOf: codexThreadRequestURL)) as! [String: Any]
        let codexThreadParams = codexThreadRequest["params"] as! [String: Any]
        expect(codexThreadRequest["method"] as? String == "thread/start" && codexThreadParams["sandbox"] as? String == "workspace-write", "Codex starts a native writable thread for Smart mode")
        let codexTurnRequest = try! JSONSerialization.jsonObject(with: Data(contentsOf: codexTurnRequestURL)) as! [String: Any]
        let codexTurnParams = codexTurnRequest["params"] as! [String: Any]
        expect(codexTurnRequest["method"] as? String == "turn/start" && codexTurnParams["effort"] as? String == "high" && codexTurnParams["summary"] as? String == "auto", "Codex starts the turn with model reasoning and visible summary settings")
        let permissionObject: [String: Any] = [
            "method": "session/request_permission",
            "params": [
                "toolCall": [
                    "title": "Run formatter",
                    "kind": "execute",
                    "rawInput": ["command": "swiftformat .", "description": "Format workspace"]
                ],
                "options": [
                    ["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"],
                    ["optionId": "deny", "name": "Deny", "kind": "reject_once"]
                ]
            ]
        ]
        let parsedPermission = HermesACPHarness.permissionRequest(from: permissionObject, workspace: codexWorkspace)
        expect(parsedPermission?.title == "Run formatter", "Hermes permission title parsed")
        expect(parsedPermission?.detail.contains("swiftformat .") == true, "Hermes permission command parsed")
        expect(parsedPermission?.options.map(\.id) == ["allow_once", "deny"], "Hermes permission options parsed")
        expect(parsedPermission?.toolRequest?.kind == .command, "Hermes permission command is typed")
        expect(parsedPermission?.toolRequest?.workspaceScoped == false, "Hermes permission without a path is not assumed workspace-scoped")
        let hermesPathPermissionObject: [String: Any] = [
            "method": "session/request_permission",
            "params": [
                "toolCall": [
                    "title": "Edit app",
                    "kind": "edit",
                    "rawInput": ["path": "Sources/App.swift"]
                ],
                "options": [
                    ["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"],
                    ["optionId": "deny", "name": "Deny", "kind": "reject_once"]
                ]
            ]
        ]
        expect(HermesACPHarness.permissionRequest(from: hermesPathPermissionObject, workspace: codexWorkspace)?.toolRequest?.kind == .write, "Hermes edit permission is typed")
        expect(HermesACPHarness.permissionRequest(from: hermesPathPermissionObject, workspace: codexWorkspace)?.toolRequest?.workspaceScoped == true, "Hermes relative edit path is workspace-scoped")
        try? FileManager.default.removeItem(at: codexWorkspace)
        let hermesToolStart: [String: Any] = [
            "method": "session/update",
            "params": ["update": [
                "sessionUpdate": "tool_call", "toolCallId": "call-1", "title": "edit Sources/App.swift", "kind": "edit",
                "locations": [["path": "Sources/App.swift"]], "rawInput": ["path": "Sources/App.swift"]
            ]]
        ]
        let hermesToolEnd: [String: Any] = [
            "method": "session/update",
            "params": ["update": ["sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": "completed"]]
        ]
        var hermesToolID: UUID?
        if case .toolRequested(let request)? = HarnessToolEventDecoder.hermesEvent(from: hermesToolStart, workspace: root) {
            hermesToolID = request.id
            expect(request.kind == .write && request.detail == "Sources/App.swift", "Hermes tool path projected")
        } else { expect(false, "Hermes tool start projected") }
        if case .toolProgress(let id, let fraction, let detail)? = HarnessToolEventDecoder.hermesEvent(from: hermesToolEnd, workspace: root) {
            expect(id == hermesToolID && fraction == 1 && detail == "Completed", "Hermes tool completion correlated")
        } else { expect(false, "Hermes tool completion projected") }
        let permissionOptions = [
            ApprovalOption(id: "allow_once", name: "Allow once", kind: "allow_once"),
            ApprovalOption(id: "allow_session", name: "Allow for session", kind: "allow_session"),
            ApprovalOption(id: "allow_always", name: "Allow always", kind: "allow_always"),
            ApprovalOption(id: "deny", name: "Deny", kind: "reject_once"),
            ApprovalOption(id: "deny_always", name: "Deny always", kind: "reject_always")
        ]
        expect(ApprovalOptionPolicy.visibleOptions(permissionOptions, under: .ask).map(\.id) == ["allow_once", "deny"], "Ask exposes one-turn ACP decisions")
        expect(ApprovalOptionPolicy.visibleOptions(permissionOptions, under: .smart).map(\.id) == ["allow_once", "allow_session", "deny"], "Smart exposes session-scoped ACP approval")
        expect(ApprovalOptionPolicy.visibleOptions(permissionOptions, under: .yolo).map(\.id) == ["allow_once", "allow_session", "allow_always", "deny"], "YOLO policy excludes persistent rejection")
        expect(!ApprovalOptionPolicy.isVisible(permissionOptions[2], under: .ask), "Ask rejects hidden permanent allow decisions")
        expect(!ApprovalOptionPolicy.isVisible(permissionOptions[2], under: .smart), "Smart rejects hidden permanent allow decisions")
        expect(ApprovalOptionPolicy.isVisible(permissionOptions[2], under: .yolo), "YOLO can expose permanent allow decisions")
        expect(!ApprovalOptionPolicy.isVisible(permissionOptions[4], under: .yolo), "YOLO still rejects permanent deny decisions")
        let providerNativeOptions = [
            ApprovalOption(id: "accept", name: "Allow once", kind: "allow_once"),
            ApprovalOption(id: "acceptForSession", name: "Allow for session", kind: "allow_session"),
            ApprovalOption(id: "acceptAlways", name: "Allow always", kind: "allow_always"),
            ApprovalOption(id: "decline", name: "Deny", kind: "reject_once"),
            ApprovalOption(id: "cancel", name: "Stop", kind: "reject_always")
        ]
        expect(ApprovalOptionPolicy.visibleOptions(providerNativeOptions, under: .smart).map(\.id) == ["accept", "acceptForSession", "decline"], "Smart exposes provider-native session approval by kind")

        let fakeHarnessRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: fakeHarnessRoot, withIntermediateDirectories: true)
        let fakeHarnessURL = fakeHarnessRoot.appendingPathComponent("fake-hermes")
        let decisionURL = fakeHarnessRoot.appendingPathComponent("permission-response.json")
        let acpSessionRequestURL = fakeHarnessRoot.appendingPathComponent("session-request.json")
        let hermesInsideURL = fakeHarnessRoot.appendingPathComponent("sandbox-inside.txt")
        let hermesOutsideRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: hermesOutsideRoot, withIntermediateDirectories: true)
        let hermesOutsideURL = hermesOutsideRoot.appendingPathComponent("sandbox-outside.txt")
        let fakeHarnessScript = """
        #!/bin/zsh
        print -r -- inside > '\(hermesInsideURL.path)'
        print -r -- outside > '\(hermesOutsideURL.path)' 2>/dev/null || true
        IFS= read -r initialize
        print -r -- '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        IFS= read -r session
        print -r -- "$session" > '\(acpSessionRequestURL.path)'
        print -r -- '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"fake-session","models":{"currentModelId":"model-1","availableModels":[{"modelId":"model-1","name":"Model One"}]}}}'
        IFS= read -r prompt
        print -r -- '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fake-session","update":{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"Run formatter","kind":"execute","rawInput":{"command":"swiftformat ."}}}}'
        print -r -- '{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"fake-session","toolCall":{"toolCallId":"call-1","title":"Run formatter","kind":"execute","rawInput":{"command":"swiftformat .","description":"Format workspace"}},"options":[{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}'
        while IFS= read -r permission; do
          [[ "$permission" == *'"id":99'* ]] && break
        done
        print -r -- "$permission" > '\(decisionURL.path)'
        print -r -- '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fake-session","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed"}}}'
        print -r -- '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        """
        try! Data(fakeHarnessScript.utf8).write(to: fakeHarnessURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHarnessURL.path)
        let fakeHarness = HermesACPHarness(executableURL: fakeHarnessURL)
        let fakeSessionID = UUID()
        var sawPermission = false
        var sawCompletion = false
        var sawHermesToolStart = false
        var sawHermesToolEnd = false
        for await event in fakeHarness.stream(prompt: "Format", sessionID: fakeSessionID, threadID: nil, workspace: fakeHarnessRoot, requestedModel: "Model One") {
            if case .toolRequested(let request) = event { sawHermesToolStart = request.detail.contains("swiftformat .") }
            if case .toolProgress(_, let fraction, _) = event { sawHermesToolEnd = fraction == 1 }
            if case .permissionRequested(let request) = event {
                sawPermission = true
                expect(!fakeHarness.respondToPermission(sessionID: UUID(), requestID: request.id, optionID: "allow_once"), "Hermes rejects cross-session permission response")
                expect(!fakeHarness.respondToPermission(sessionID: fakeSessionID, requestID: request.id, optionID: "unknown"), "Hermes rejects unknown permission option")
                expect(fakeHarness.respondToPermission(sessionID: fakeSessionID, requestID: request.id, optionID: "allow_once"), "Hermes accepts active permission option")
            }
            if case .completed = event { sawCompletion = true }
        }
        expect(sawPermission, "Hermes permission event forwarded")
        expect(sawCompletion, "Hermes continues after permission response")
        expect(sawHermesToolStart && sawHermesToolEnd, "Hermes tool activity forwarded")
        let permissionResponse = try! String(contentsOf: decisionURL, encoding: .utf8)
        expect(permissionResponse.contains("\"outcome\":\"selected\"") && permissionResponse.contains("\"optionId\":\"allow_once\""), "Hermes selected permission response written")
        let acpSessionRequest = try! String(contentsOf: acpSessionRequestURL, encoding: .utf8)
        expect(acpSessionRequest.contains("\"method\":\"session/new\"") && !acpSessionRequest.contains("session\\/new"), "ACP transport preserves protocol method names without escaped slashes")
        expect(FileManager.default.fileExists(atPath: hermesInsideURL.path), "Sandboxed Hermes process can write workspace")
        expect(!FileManager.default.fileExists(atPath: hermesOutsideURL.path), "Sandboxed Hermes process cannot write outside workspace")
        let fakeGrokACP = HermesACPHarness(profile: .grok, executableURL: fakeHarnessURL)
        let fakeGrokSessionID = UUID()
        var fakeGrokThreadID: String?
        var sawGrokPermission = false
        var sawGrokCompletion = false
        for await event in fakeGrokACP.stream(prompt: "Format", sessionID: fakeGrokSessionID, threadID: nil, workspace: fakeHarnessRoot, requestedModel: "Model One") {
            if case .harnessSessionStarted(let id) = event { fakeGrokThreadID = id }
            if case .permissionRequested(let request) = event {
                sawGrokPermission = fakeGrokACP.respondToPermission(sessionID: fakeGrokSessionID, requestID: request.id, optionID: "allow_once")
            }
            if case .completed = event { sawGrokCompletion = true }
        }
        expect(fakeGrokThreadID == "grok-acp:fake-session", "Grok ACP session identity is durable and provider-scoped")
        expect(sawGrokPermission && sawGrokCompletion, "Grok ACP permission and completion lifecycle")
        let acpCatalog = [HarnessModel(id: "provider/model-one", name: "Model One"), HarnessModel(id: "provider/model-two", name: "Model Two")]
        expect(ACPHarness.bestMatch(for: "provider/model-one", in: acpCatalog)?.id == "provider/model-one", "ACP exact model match qualifies runnable model")
        expect(ACPHarness.bestMatch(for: "provider/missing", in: acpCatalog) == nil, "ACP missing model does not qualify as runnable")
        let fakeOpenCodeURL = fakeHarnessRoot.appendingPathComponent("fake-opencode")
        let openCodeConfigRequestURL = fakeHarnessRoot.appendingPathComponent("opencode-config-request.json")
        let openCodeDecisionURL = fakeHarnessRoot.appendingPathComponent("opencode-permission-response.json")
        let fakeOpenCodeScript = """
        #!/bin/zsh
        IFS= read -r initialize
        print -r -- '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        IFS= read -r session
        print -r -- '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"open-session","configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"opencode/other","options":[{"value":"opencode/other","name":"Other"},{"value":"opencode/model-one","name":"Model One"}]}]}}'
        IFS= read -r config
        print -r -- "$config" > '\(openCodeConfigRequestURL.path)'
        print -r -- '{"jsonrpc":"2.0","id":3,"result":{"configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"opencode/model-one","options":[{"value":"opencode/other","name":"Other"},{"value":"opencode/model-one","name":"Model One"}]}]}}'
        IFS= read -r prompt
        print -r -- '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"open-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"OpenCode ACP"}}}}'
        print -r -- '{"jsonrpc":"2.0","id":199,"method":"session/request_permission","params":{"sessionId":"open-session","toolCall":{"toolCallId":"open-call","title":"Run check","kind":"execute","rawInput":{"command":"swift test"}},"options":[{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}'
        while IFS= read -r permission; do
          [[ "$permission" == *'"id":199'* ]] && break
        done
        print -r -- "$permission" > '\(openCodeDecisionURL.path)'
        print -r -- '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
        """
        try! Data(fakeOpenCodeScript.utf8).write(to: fakeOpenCodeURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenCodeURL.path)
        let fakeOpenCodeACP = ACPHarness(profile: .openCode, executableURL: fakeOpenCodeURL)
        let fakeOpenCodeSessionID = UUID()
        var fakeOpenCodeThreadID: String?
        var sawOpenCodeText = false
        var sawOpenCodePermission = false
        var sawOpenCodeCompletion = false
        for await event in fakeOpenCodeACP.stream(prompt: "Check", sessionID: fakeOpenCodeSessionID, threadID: nil, workspace: fakeHarnessRoot, requestedModel: "opencode/model-one") {
            if case .harnessSessionStarted(let id) = event { fakeOpenCodeThreadID = id }
            if case .assistantDelta(let text) = event { sawOpenCodeText = text == "OpenCode ACP" }
            if case .permissionRequested(let request) = event {
                sawOpenCodePermission = fakeOpenCodeACP.respondToPermission(sessionID: fakeOpenCodeSessionID, requestID: request.id, optionID: "allow_once")
            }
            if case .completed = event { sawOpenCodeCompletion = true }
        }
        expect(fakeOpenCodeThreadID == "opencode-acp:open-session", "OpenCode ACP session identity is durable and provider-scoped")
        expect(sawOpenCodeText && sawOpenCodePermission && sawOpenCodeCompletion, "OpenCode ACP streaming, permission, and completion lifecycle")
        let openCodeConfigRequest = try! String(contentsOf: openCodeConfigRequestURL, encoding: .utf8)
        expect(openCodeConfigRequest.contains("\"method\":\"session/set_config_option\"") && openCodeConfigRequest.contains("\"value\":\"opencode/model-one\""), "OpenCode ACP selects models through session configuration")
        let openCodePermissionResponse = try! String(contentsOf: openCodeDecisionURL, encoding: .utf8)
        expect(openCodePermissionResponse.contains("\"optionId\":\"allow_once\""), "OpenCode ACP permission response written")
        let unavailableHermes = HermesACPHarness(executableURL: fakeHarnessURL, sandboxExecutableURL: nil)
        var unavailableHermesFailure = ""
        for await event in unavailableHermes.stream(prompt: "Format", sessionID: UUID(), threadID: nil, workspace: fakeHarnessRoot, requestedModel: "Model One") {
            if case .failed(let message) = event { unavailableHermesFailure = message }
        }
        expect(unavailableHermesFailure.contains("workspace sandbox is unavailable"), "Hermes refuses launch without sandbox")
        try? FileManager.default.removeItem(at: fakeHarnessRoot)
        try? FileManager.default.removeItem(at: hermesOutsideRoot)

        let fakeCancelRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: fakeCancelRoot, withIntermediateDirectories: true)
        let fakeCancelURL = fakeCancelRoot.appendingPathComponent("fake-hermes")
        let cancelledDecisionURL = fakeCancelRoot.appendingPathComponent("permission-response.json")
        let fakeCancelScript = fakeHarnessScript.replacingOccurrences(of: decisionURL.path, with: cancelledDecisionURL.path)
        try! Data(fakeCancelScript.utf8).write(to: fakeCancelURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCancelURL.path)
        let cancellingHarness = HermesACPHarness(executableURL: fakeCancelURL)
        let cancellingSessionID = UUID()
        var sawCancellation = false
        for await event in cancellingHarness.stream(prompt: "Format", sessionID: cancellingSessionID, threadID: nil, workspace: fakeCancelRoot, requestedModel: "Model One") {
            if case .permissionRequested = event { cancellingHarness.cancel(sessionID: cancellingSessionID) }
            if case .cancelled = event { sawCancellation = true }
        }
        expect(sawCancellation, "Hermes cancellation remains cancelled after prompt response")
        let cancelledPermissionResponse = try! String(contentsOf: cancelledDecisionURL, encoding: .utf8)
        expect(cancelledPermissionResponse.contains("\"outcome\":\"cancelled\""), "Hermes pending permission cancelled before turn stop")
        try? FileManager.default.removeItem(at: fakeCancelRoot)

        let sandboxRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sandboxWorkspace = sandboxRoot.appendingPathComponent("workspace", isDirectory: true)
        let sandboxState = sandboxRoot.appendingPathComponent("state", isDirectory: true)
        let sandboxOutside = sandboxRoot.appendingPathComponent("outside", isDirectory: true)
        try! FileManager.default.createDirectory(at: sandboxWorkspace, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: sandboxState, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: sandboxOutside, withIntermediateDirectories: true)
        let canonicalSandboxWorkspace = try! HarnessSandbox.canonicalDirectory(sandboxWorkspace)
        let canonicalSandboxState = try! HarnessSandbox.canonicalDirectory(sandboxState)
        let canonicalSandboxOutside = try! HarnessSandbox.canonicalDirectory(sandboxOutside)
        try! FileManager.default.createSymbolicLink(at: canonicalSandboxWorkspace.appendingPathComponent("escape"), withDestinationURL: canonicalSandboxOutside)
        let insideFile = canonicalSandboxWorkspace.appendingPathComponent("inside.txt")
        let stateFile = canonicalSandboxState.appendingPathComponent("session.txt")
        let outsideFile = canonicalSandboxOutside.appendingPathComponent("outside.txt")
        let escapedFile = canonicalSandboxOutside.appendingPathComponent("escaped.txt")
        let sandboxCommand = "printf inside > \"$0\"; printf state > \"$1\"; printf outside > \"$2\" 2>/dev/null || true; printf escaped > \"$3\" 2>/dev/null || true"
        let sandboxLaunch = try! HarnessSandbox.writeRestrictedLaunch(
            command: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", sandboxCommand, insideFile.path, stateFile.path, outsideFile.path, canonicalSandboxWorkspace.appendingPathComponent("escape/escaped.txt").path],
            writableDirectories: [canonicalSandboxWorkspace, canonicalSandboxState]
        )
        let sandboxProcess = Process()
        let sandboxError = Pipe()
        sandboxProcess.executableURL = sandboxLaunch.executableURL
        sandboxProcess.arguments = sandboxLaunch.arguments
        sandboxProcess.standardError = sandboxError
        try! sandboxProcess.run()
        sandboxProcess.waitUntilExit()
        let sandboxErrorText = String(decoding: sandboxError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expect(sandboxProcess.terminationStatus == 0, "Workspace sandbox process starts")
        expect(FileManager.default.fileExists(atPath: insideFile.path), "Workspace sandbox permits workspace write")
        expect(FileManager.default.fileExists(atPath: stateFile.path), "Workspace sandbox permits explicit state write")
        expect(!FileManager.default.fileExists(atPath: outsideFile.path), "Workspace sandbox denies outside write")
        expect(!FileManager.default.fileExists(atPath: escapedFile.path), "Workspace sandbox denies symlink escape")
        expect(sandboxErrorText.components(separatedBy: "Operation not permitted").count >= 3, "Workspace sandbox reports denied writes")
        do {
            _ = try HarnessSandbox.writeRestrictedLaunch(command: URL(fileURLWithPath: "/bin/true"), arguments: [], writableDirectories: [sandboxWorkspace], sandboxExecutableURL: nil)
            expect(false, "Missing workspace sandbox fails closed")
        } catch HarnessSandboxError.unavailable {
            expect(true, "Missing workspace sandbox fails closed")
        } catch {
            expect(false, "Missing workspace sandbox fails closed")
        }
        try? FileManager.default.removeItem(at: sandboxRoot)

        let piWorkspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: piWorkspace, withIntermediateDirectories: true)
        let piRequestObject: [String: Any] = [
            "type": "extension_ui_request",
            "id": "gate-1",
            "method": "confirm",
            "message": "{\"toolName\":\"write\",\"input\":{\"path\":\"Sources/App.swift\",\"content\":\"ok\"}}"
        ]
        let parsedPiPermission = PiRPCHarness.permissionRequest(from: piRequestObject, workspace: piWorkspace)
        expect(parsedPiPermission?.title == "Pi wants to use write", "Pi write permission title parsed")
        expect(parsedPiPermission?.detail == "Sources/App.swift", "Pi write path parsed")
        expect(parsedPiPermission?.toolRequest?.workspaceScoped == true, "Pi relative write is workspace scoped")
        let externalPiRequest: [String: Any] = [
            "type": "extension_ui_request",
            "id": "gate-2",
            "method": "confirm",
            "message": "{\"toolName\":\"edit\",\"input\":{\"path\":\"/tmp/outside.txt\"}}"
        ]
        expect(PiRPCHarness.permissionRequest(from: externalPiRequest, workspace: piWorkspace)?.toolRequest?.workspaceScoped == false, "Pi external edit crosses workspace scope")
        expect(PiRPCHarness.permissionRequest(from: ["type": "extension_ui_request", "id": "gate-3", "method": "confirm", "message": "{\"toolName\":\"read\",\"input\":{\"path\":\"file\"}}"], workspace: piWorkspace) == nil, "Pi ignores unguarded read dialogs")
        let piToolStart: [String: Any] = ["type": "tool_execution_start", "toolCallId": "pi-call-1", "toolName": "bash", "args": ["command": "swift build"]]
        let piToolEnd: [String: Any] = ["type": "tool_execution_end", "toolCallId": "pi-call-1", "toolName": "bash", "isError": false]
        var piToolID: UUID?
        if case .toolRequested(let request)? = HarnessToolEventDecoder.piEvent(from: piToolStart, workspace: piWorkspace) {
            piToolID = request.id
            expect(request.kind == .command && request.detail == "$ swift build", "Pi tool command projected")
        } else { expect(false, "Pi tool start projected") }
        if case .toolProgress(let id, let fraction, let detail)? = HarnessToolEventDecoder.piEvent(from: piToolEnd, workspace: piWorkspace) {
            expect(id == piToolID && fraction == 1 && detail == "Completed", "Pi tool completion correlated")
        } else { expect(false, "Pi tool completion projected") }
        let piExtensionURL = piWorkspace.appendingPathComponent("lattice-permission-gate.js")
        try! PiRPCHarness.installPermissionExtension(at: piExtensionURL)
        let piExtensionSource = try! String(contentsOf: piExtensionURL, encoding: .utf8)
        expect(piExtensionSource.contains("write") && piExtensionSource.contains("edit") && piExtensionSource.contains("bash"), "Pi permission extension gates mutation tools")

        let fakePiURL = piWorkspace.appendingPathComponent("fake-pi")
        let piDecisionURL = piWorkspace.appendingPathComponent("permission-response.json")
        let fakePiScript = """
        #!/bin/zsh
        IFS= read -r prompt
        print -r -- '{"type":"tool_execution_start","toolCallId":"pi-call-1","toolName":"write","args":{"path":"Sources/App.swift","content":"ok"}}'
        print -r -- '{"type":"extension_ui_request","id":"gate-1","method":"confirm","title":"Lattice permission request","message":"{\\"toolName\\":\\"write\\",\\"input\\":{\\"path\\":\\"Sources/App.swift\\",\\"content\\":\\"ok\\"}}"}'
        while IFS= read -r permission; do
          [[ "$permission" == *'"type":"extension_ui_response"'* ]] && break
        done
        print -r -- "$permission" > '\(piDecisionURL.path)'
        print -r -- '{"type":"tool_execution_end","toolCallId":"pi-call-1","toolName":"write","result":{"content":[{"type":"text","text":"ok"}]},"isError":false}'
        print -r -- '{"type":"agent_end"}'
        """
        try! Data(fakePiScript.utf8).write(to: fakePiURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePiURL.path)
        let fakePi = PiRPCHarness(executableURL: fakePiURL, permissionExtensionURL: piExtensionURL)
        let fakePiSessionID = UUID()
        var sawPiPermission = false
        var sawPiCompletion = false
        var sawPiToolStart = false
        var sawPiToolEnd = false
        for await event in fakePi.stream(prompt: "Edit", sessionID: fakePiSessionID, threadID: nil, workspace: piWorkspace, provider: "test", model: "model", reasoningEffort: nil, allowFileModification: true) {
            if case .toolRequested(let request) = event { sawPiToolStart = request.detail == "Sources/App.swift" }
            if case .toolProgress(_, let fraction, _) = event { sawPiToolEnd = fraction == 1 }
            if case .permissionRequested(let request) = event {
                sawPiPermission = true
                expect(!fakePi.respondToPermission(sessionID: UUID(), requestID: request.id, optionID: "allow_once"), "Pi rejects cross-session permission response")
                expect(!fakePi.respondToPermission(sessionID: fakePiSessionID, requestID: request.id, optionID: "unknown"), "Pi rejects unknown permission option")
                expect(fakePi.respondToPermission(sessionID: fakePiSessionID, requestID: request.id, optionID: "allow_once"), "Pi accepts active permission option")
            }
            if case .completed = event { sawPiCompletion = true }
        }
        expect(sawPiPermission, "Pi permission event forwarded")
        expect(sawPiCompletion, "Pi continues after permission response")
        expect(sawPiToolStart && sawPiToolEnd, "Pi tool activity forwarded")
        let piPermissionResponse = try! String(contentsOf: piDecisionURL, encoding: .utf8)
        expect(piPermissionResponse.contains("\"confirmed\":true"), "Pi confirmed permission response written")

        let cancellingPiDecisionURL = piWorkspace.appendingPathComponent("cancelled-permission-response.json")
        let cancellingPiURL = piWorkspace.appendingPathComponent("fake-pi-cancel")
        let cancellingPiScript = fakePiScript.replacingOccurrences(of: piDecisionURL.path, with: cancellingPiDecisionURL.path)
        try! Data(cancellingPiScript.utf8).write(to: cancellingPiURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cancellingPiURL.path)
        let cancellingPi = PiRPCHarness(executableURL: cancellingPiURL, permissionExtensionURL: piExtensionURL)
        let cancellingPiSessionID = UUID()
        var sawPiCancellation = false
        var sawPiCompletionAfterCancel = false
        for await event in cancellingPi.stream(prompt: "Edit", sessionID: cancellingPiSessionID, threadID: nil, workspace: piWorkspace, provider: "test", model: "model", reasoningEffort: nil, allowFileModification: true) {
            if case .permissionRequested = event { cancellingPi.cancel(sessionID: cancellingPiSessionID) }
            if case .cancelled = event { sawPiCancellation = true }
            if case .completed = event { sawPiCompletionAfterCancel = true }
        }
        expect(sawPiCancellation && !sawPiCompletionAfterCancel, "Pi cancellation remains cancelled after permission response")
        let cancelledPiPermissionResponse = try! String(contentsOf: cancellingPiDecisionURL, encoding: .utf8)
        expect(cancelledPiPermissionResponse.contains("\"cancelled\":true"), "Pi pending permission cancelled before turn stop")
        let unavailablePi = PiRPCHarness(executableURL: fakePiURL, permissionExtensionURL: piExtensionURL, sandboxExecutableURL: nil)
        var unavailablePiFailure = ""
        for await event in unavailablePi.stream(prompt: "Edit", sessionID: UUID(), threadID: nil, workspace: piWorkspace, provider: "test", model: "model", reasoningEffort: nil, allowFileModification: true) {
            if case .failed(let message) = event { unavailablePiFailure = message }
        }
        expect(unavailablePiFailure.contains("workspace sandbox is unavailable"), "Pi refuses write-capable launch without sandbox")
        try? FileManager.default.removeItem(at: piWorkspace)

        let hardware = HardwareProfile(chipName: "Test", physicalMemoryBytes: 16 * 1_073_741_824)
        let small = LocalModelRecommendation(id: "small", name: "Small", ollamaTag: "small", parameterCountB: 3, quantizationBits: 4, category: "Fast", contextTokens: 8_192)
        let fastLongContext = LocalModelRecommendation(id: "fast-long", name: "Fast Long", ollamaTag: "fast-long", parameterCountB: 4, quantizationBits: 4, category: "Fast", contextTokens: 262_144)
        expect(small.fit(on: hardware) == .comfortable, "Hardware fit")
        expect(small.canInstall(on: hardware), "Install gate for fitting model")
        expect(small.serveProfile == .quick, "Serve profile inference")
        expect(fastLongContext.serveProfile == .quick, "Category intent wins over context size")
        expect(small.lifecyclePlan(on: hardware).idleUnloadMinutes == 3, "Quick model idle unload plan")
        expect(small.lifecyclePlan(on: hardware).preloadAllowed, "Small comfortable model can preload")
        let criticalHardware = HardwareProfile(chipName: "Test", physicalMemoryBytes: 16 * 1_073_741_824, thermalState: "Critical")
        expect(criticalHardware.safeModelBudgetBytes < hardware.safeModelBudgetBytes, "Thermal budget reduction")
        expect(!small.tupleSummary.contains("ollama") && !small.tupleSummary.contains("lattice") && small.tupleSummary.contains("context"), "Recommendation tuple hides internal routing labels")
        expect(LocalModelCatalog.recommendations(for: hardware, category: "Fast").first?.fit(on: hardware) == .comfortable, "Catalog ranking prefers fitting models")
        expect(LocalModelCatalog.recommendations(for: hardware, category: "Coding", fitOnly: true).allSatisfy { $0.canInstall(on: hardware) }, "Fit-only recommendations hide oversized local models")
        let fullCodingCount = LocalModelCatalog.recommendations(for: hardware, category: "Coding", fitOnly: false).count
        let fitCodingCount = LocalModelCatalog.recommendations(for: hardware, category: "Coding", fitOnly: true).count
        expect(LocalModelCatalog.hiddenOversizedRecommendationCount(for: hardware, category: "Coding") == fullCodingCount - fitCodingCount, "Hidden oversized recommendation count matches filtered catalog")
        expect(ExecutableDiscovery.locate("../tool", path: "/bin:/usr/bin") == nil, "Executable validation")
        expect(CodexExecHarness().isInstalled, "Codex discovery")
        let directCLI = CLIInstallSnapshot(executablePath: "/Users/test/.opencode/bin/opencode", homebrewPrefix: "/opt/homebrew", npmPrefix: "/Users/test/.local", homebrewFormulaInstalled: true, npmPackageInstalled: true)
        expect(CLIInstallResolver.source(for: directCLI, directPathMarkers: ["/.opencode/bin/"]) == .direct, "Direct CLI source wins")
        let directPlan = CLIInstallResolver.updatePlan(executableName: "opencode", source: .direct, homebrewFormula: "opencode", npmPackage: "opencode-ai", selfUpdateArguments: ["upgrade"], directArguments: ["upgrade", "--method", "curl"])
        expect(directPlan == CLIUpdateCommandPlan(source: .direct, executable: "opencode", arguments: ["upgrade", "--method", "curl"]), "Direct CLI update plan")
        let piNPMInstall = CLIInstallResolver.packageInstallPlan(npmPackage: "@earendil-works/pi-coding-agent", npmAvailable: true, pnpmAvailable: true)
        expect(piNPMInstall == CLIUpdateCommandPlan(source: .npmGlobal, executable: "npm", arguments: ["install", "-g", "@earendil-works/pi-coding-agent@latest"]), "Pi install uses its published npm package")
        let piPNPMInstall = CLIInstallResolver.packageInstallPlan(npmPackage: "@earendil-works/pi-coding-agent", npmAvailable: false, pnpmAvailable: true)
        expect(piPNPMInstall == CLIUpdateCommandPlan(source: .pnpmGlobal, executable: "pnpm", arguments: ["add", "-g", "@earendil-works/pi-coding-agent@latest"]), "Pi install falls back to pnpm")
        expect(CLIInstallResolver.packageInstallPlan(npmPackage: "package", npmAvailable: false, pnpmAvailable: false) == nil, "Package install fails closed without a package manager")
        expect(CLIInstallResolver.codexInstallPlan(homebrewAvailable: true, npmAvailable: true, pnpmAvailable: true) == CLIUpdateCommandPlan(source: .homebrewCask, executable: "brew", arguments: ["install", "--cask", "codex"]), "Codex install prefers official Homebrew cask")
        expect(CLIInstallResolver.codexInstallPlan(homebrewAvailable: false, npmAvailable: true, pnpmAvailable: true) == CLIUpdateCommandPlan(source: .npmGlobal, executable: "npm", arguments: ["install", "-g", "@openai/codex@latest"]), "Codex install falls back to official npm package")
        expect(CLIInstallResolver.codexInstallPlan(homebrewAvailable: false, npmAvailable: false, pnpmAvailable: true) == CLIUpdateCommandPlan(source: .pnpmGlobal, executable: "pnpm", arguments: ["add", "-g", "@openai/codex@latest"]), "Codex install falls back to official package through pnpm")
        expect(CLIInstallResolver.codexInstallPlan(homebrewAvailable: false, npmAvailable: false, pnpmAvailable: false) == nil, "Codex install fails closed without a supported package manager")
        expect(RemoteInstallerScriptPolicy.validationMessage(for: URL(string: "https://x.ai/cli/install.sh")!) == nil, "Remote installer policy allows the exact official Grok endpoint")
        expect(RemoteInstallerScriptPolicy.validationMessage(for: URL(string: "https://opencode.ai/install")!) == nil, "Remote installer policy allows the exact official OpenCode endpoint")
        expect(RemoteInstallerScriptPolicy.validationMessage(for: URL(string: "https://hermes-agent.nousresearch.com/install.sh")!) == nil, "Remote installer policy allows the exact official Hermes endpoint")
        expect(RemoteInstallerScriptPolicy.validationMessage(for: URL(string: "https://antigravity.google/cli/install.sh")!) != nil, "Remote installer policy rejects the unverified Antigravity endpoint")
        expect(RemoteInstallerScriptPolicy.validationMessage(for: Data("#!/bin/bash\nset -e\necho install\n".utf8)) == nil, "Remote installer policy accepts a bounded UTF-8 shell script")
        expect(RemoteInstallerScriptPolicy.validationMessage(for: Data("<html>not a script</html>".utf8)) != nil, "Remote installer policy rejects provider error pages")
        expect(RemoteInstallerScriptPolicy.validationMessage(for: Data(repeating: 65, count: RemoteInstallerScriptPolicy.maximumByteCount + 1)) != nil, "Remote installer policy rejects oversized downloads")
        expect(ExecutableDiscovery.locate("bash") != nil, "Executable discovery includes the system shell used for staged installer validation")
        let brewCLI = CLIInstallSnapshot(executablePath: "/opt/homebrew/bin/codex", homebrewPrefix: "/opt/homebrew", homebrewCaskInstalled: true, npmPackageInstalled: true)
        expect(CLIInstallResolver.source(for: brewCLI) == .homebrewCask, "Homebrew cask source")
        let brewPlan = CLIInstallResolver.updatePlan(executableName: "codex", source: .homebrewCask, homebrewCask: "codex")
        expect(brewPlan == CLIUpdateCommandPlan(source: .homebrewCask, executable: "brew", arguments: ["upgrade", "--cask", "codex"]), "Homebrew cask update plan")
        let rawUpdateInfo = CLIUpdateInfo(updateAvailable: true, detail: "Update available: 1048 commits behind — run 'hermes update'")
        expect(rawUpdateInfo.statusText == "Update available", "Raw CLI update text is not surfaced")
        expect(CLIVersionDisplayPolicy.targetVersion(currentVersion: "0.13.0", latestVersion: "0.14.0") == "0.14.0", "CLI target version uses latest version")
        expect(CLIVersionDisplayPolicy.updateActionTitle("Update CLI", currentVersion: "codex 0.13.0", latestVersion: "codex 0.14.0") == "Update CLI (0.14.0)", "CLI update title displays target version")
        expect(CLIVersionDisplayPolicy.updateActionTitle("Update CLI", currentVersion: "0.14.0", latestVersion: "v0.14.0") == "Update CLI", "CLI update title hides current version")
        expect(CLIVersionDisplayPolicy.normalizedVersion("Update available: 0.13.0 → v0.14.0") == "0.14.0", "CLI parser extracts newest version from update text")
        expect(CLIVersionDisplayPolicy.normalizedVersion("Update available: 1048 commits behind") == nil, "CLI parser rejects non-version counters")
        expect(CLIVersionDisplayPolicy.targetVersion(currentVersion: nil, latestVersion: "v0.15.0") == "0.15.0", "CLI target version shows known latest version without current version")
        expect(CLIVersionDisplayPolicy.releaseNotes(from: "Update available\nRelease notes:\n- Better ACP restore\n- Fix cancellation") == "- Better ACP restore\n- Fix cancellation", "CLI release note parser extracts provider notes")
        expect(CLIVersionDisplayPolicy.releaseNotes(from: "Update available: 1048 commits behind") == nil, "CLI release note parser ignores generic update banners")
        expect(CLIUpdateInfo(latestVersion: "0.15.0", updateAvailable: true).statusText == "Update available · 0.15.0", "CLI update status includes target version")
        expect(CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: "0.13.0", latestVersion: "0.14.0"), "CLI update availability compares semantic versions")
        expect(!CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: "0.141.0", latestVersion: "0.141.0"), "Current CLI does not show an update")
        expect(!CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: "0.141.0", latestVersion: "0.140.0"), "Older catalog version does not show an update")
        expect(CLIActionStatusPolicy.signInMessage(providerName: "OpenCode", commandSucceeded: true, readyAfterRefresh: true).isEmpty, "Verified sign in clears action message")
        expect(CLIActionStatusPolicy.signInMessage(providerName: "OpenCode", commandSucceeded: false, readyAfterRefresh: false) == "Sign in failed for OpenCode.", "Failed sign in remains visible")
        expect(CLIActionStatusPolicy.signInMessage(providerName: "OpenCode", commandSucceeded: true, readyAfterRefresh: false) == "Sign in finished, but Lattice could not verify a runnable OpenCode connection.", "Unverified sign in remains visible")
        expect(CLIActionStatusPolicy.signInMessage(providerName: "OpenCode", commandSucceeded: false, readyAfterRefresh: true).isEmpty, "Refreshed readiness overrides stale command status")
        expect(CLIActionStatusPolicy.messageIndicatesProblem("pi installed, but it is not on PATH yet."), "PATH warning is styled as a problem")
        expect(CLIActionStatusPolicy.messageIndicatesProblem("Active CLI stayed on 1.0.0."), "Unchanged version warning is styled as a problem")
        expect(!CLIActionStatusPolicy.messageIndicatesProblem("Update available"), "Available update is not styled as a failure")
        expect(CLIActionStatusPolicy.installMessage(executableName: "pi", status: 1, output: Data("network failed".utf8), executableAvailableAfterRefresh: true) == "Install failed: network failed", "Install failure is not hidden by an existing executable")
        expect(CLIActionStatusPolicy.installMessage(executableName: "pi", status: 0, output: Data(), executableAvailableAfterRefresh: false) == "pi installed, but it is not on PATH yet.", "Install success without PATH reports PATH issue")
        expect(CLIActionStatusPolicy.installMessage(executableName: "pi", status: 0, output: Data(), executableAvailableAfterRefresh: true).isEmpty, "Verified install clears action message")
        expect(CLIActionStatusPolicy.updateMessage(status: 1, output: Data("permission denied".utf8), beforeVersion: "1.0.0", afterVersion: "1.0.0") == "Update failed: permission denied", "Update failure reports command error")
        expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data(), beforeVersion: "1.0.0", afterVersion: "1.1.0").isEmpty, "Update with changed active version clears action message")
        expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data(), beforeVersion: nil, afterVersion: "1.1.0").isEmpty, "Update with newly verified active version clears action message")
        expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data("Already up to date".utf8), beforeVersion: "1.0.0", afterVersion: "1.0.0").isEmpty, "Up-to-date update output clears action message")
        expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data("done".utf8), beforeVersion: "1.0.0", afterVersion: "1.0.0") == "Active CLI stayed on 1.0.0.", "Unchanged active CLI version is reported")
        expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data("done".utf8), beforeVersion: "1.0.0", afterVersion: nil) == "Update finished, but Lattice could not verify the active CLI version.", "Update that loses active version visibility is reported as unverifiable")
        expect(CLIActionStatusPolicy.updateMessage(status: 0, output: Data("done".utf8), beforeVersion: nil, afterVersion: nil) == "Update finished, but Lattice could not verify the active CLI version.", "Unverifiable update success stays visible")
        let fakeOpenCodeModelsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: fakeOpenCodeModelsRoot, withIntermediateDirectories: true)
        let fakeOpenCodeModelsURL = fakeOpenCodeModelsRoot.appendingPathComponent("opencode")
        let fakeOpenCodeRefreshMarker = fakeOpenCodeModelsRoot.appendingPathComponent("refreshed")
        let fakeOpenCodeModelsScript = """
        #!/bin/sh
        if [ "$1" = "models" ] && [ "$2" = "--refresh" ]; then
          printf refreshed > "\(fakeOpenCodeRefreshMarker.path)"
          exit 0
        fi
        if [ "$1" = "models" ] && [ "$2" = "opencode" ]; then
          printf '%s\\n' '{"id":"qwen3-coder","providerID":"opencode","name":"Qwen3 Coder","limit":{"context":64000},"variants":{"low":{},"medium":{},"high":{"reasoningEffort":"high"}}}'
          exit 0
        fi
        if [ "$1" = "models" ] && [ "$2" = "opencode-go" ]; then
          printf '%s\\n' '{"id":"deepseek-v4-pro","providerID":"opencode-go","name":"DeepSeek V4 Pro","contextWindow":"128k","variants":{"thinking":{"reasoningEffort":"thinking"},"max":{}}}'
          exit 0
        fi
        exit 1
        """
        try! Data(fakeOpenCodeModelsScript.utf8).write(to: fakeOpenCodeModelsURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpenCodeModelsURL.path)
        let parsedOpenCodeModels = await StructuredCLIHarness(kind: .openCode, executableURL: fakeOpenCodeModelsURL).models(refreshCache: true)
        let qwenReasoning = parsedOpenCodeModels.first { $0.id == "opencode/qwen3-coder" }?.reasoningOptions.map(\.effort) ?? []
        let goReasoning = parsedOpenCodeModels.first { $0.id == "opencode-go/deepseek-v4-pro" }?.reasoningOptions.map(\.effort) ?? []
        expect(qwenReasoning == [.low, .medium, .high], "OpenCode reasoning variants are discovered")
        expect(parsedOpenCodeModels.first { $0.id == "opencode/qwen3-coder" }?.defaultReasoningEffort == .medium, "OpenCode reasoning default prefers medium")
        expect(parsedOpenCodeModels.first { $0.id == "opencode/qwen3-coder" }?.contextWindow == 64_000, "OpenCode model context limit is parsed from provider metadata")
        expect(goReasoning == [.max, .thinking], "OpenCode Go reasoning variants are discovered")
        expect(parsedOpenCodeModels.first { $0.id == "opencode-go/deepseek-v4-pro" }?.contextWindow == 128_000, "OpenCode model context limit supports abbreviated provider metadata")
        expect(FileManager.default.fileExists(atPath: fakeOpenCodeRefreshMarker.path), "OpenCode explicit refresh updates the provider model cache before reading catalogs")
        try? FileManager.default.removeItem(at: fakeOpenCodeModelsRoot)

        let parsedGrokTextModels = StructuredCLIHarness.parseModels(Data("""
        You are logged in
        * grok-thinking-test (default)
        - grok-reasoning-test
        """.utf8), kind: .grok)
        expect(parsedGrokTextModels.count == 2, "Grok text model catalog parses models")
        expect(parsedGrokTextModels.allSatisfy { $0.reasoningOptions.isEmpty }, "Grok text model catalog does not infer reasoning options from names")
        expect(parsedGrokTextModels.first { $0.id == "grok-thinking-test" }?.isDefault == true, "Grok text model catalog preserves default marker")
        let parsedGrokStructuredModel = StructuredCLIHarness.parseModels(Data("""
        {"id":"grok-structured","name":"Grok Structured","isDefault":true,"reasoningOptions":["high","low"],"defaultReasoningEffort":"high","model_context_window":131072}
        """.utf8), kind: .grok).first
        expect(parsedGrokStructuredModel?.reasoningOptions.map(\.effort) == [.low, .high], "Grok structured model catalog exposes declared reasoning options")
        expect(parsedGrokStructuredModel?.defaultReasoningEffort == .high, "Grok structured model catalog preserves declared default reasoning")
        expect(parsedGrokStructuredModel?.contextWindow == 131_072, "Grok structured model catalog preserves declared context window")
        let reasoningCodexModels = [
            ProviderModel(id: "gpt", name: "GPT", reasoningOptions: [ReasoningOption(effort: .low), ReasoningOption(effort: .high)], defaultReasoningEffort: .high)
        ]
        let reasoningGrokModels = [
            ProviderModel(id: "grok-structured", name: "Grok Structured", reasoningOptions: [ReasoningOption(effort: .high)], defaultReasoningEffort: .high)
        ]
        let reasoningOpenCodeModels = [
            ProviderModel(id: "opencode-go/deepseek", name: "DeepSeek", reasoningOptions: [ReasoningOption(effort: .thinking)], defaultReasoningEffort: .thinking)
        ]
        expect(ReasoningCapabilityPolicy.options(for: .codex(model: "gpt"), harnessID: "codex", codexModels: reasoningCodexModels, grokModels: reasoningGrokModels, openCodeModels: reasoningOpenCodeModels).map(\.effort) == [.low, .high], "Codex reasoning options remain available on Codex route")
        expect(ReasoningCapabilityPolicy.defaultEffort(for: .codex(model: "gpt"), harnessID: "codex", codexModels: reasoningCodexModels, grokModels: reasoningGrokModels, openCodeModels: reasoningOpenCodeModels) == .high, "Codex reasoning default remains available on Codex route")
        expect(ReasoningCapabilityPolicy.options(for: .grok(model: "grok-structured"), harnessID: "grok", codexModels: reasoningCodexModels, grokModels: reasoningGrokModels, openCodeModels: reasoningOpenCodeModels).isEmpty, "Grok reasoning options stay hidden until Grok execution supports them")
        expect(ReasoningCapabilityPolicy.defaultEffort(for: .grok(model: "grok-structured"), harnessID: "grok", codexModels: reasoningCodexModels, grokModels: reasoningGrokModels, openCodeModels: reasoningOpenCodeModels) == nil, "Grok reasoning default stays hidden until Grok execution supports it")
        expect(ReasoningCapabilityPolicy.options(for: .openCode(model: "opencode-go/deepseek"), harnessID: "opencode", codexModels: reasoningCodexModels, grokModels: reasoningGrokModels, openCodeModels: reasoningOpenCodeModels).isEmpty, "Plain OpenCode route hides reasoning options")
        expect(ReasoningCapabilityPolicy.options(for: .openCode(model: "opencode-go/deepseek"), harnessID: "pi", codexModels: reasoningCodexModels, grokModels: reasoningGrokModels, openCodeModels: reasoningOpenCodeModels).map(\.effort) == [.thinking], "Pi-backed OpenCode route exposes reasoning options")
        expect(ReasoningCapabilityPolicy.defaultEffort(for: .openCode(model: "opencode-go/deepseek"), harnessID: "pi", codexModels: reasoningCodexModels, grokModels: reasoningGrokModels, openCodeModels: reasoningOpenCodeModels) == .thinking, "Pi-backed OpenCode route exposes reasoning default")

        let backendSnapshot = BackendAvailabilitySnapshot(
            codexModels: [
                ProviderModel(id: "gpt-5.4", name: "GPT-5.4"),
                ProviderModel(id: "gpt-5.5", name: "GPT-5.5", isDefault: true)
            ],
            grokModels: [ProviderModel(id: "grok-4", name: "Grok 4", isDefault: true)],
            openCodeModels: [ProviderModel(id: "qwen3-coder", name: "Qwen3 Coder", isDefault: true)],
            appleIntelligenceReady: false,
            ollamaModelNames: ["llama3.2:latest"],
            codexInstalled: true
        )
        expect(BackendAvailabilityPolicy.normalize(.antigravity(model: "composer"), using: backendSnapshot) == .codex(model: "gpt-5.5"), "Antigravity chat backend normalized")
        expect(BackendAvailabilityPolicy.normalize(.appleIntelligence, using: backendSnapshot) == .codex(model: "gpt-5.5"), "Unavailable Apple backend normalized")
        expect(BackendAvailabilityPolicy.normalize(.ollama(model: "missing:latest"), using: backendSnapshot) == .codex(model: "gpt-5.5"), "Missing Ollama model normalized")
        expect(BackendAvailabilityPolicy.normalize(.openCode(model: "old-opencode"), using: backendSnapshot) == .openCode(model: "qwen3-coder"), "Stale OpenCode model normalized")

        let extensionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let strictEnvelope = """
        <lattice-extension-manifest>
        {"schemaVersion":1,"id":"com.lattice.strict","name":"Strict","version":"1","summary":"Strict manifest."}
        </lattice-extension-manifest>
        """
        expect((try! LatticeExtensionManifestEnvelope.decode(from: strictEnvelope)).id == "com.lattice.strict", "Self-edit manifest envelope decodes exact manifest")
        do {
            _ = try LatticeExtensionManifestEnvelope.decode(from: "Here is the change.\n\(strictEnvelope)")
            expect(false, "Self-edit manifest envelope rejects extra text")
        } catch {
            expect(error.localizedDescription.contains("extra text"), "Self-edit manifest envelope rejects extra text")
        }
        do {
            _ = try LatticeExtensionManifestEnvelope.decode(from: "\(strictEnvelope)\n\(strictEnvelope)")
            expect(false, "Self-edit manifest envelope rejects duplicate manifests")
        } catch {
            expect(error.localizedDescription.contains("extra text") || error.localizedDescription.contains("more than one"), "Self-edit manifest envelope rejects duplicate manifests")
        }
        do {
            _ = try LatticeExtensionManifestEnvelope.decode(from: "<lattice-extension-manifest>{\"schemaVersion\":1,</lattice-extension-manifest>")
            expect(false, "Self-edit manifest envelope rejects invalid JSON")
        } catch {
            expect(error.localizedDescription.contains("invalid"), "Self-edit manifest envelope rejects invalid JSON")
        }
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.theme-pack",
            name: "Theme Pack",
            version: "1.0.0",
            summary: "Changes local UI styling.",
            permissions: [.editUI],
            entrypoint: "extension.json",
            uiTargets: ["overlay"],
            stylePatches: [.init(target: .overlay, tintHex: "#FF4FA3", cornerRadius: 24)]
        )
        let extensionBundle = extensionRoot.appendingPathComponent(manifest.id, isDirectory: true)
        try! FileManager.default.createDirectory(at: extensionBundle, withIntermediateDirectories: true)
        let manifestData = try! JSONEncoder().encode(manifest)
        try! manifestData.write(to: extensionBundle.appendingPathComponent("lattice-extension.json"))
        let extensionStore = LatticeExtensionStore(rootURL: extensionRoot)
        let loadedExtensions = extensionStore.load()
        expect(loadedExtensions.count == 1, "Extension load")
        expect(loadedExtensions.first?.isValid == true, "Extension validation")
        expect(loadedExtensions.first?.stylePatches.first?.target == .overlay, "Extension style patch")
        let duplicateRoot = extensionRoot.appendingPathComponent("duplicates", isDirectory: true)
        let duplicateA = duplicateRoot.appendingPathComponent("a", isDirectory: true)
        let duplicateB = duplicateRoot.appendingPathComponent("b", isDirectory: true)
        try! FileManager.default.createDirectory(at: duplicateA, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: duplicateB, withIntermediateDirectories: true)
        let duplicateOne = LatticeExtensionManifest(id: "com.lattice.duplicate", name: "Duplicate A", version: "1", summary: "First.", permissions: [.editUI], stylePatches: [.init(target: .composer, tintHex: "#88CCFF")])
        let duplicateTwo = LatticeExtensionManifest(id: "COM.LATTICE.DUPLICATE", name: "Duplicate B", version: "1", summary: "Second.", permissions: [.editUI], stylePatches: [.init(target: .overlay, tintHex: "#88CCFF")])
        try! JSONEncoder().encode(duplicateOne).write(to: duplicateA.appendingPathComponent("lattice-extension.json"))
        try! JSONEncoder().encode(duplicateTwo).write(to: duplicateB.appendingPathComponent("lattice-extension.json"))
        let duplicateRecords = LatticeExtensionStore(rootURL: duplicateRoot).load()
        expect(duplicateRecords.count == 2, "Duplicate extension ids both load for review")
        expect(duplicateRecords.allSatisfy { !$0.isValid }, "Duplicate extension ids are invalid")
        expect(duplicateRecords.allSatisfy { $0.validationMessages.contains { $0.contains("Duplicate extension id") } }, "Duplicate extension ids explain validation failure")
        expect(extensionStore.validate(LatticeExtensionManifest(id: "COM.LATTICE.UPPERCASE", name: "Uppercase", version: "1", summary: "Uses uppercase id.")).contains("Id must be lowercase."), "Extension manifest id rejects uppercase")
        let badDisplayMetadata = LatticeExtensionManifest(id: "bad-display-metadata", name: " Calmer\nLattice ", version: " 1\n.0 ", summary: " Softens\napp tone ")
        let badDisplayMetadataMessages = extensionStore.validate(badDisplayMetadata)
        expect(badDisplayMetadataMessages.contains("Name must not have leading or trailing whitespace."), "Extension manifest name rejects surrounding whitespace")
        expect(badDisplayMetadataMessages.contains("Name must be one line."), "Extension manifest name rejects newlines")
        expect(badDisplayMetadataMessages.contains("Version must not have leading or trailing whitespace."), "Extension manifest version rejects surrounding whitespace")
        expect(badDisplayMetadataMessages.contains("Version must be one line."), "Extension manifest version rejects newlines")
        expect(badDisplayMetadataMessages.contains("Summary must not have leading or trailing whitespace."), "Extension manifest summary rejects surrounding whitespace")
        expect(badDisplayMetadataMessages.contains("Summary must be one line."), "Extension manifest summary rejects newlines")
        let previousData = try! Data(contentsOf: extensionBundle.appendingPathComponent("lattice-extension.json"))
        let replacement = LatticeExtensionManifest(
            id: "com.lattice.theme-pack",
            name: "Theme Pack",
            version: "1.1.0",
            summary: "Changes composer styling.",
            permissions: [.editUI],
            uiTargets: ["composer"],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF", cornerRadius: 18)],
            layoutPatches: [.init(target: .composer, density: .compact)],
            copyPatches: [.init(target: .askButton, text: "Ask softly")],
            promptTemplates: [
                .init(invocation: "/summarize", title: "Summarize", detail: "Five bullets", prompt: "Summarize this in five bullets.")
            ],
            skillPatches: [
                .init(id: "subagents", title: "Subagents", summary: "Use helper agents.", markdown: "# Subagents\n\nUse bounded helper agents.")
            ],
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .relayout, summary: "Make the composer compact.", detail: "Executable when backed by a composer layout patch."),
                .init(targetSurfaceID: "extensions", operation: .addSkill, summary: "Add subagents skill.", detail: "Executable when backed by a skill patch.")
            ]
        )
        _ = try! extensionStore.writeGeneratedExtension(replacement)
        expect(replacement.hasRuntimePatches, "Extension detects real runtime patches")
        expect(extensionStore.load().first?.version == "1.1.0", "Generated extension overwrite")
        expect(extensionStore.load().first?.hasRuntimePatches == true, "Loaded extension detects real runtime patches")
        expect(extensionStore.load().first?.layoutPatches == replacement.layoutPatches, "Extension layout patches load")
        expect(extensionStore.load().first?.copyPatches == replacement.copyPatches, "Extension copy patches load")
        expect(extensionStore.load().first?.promptTemplates == replacement.promptTemplates, "Extension prompt templates load")
        expect(extensionStore.load().first?.skillPatches == replacement.skillPatches, "Extension skill patches load")
        expect(replacement.promptTemplates.first?.command.replacementText == "Summarize this in five bullets.", "Prompt template becomes an inserting command")
        expect(extensionStore.load().first?.operationPreviews == replacement.operationPreviews, "Extension operation previews load")
        let skillRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let globalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let globalSkillFolder = globalRoot.appendingPathComponent("subagents", isDirectory: true)
        let reservedGlobalSkillFolder = globalRoot.appendingPathComponent("self-edit", isDirectory: true)
        try! FileManager.default.createDirectory(at: globalSkillFolder, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: reservedGlobalSkillFolder, withIntermediateDirectories: true)
        try! Data("# Subagents\n\nUse helper agents.".utf8).write(to: globalSkillFolder.appendingPathComponent("SKILL.md"))
        try! Data("# Self Edit\n\nReserved collision.".utf8).write(to: reservedGlobalSkillFolder.appendingPathComponent("SKILL.md"))
        let skillStore = LatticeSkillStore(rootURL: skillRoot, globalRoots: [globalRoot])
        try! skillStore.importGlobalSkills()
        let importedSkills = skillStore.load()
        expect(importedSkills.first?.id == "subagents", "Global skills import into Lattice skills folder")
        expect(!importedSkills.contains { $0.id == "self-edit" }, "Global skills cannot import over Lattice's reserved self-edit command")
        if let importedSkill = importedSkills.first {
            expect(LatticeSkillPromptBuilder.command(for: importedSkill).invocation == "/subagents", "Imported skill becomes a slash command")
        } else {
            expect(false, "Imported skill becomes a slash command")
        }
        let legacySidecarRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacyImportedFolder = legacySidecarRoot.appendingPathComponent("legacy-import", isDirectory: true)
        try! FileManager.default.createDirectory(at: legacyImportedFolder, withIntermediateDirectories: true)
        try! Data("# Legacy Import\n\nImported skill.".utf8).write(to: legacyImportedFolder.appendingPathComponent("SKILL.md"))
        try! Data(LatticeSkillSource.importedGlobal.rawValue.utf8).write(
            to: legacyImportedFolder.appendingPathComponent(LatticeLegacyBrandCompatibility.skillSourceMarker)
        )
        let legacySidecarStore = LatticeSkillStore(rootURL: legacySidecarRoot, globalRoots: [])
        try! legacySidecarStore.deleteSkill(id: "legacy-import")
        expect(!FileManager.default.fileExists(atPath: legacyImportedFolder.path), "Legacy imported-skill sidecar retains deletion semantics")
        let legacyOwnedFolder = legacySidecarRoot.appendingPathComponent("legacy-owned", isDirectory: true)
        try! FileManager.default.createDirectory(at: legacyOwnedFolder, withIntermediateDirectories: true)
        try! Data("# Legacy Owned\n\nOwned skill.".utf8).write(to: legacyOwnedFolder.appendingPathComponent("SKILL.md"))
        try! Data("com.lattice.owner".utf8).write(
            to: legacyOwnedFolder.appendingPathComponent(LatticeLegacyBrandCompatibility.skillOwnerMarker)
        )
        expect((try! legacySidecarStore.deleteSkill(id: "legacy-owned", ownedByExtensionID: "com.lattice.other")) == false, "Legacy owner sidecar rejects wrong-owner deletion")
        expect(try! legacySidecarStore.deleteSkill(id: "legacy-owned", ownedByExtensionID: "com.lattice.owner"), "Legacy owner sidecar authorizes matching-owner deletion")
        if let invocation = LatticeSkillPromptBuilder.invocation(in: "/subagents split this into helper tasks", records: importedSkills, disabledSkillIDs: []) {
            let prompt = LatticeSkillPromptBuilder.prompt(for: invocation)
            expect(invocation.userRequest == "split this into helper tasks" && prompt.contains("# Subagents") && prompt.contains("Lattice skill invocation: /subagents"), "Enabled skill invocation injects SKILL.md into backend prompt")
            let visibleSkillMessage = ChatMessage(role: .user, text: "/subagents split this into helper tasks")
            let structuredSkillSession = LatticeSession(
                title: "Skill chat",
                messages: [.init(role: .user, text: "Earlier"), .init(role: .assistant, text: "Earlier answer"), visibleSkillMessage, .init(role: .assistant, text: "")],
                backend: .ollama(model: "qwen3:8b")
            )
            let backendMessages = LatticeBackendMessageBuilder.structuredMessages(session: structuredSkillSession, submittedText: prompt, additionalContext: "\n\nAttached paths:\n/tmp/a.swift")
            expect(backendMessages.last?.text.contains("Lattice skill invocation: /subagents") == true && backendMessages.last?.text.contains("/tmp/a.swift") == true, "Structured local routes receive injected skill prompt and attachments")
            expect(structuredSkillSession.messages[2].text == "/subagents split this into helper tasks", "Visible skill invocation remains unchanged in canonical transcript")
        } else {
            expect(false, "Enabled skill invocation injects SKILL.md into backend prompt")
        }
        expect(LatticeSkillPromptBuilder.invocation(in: "/subagents split this", records: importedSkills, disabledSkillIDs: ["subagents"]) == nil, "Disabled skills are not invoked")
        let generatedReviewSkill = LatticeSkillPatch(id: "review-buddy", title: "Review Buddy", summary: "Review changes.", markdown: "# Review Buddy\n\nReview patches for risk.")
        let generatedReviewPreview = LatticeSkillPatchPreviewBuilder.preview(for: generatedReviewSkill)
        expect(generatedReviewPreview.command == "/review-buddy", "Skill preview shows generated slash command")
        expect(generatedReviewPreview.fileName == "SKILL.md", "Skill preview identifies generated skill file")
        expect(generatedReviewPreview.summary == "Review changes.", "Skill preview uses explicit summary")
        expect(generatedReviewPreview.markdownLineCount == 3 && generatedReviewPreview.markdownCharacterCount == generatedReviewSkill.markdown.count, "Skill preview reports markdown size")
        let fallbackSkillPreview = LatticeSkillPatchPreviewBuilder.preview(for: .init(id: "quiet-mode", title: "Quiet Mode", summary: "", markdown: "# Quiet Mode\n\nKeep replies calm."))
        expect(fallbackSkillPreview.summary == "Quiet Mode", "Skill preview falls back to markdown heading when summary is empty")
        let reservedSkill = LatticeSkillPatch(id: "self-edit", title: "Self Edit", summary: "Reserved.", markdown: "# Self Edit\n\nReserved.")
        expect(LatticeSkillStore.validate(reservedSkill).contains { $0.contains("cannot replace /self-edit") }, "Skills cannot replace Lattice's reserved self-edit command")
        let shallowGeneratedSkill = LatticeSkillPatch(id: "shallow", title: "Shallow", summary: "Too short.", markdown: "# Shallow\n\nDo the task.")
        expect(LatticeSkillStore.validateGenerated(shallowGeneratedSkill).contains(where: { $0.contains("at least 600 characters") }), "Self-edit rejects shallow generated skills without rejecting imported skill compatibility")
        let canonicalSubagentsTemplateSkill = LatticeSkillPatch(
            id: "subagents",
            title: "Subagents",
            summary: "Use parallel helper agents for independent subtasks.",
            markdown: LatticeGeneratedSkillTemplate.subagentsMarkdown
        )
        expect(LatticeSkillStore.validateGenerated(canonicalSubagentsTemplateSkill).isEmpty, "Self-edit's canonical subagents skill template satisfies generated skill quality rules")
        expect(
            LatticeGeneratedSkillTemplate.subagentsMarkdown.contains("1.")
            && LatticeGeneratedSkillTemplate.subagentsMarkdown.contains("## Guardrails")
            && LatticeGeneratedSkillTemplate.subagentsMarkdown.contains("## Verification"),
            "Self-edit generated skill template demonstrates numbered workflow, guardrails, and verification"
        )
        let shallowGeneratedManifest = LatticeExtensionManifest(
            id: "com.lattice.shallow-skill",
            name: "Shallow Skill",
            version: "1.0.0",
            summary: "Adds a shallow generated skill.",
            permissions: [.editUI],
            skillPatches: [shallowGeneratedSkill]
        )
        expect(extensionStore.validate(shallowGeneratedManifest).isEmpty, "General extension validation remains compatible with short manually installed skills")
        expect(
            LatticeSelfEditGeneratedSkillValidationPolicy.validationMessages(for: shallowGeneratedManifest).contains { $0.contains("Skill shallow: Generated skill markdown must be at least 600 characters") },
            "Self-edit generated-skill validation rejects shallow skills before preview edits can be applied"
        )
        let paddedGenericMarkdown = """
        ---
        name: generic-helper
        description: Use this skill for many different tasks whenever the user asks for help with anything in Lattice.
        ---

        # Generic Helper

        This deliberately padded introduction is long enough to avoid a simple character-count-only check, but it still does not provide a reusable operating procedure with real decisions, concrete limits, or evidence requirements. It keeps repeating that the assistant should help carefully and be useful without explaining how to perform the work. It should therefore fail generated skill validation even though it has the required headings and frontmatter.

        ## Quick start

        Help the user.

        ## Workflow

        1. Read the request.
        2. Do it.

        ## Guardrails

        Be careful.

        ## Verification

        Make sure it is good.
        """
        let paddedGenericSkill = LatticeSkillPatch(id: "generic-helper", title: "Generic Helper", summary: "Generic help.", markdown: paddedGenericMarkdown)
        let paddedGenericMessages = LatticeSkillStore.validateGenerated(paddedGenericSkill)
        expect(paddedGenericMessages.contains { $0.contains("Workflow section must include at least three numbered steps") } && paddedGenericMessages.contains { $0.contains("Quick Start section is too thin") }, "Self-edit rejects padded but generic generated skills")
        let richGeneratedMarkdown = """
        ---
        name: change-reviewer
        description: Review proposed changes when a user needs scope, risk, rollback, and verification guidance before applying them.
        ---

        # Change Reviewer

        ## Quick start

        Read the proposed change list, identify executable effects, and give a plain-language recommendation before any mutation occurs.

        ## Workflow

        1. Compare the proposed artifact with the currently active version and ignore unchanged fields.
        2. Trace every changed setting to its user-visible effect and identify conflicts, stale state, or missing prerequisites.
        3. Separate reversible application-owned changes from provider credentials, workspace files, operating-system permissions, and recorded-only plans.
        4. Explain what applying the review changes, what remains untouched, and what revision would reduce unnecessary scope.
        5. Confirm that rollback data exists for every executable effect before recommending Apply.

        ## Guardrails

        Never describe a recorded-only proposal as executable. Do not infer access to source code, app bundles, credentials, or unrelated extensions. Reject stale previews and surface uncertainty instead of inventing evidence.

        ## Verification

        Verify identifiers, changed values, ownership, enablement, permissions, and rollback coverage. Report an Apply, Revise, or Discard recommendation with the evidence needed to make the decision without reading the complete manifest.
        """
        let richGeneratedSkill = LatticeSkillPatch(id: "change-reviewer", title: "Change Reviewer", summary: "Review change scope, risk, and rollback before applying.", markdown: richGeneratedMarkdown)
        expect(LatticeSkillStore.validateGenerated(richGeneratedSkill).isEmpty, "Self-edit accepts substantive generated skills with reusable workflow, guardrails, and verification")
        let unclosedFrontmatterMarkdown = richGeneratedMarkdown.replacingOccurrences(
            of: "\n---\n\n# Change Reviewer",
            with: "\n\n# Change Reviewer"
        )
        let unclosedFrontmatterSkill = LatticeSkillPatch(id: "change-reviewer", title: "Change Reviewer", summary: "Malformed frontmatter.", markdown: unclosedFrontmatterMarkdown)
        expect(LatticeSkillStore.validateGenerated(unclosedFrontmatterSkill).contains { $0.contains("YAML frontmatter") }, "Self-edit rejects generated skills with unclosed YAML frontmatter")
        let extraFrontmatterMarkdown = richGeneratedMarkdown.replacingOccurrences(
            of: "description: Review proposed changes when a user needs scope, risk, rollback, and verification guidance before applying them.\n---",
            with: "description: Review proposed changes when a user needs scope, risk, rollback, and verification guidance before applying them.\nversion: 1\n---"
        )
        let extraFrontmatterSkill = LatticeSkillPatch(id: "change-reviewer", title: "Change Reviewer", summary: "Malformed frontmatter.", markdown: extraFrontmatterMarkdown)
        expect(LatticeSkillStore.validateGenerated(extraFrontmatterSkill).contains { $0.contains("only contain name and description") }, "Self-edit rejects generated skills with non-portable frontmatter keys")
        let duplicateFrontmatterMarkdown = richGeneratedMarkdown.replacingOccurrences(
            of: "name: change-reviewer\n",
            with: "name: change-reviewer\nname: other-reviewer\n"
        )
        let duplicateFrontmatterSkill = LatticeSkillPatch(id: "change-reviewer", title: "Change Reviewer", summary: "Malformed frontmatter.", markdown: duplicateFrontmatterMarkdown)
        expect(LatticeSkillStore.validateGenerated(duplicateFrontmatterSkill).contains { $0.contains("must not repeat keys") }, "Self-edit rejects generated skills with duplicate frontmatter keys")
        let malformedFrontmatterMarkdown = richGeneratedMarkdown.replacingOccurrences(
            of: "description: Review proposed changes when a user needs scope, risk, rollback, and verification guidance before applying them.\n",
            with: "description: Review proposed changes when a user needs scope, risk, rollback, and verification guidance before applying them.\nnot a key value pair\n"
        )
        let malformedFrontmatterSkill = LatticeSkillPatch(id: "change-reviewer", title: "Change Reviewer", summary: "Malformed frontmatter.", markdown: malformedFrontmatterMarkdown)
        expect(LatticeSkillStore.validateGenerated(malformedFrontmatterSkill).contains { $0.contains("key: value pairs") }, "Self-edit rejects generated skills with malformed frontmatter lines")
        let priorReviewManifest = LatticeExtensionManifest(
            id: "com.lattice.review-test",
            name: "Review Test",
            version: "1.1.0",
            summary: "Changes only the prompt placeholder.",
            permissions: [.editUI],
            copyPatches: [.init(target: .promptPlaceholder, text: "Old prompt")],
            skillPatches: [richGeneratedSkill]
        )
        let updatedReviewManifest = LatticeExtensionManifest(
            id: "com.lattice.review-test",
            name: "Review Test",
            version: "1.1.0",
            summary: "Changes only the prompt placeholder.",
            permissions: [.editUI],
            copyPatches: [.init(target: .promptPlaceholder, text: "Ask Lattice calmly")],
            skillPatches: [richGeneratedSkill]
        )
        let changeReview = LatticeExtensionChangeReviewBuilder.review(current: updatedReviewManifest, previous: priorReviewManifest)
        expect(changeReview.changes == ["Change prompt placeholder text to “Ask Lattice calmly”."], "Self-edit review excludes unchanged extension and skill fields")
        expect(changeReview.hasChanges, "Self-edit review reports actual change presence")
        expect(changeReview.acceptanceSummary.contains("Applying makes") && changeReview.acceptanceSummary.contains("Nothing else in Lattice is modified") && changeReview.acceptanceSummary.contains("roll it back"), "Self-edit review explains Apply impact and rollback without requiring manifest inspection")
        let noOpReview = LatticeExtensionChangeReviewBuilder.review(current: priorReviewManifest, previous: priorReviewManifest)
        expect(!noOpReview.hasChanges && noOpReview.acceptanceSummary.contains("does not change"), "Self-edit no-op reviews are detectable before Apply")
        let removalReviewManifest = LatticeExtensionManifest(
            id: "com.lattice.review-test",
            name: "Review Test",
            version: "1.1.0",
            summary: "Changes only the prompt placeholder.",
            permissions: [.editUI],
            copyPatches: [],
            skillPatches: [],
            operationPreviews: []
        )
        let removalReview = LatticeExtensionChangeReviewBuilder.review(current: removalReviewManifest, previous: priorReviewManifest)
        expect(
            removalReview.changes.contains("Restore the default prompt placeholder text.")
                && removalReview.changes.contains("Remove the /change-reviewer skill owned by this extension."),
            "Self-edit review lists removed copy and skill changes instead of hiding removals"
        )
        expect(removalReview.acceptanceSummary.contains("roll it back"), "Self-edit removal reviews explain rollback availability")
        let recordedOperationReviewManifest = LatticeExtensionManifest(
            id: "com.lattice.recorded-operation-review",
            name: "Recorded Operation Review",
            version: "1.0.0",
            summary: "Records a roadmap operation.",
            permissions: [.editUI],
            operationPreviews: [.init(targetSurfaceID: "models", operation: .addModelRecommendation, summary: "Add a battery-aware model recommendation.", detail: "Requires a future recommendation schema.")]
        )
        let recordedOperationReview = LatticeExtensionChangeReviewBuilder.review(current: recordedOperationReviewManifest, previous: nil)
        expect(recordedOperationReview.changes == ["Record add model recommendation for models: Add a battery-aware model recommendation. Requires a future recommendation schema."], "Self-edit review shows recorded-only operation changes instead of hiding them")
        expect(recordedOperationReview.acceptanceSummary.contains("does not change Lattice's runtime behavior"), "Self-edit operation-only review explains that Apply records metadata without executing it")
        expect(recordedOperationReview.acceptanceSummary.contains("roll it back"), "Self-edit recorded-only reviews explain rollback availability")
        let executableOperationReviewManifest = LatticeExtensionManifest(
            id: "com.lattice.executable-operation-review",
            name: "Executable Operation Review",
            version: "1.0.0",
            summary: "Adds a skill.",
            permissions: [.editUI],
            skillPatches: [richGeneratedSkill],
            operationPreviews: [.init(targetSurfaceID: "extensions", operation: .addSkill, summary: "Add a reusable review skill.")]
        )
        let executableOperationReview = LatticeExtensionChangeReviewBuilder.review(current: executableOperationReviewManifest, previous: nil)
        expect(executableOperationReview.changes.count == 1 && executableOperationReview.changes.first?.contains("/change-reviewer skill") == true, "Self-edit review hides executable operation preview rows that would duplicate actual skill changes")
        let mixedOperationReviewManifest = LatticeExtensionManifest(
            id: "com.lattice.mixed-operation-review",
            name: "Mixed Operation Review",
            version: "1.0.0",
            summary: "Changes copy and records a model roadmap plan.",
            permissions: [.editUI],
            copyPatches: [.init(target: .promptPlaceholder, text: "Ask Lattice")],
            operationPreviews: [.init(targetSurfaceID: "models", operation: .addModelRecommendation, summary: "Add a calmer default model recommendation.", detail: "Requires a future model recommendation runtime.")]
        )
        let mixedOperationReview = LatticeExtensionChangeReviewBuilder.review(current: mixedOperationReviewManifest, previous: nil)
        expect(mixedOperationReview.changes.contains("Change prompt placeholder text to “Ask Lattice”.") && mixedOperationReview.changes.contains("Record add model recommendation for models: Add a calmer default model recommendation. Requires a future model recommendation runtime."), "Self-edit mixed reviews show both runtime changes and recorded plans")
        expect(mixedOperationReview.acceptanceSummary.contains("runtime changes") && mixedOperationReview.acceptanceSummary.contains("future-operation plan") && mixedOperationReview.acceptanceSummary.contains("Recorded plans do not change Lattice's runtime behavior yet"), "Self-edit mixed reviews separate applied runtime changes from recorded-only plans")
        expect(LatticeSelfEditApplyStatusPolicy.status(for: mixedOperationReviewManifest).contains("future-operation plan") && !LatticeSelfEditApplyStatusPolicy.status(for: mixedOperationReviewManifest).contains("unsupported"), "Self-edit Apply status uses non-technical wording for recorded-only plans")
        expect(LatticeSelfEditApplyStatusPolicy.status(for: recordedOperationReviewManifest).contains("No runtime change was applied"), "Self-edit Apply status explains recorded-only reviews")
        expect(LatticeSelfEditReviewCopy.readyStatus == "Lattice change ready for review." && !LatticeSelfEditReviewCopy.readyStatus.localizedCaseInsensitiveContains("accept") && !LatticeSelfEditReviewCopy.readyStatus.localizedCaseInsensitiveContains("discard"), "Self-edit assistant status stays concise and leaves decisions to the review card")
        expect(LatticeSelfEditReviewDecision.parse("Looks good, accept.") == .accept, "Self-edit review accepts a clear conversational decision")
        expect(LatticeSelfEditReviewDecision.parse("yes, apply it") == .accept, "Self-edit review accepts clear yes/apply wording")
        expect(LatticeSelfEditReviewDecision.parse("please approve this") == .accept, "Self-edit review accepts clear approve wording")
        expect(LatticeSelfEditReviewDecision.parse("go ahead and apply it") == .accept, "Self-edit review accepts clear go-ahead wording")
        expect(LatticeSelfEditReviewDecision.parse("discard this change") == .discard, "Self-edit review discards a clear conversational decision")
        expect(LatticeSelfEditReviewDecision.parse("yes, reject it") == .discard, "Self-edit review discards clear reject wording")
        expect(LatticeSelfEditReviewDecision.parse("throw it away") == .discard, "Self-edit review discards clear throw-away wording")
        expect(LatticeSelfEditReviewDecision.parse("please cancel it") == .discard, "Self-edit review discards clear cancel wording")
        expect(LatticeSelfEditReviewDecision.parse("drop this proposal") == .discard, "Self-edit review discards clear proposal-drop wording")
        expect(LatticeSelfEditReviewDecision.parse("Can you change this part in the plan?") == nil, "Self-edit revision prompts are not mistaken for accept or discard decisions")
        expect(LatticeSelfEditReviewDecision.parse("Please remove the prompt template.") == nil, "Self-edit targeted edit prompts are not mistaken for discard decisions")
        expect(LatticeSelfEditReviewDecision.parse("Do not accept this") == nil, "Self-edit review does not accept ambiguous or negated language")
        expect(LatticeSelfEditReviewDecision.parse("please don't discard this") == nil, "Self-edit review does not discard negated language")
        _ = try! skillStore.writeGeneratedSkill(generatedReviewSkill, ownerExtensionID: "com.lattice.review")
        expect(Set(skillStore.load().map(\.id)) == ["subagents", "review-buddy"], "Generated skills write into Lattice skills folder")
        expect(skillStore.load().first { $0.id == "review-buddy" }?.ownerExtensionID == "com.lattice.review", "Generated extension-owned skills record their owner")
        let skillsWithOwnedReview = skillStore.load()
        if let ownedReviewSkill = skillsWithOwnedReview.first(where: { $0.id == "review-buddy" }) {
            expect(!LatticeSkillActivationPolicy.isEnabled(ownedReviewSkill, disabledSkillIDs: [], enabledExtensionIDs: []), "Disabled owning extension disables its skill")
            expect(LatticeSkillActivationPolicy.isEnabled(ownedReviewSkill, disabledSkillIDs: [], enabledExtensionIDs: ["com.lattice.review"]), "Enabled owning extension activates its skill")
            expect(!LatticeSkillActivationPolicy.isEnabled(ownedReviewSkill, disabledSkillIDs: ["review-buddy"], enabledExtensionIDs: ["com.lattice.review"]), "Explicit skill toggle still overrides enabled owner")
        } else {
            expect(false, "Extension-owned skill activation policy")
        }
        let ownerDisabledSkillIDs = LatticeSkillActivationPolicy.effectiveDisabledSkillIDs(records: skillsWithOwnedReview, disabledSkillIDs: [], enabledExtensionIDs: [])
        expect(ownerDisabledSkillIDs == ["review-buddy"], "Disabled owner only suppresses its owned skills")
        expect(LatticeSkillPromptBuilder.invocation(in: "/review-buddy inspect this", records: skillsWithOwnedReview, disabledSkillIDs: ownerDisabledSkillIDs) == nil, "Disabled extension-owned skill cannot invoke")
        let ownerEnabledSkillIDs = LatticeSkillActivationPolicy.effectiveDisabledSkillIDs(records: skillsWithOwnedReview, disabledSkillIDs: [], enabledExtensionIDs: ["com.lattice.review"])
        expect(LatticeSkillPromptBuilder.invocation(in: "/review-buddy inspect this", records: skillsWithOwnedReview, disabledSkillIDs: ownerEnabledSkillIDs)?.skillID == "review-buddy", "Re-enabled extension restores owned skill invocation")
        let wrongOwnerDeletedSkill = try! skillStore.deleteSkill(id: "review-buddy", ownedByExtensionID: "com.lattice.other")
        expect(!wrongOwnerDeletedSkill && skillStore.load().contains { $0.id == "review-buddy" }, "Wrong extension cannot delete another extension's skill")
        let rightOwnerDeletedSkill = try! skillStore.deleteSkill(id: "review-buddy", ownedByExtensionID: "com.lattice.review")
        expect(rightOwnerDeletedSkill, "Owning extension reports owned skill deletion")
        expect(Set(skillStore.load().map(\.id)) == ["subagents"], "Owning extension can delete its generated skill")
        let existingSkillSnapshot = skillStore.snapshotSkill(id: "subagents")
        let overrideSkill = LatticeSkillPatch(id: "subagents", title: "Subagents Override", summary: "Override.", markdown: "# Subagents Override\n\nOverride.")
        _ = try! skillStore.writeGeneratedSkill(overrideSkill, ownerExtensionID: "com.lattice.override")
        expect(skillStore.load().first?.ownerExtensionID == "com.lattice.override", "Overwritten skill records new owning extension")
        let overrideManifest = LatticeExtensionManifest(
            id: "com.lattice.override",
            name: "Override",
            version: "1.0.0",
            summary: "Overrides a skill.",
            permissions: [.editUI],
            skillPatches: [overrideSkill]
        )
        let overrideManifestData = try! JSONEncoder().encode(overrideManifest)
        let deletionBaselineJob = LatticeExtensionJobRecord(
            sessionID: UUID(),
            harnessThreadID: nil,
            request: "Override subagents",
            manifestID: "com.lattice.override",
            manifestName: "Override",
            summary: "Overrides a skill.",
            previousManifestData: nil,
            previousSkillSnapshots: [existingSkillSnapshot],
            previousDisabledSkillIDs: ["subagents"],
            appliedManifestData: overrideManifestData,
            status: .applied
        )
        let deletionBaseline = LatticeExtensionDeletionRollbackPolicy.baseline(
            manifestID: "com.lattice.override",
            currentManifestData: overrideManifestData,
            jobs: [deletionBaselineJob]
        )
        expect(deletionBaseline?.previousSkillSnapshots == [existingSkillSnapshot], "Extension deletion can recover previous skill snapshots from the matching applied self-edit job")
        expect(deletionBaseline?.previousDisabledSkillIDs == ["subagents"], "Extension deletion can recover previous skill enablement from the matching applied self-edit job")
        expect(LatticeExtensionDeletionRollbackPolicy.baseline(manifestID: "com.lattice.override", currentManifestData: Data("changed".utf8), jobs: [deletionBaselineJob]) == nil, "Extension deletion ignores stale skill rollback baselines after later extension edits")
        try! skillStore.restoreSkill(deletionBaseline!.previousSkillSnapshots[0], removingCurrentIfOwnedBy: "com.lattice.override")
        expect(skillStore.load().first?.source == .importedGlobal && skillStore.load().first?.ownerExtensionID == nil, "Skill snapshot restores previous imported skill")
        let missingSkillSnapshot = skillStore.snapshotSkill(id: "new-skill")
        _ = try! skillStore.writeGeneratedSkill(.init(id: "new-skill", title: "New Skill", summary: "Temporary.", markdown: "# New Skill\n\nTemporary."), ownerExtensionID: "com.lattice.new")
        try! skillStore.restoreSkill(missingSkillSnapshot, removingCurrentIfOwnedBy: "com.lattice.other")
        expect(skillStore.load().contains { $0.id == "new-skill" }, "Skill snapshot restore does not remove wrong owner")
        try! skillStore.restoreSkill(missingSkillSnapshot, removingCurrentIfOwnedBy: "com.lattice.new")
        expect(!skillStore.load().contains { $0.id == "new-skill" }, "Skill snapshot restore removes newly-created owned skill")
        try! skillStore.deleteSkill(id: "subagents")
        expect(skillStore.load().isEmpty, "Imported global skills can be deleted")
        try! skillStore.importGlobalSkills()
        expect(skillStore.load().isEmpty, "Deleted imported global skills do not reappear on refresh")
        _ = try! skillStore.writeGeneratedSkill(.init(id: "subagents", title: "Subagents", summary: "Generated replacement.", markdown: "# Subagents\n\nGenerated replacement."))
        expect(skillStore.load().first?.source == .generated, "Generated skill with deleted import id can be recreated")

        let syncSkillRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let syncGlobalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let syncGlobalFolder = syncGlobalRoot.appendingPathComponent("shared-skill", isDirectory: true)
        let syncGlobalURL = syncGlobalFolder.appendingPathComponent("SKILL.md")
        let syncLocalURL = syncSkillRoot.appendingPathComponent("shared-skill/SKILL.md")
        try! FileManager.default.createDirectory(at: syncGlobalFolder, withIntermediateDirectories: true)
        let syncFirst = Data("# Shared Skill\n\nFirst global version.".utf8)
        let syncSecond = Data("# Shared Skill\n\nSecond global version.".utf8)
        let syncThird = Data("# Shared Skill\n\nThird global version.".utf8)
        let syncLocalEdit = Data("# Shared Skill\n\nLocally customized in Lattice.".utf8)
        try! syncFirst.write(to: syncGlobalURL)
        let syncSkillStore = LatticeSkillStore(rootURL: syncSkillRoot, globalRoots: [syncGlobalRoot])
        try! syncSkillStore.importGlobalSkills()
        try! syncSecond.write(to: syncGlobalURL, options: .atomic)
        try! syncSkillStore.importGlobalSkills()
        expect((try? Data(contentsOf: syncLocalURL)) == syncSecond, "Untouched imported skills synchronize later global SKILL.md updates")
        let syncSnapshot = syncSkillStore.snapshotSkill(id: "shared-skill")
        expect(syncSnapshot.importedBaselineData == syncSecond, "Imported skill snapshots retain their synchronization baseline")
        _ = try! syncSkillStore.writeGeneratedSkill(.init(id: "shared-skill", title: "Temporary", summary: "Temporary override.", markdown: "# Temporary\n\nTemporary override."), ownerExtensionID: "com.lattice.sync")
        try! syncSkillStore.restoreSkill(syncSnapshot, removingCurrentIfOwnedBy: "com.lattice.sync")
        try! syncThird.write(to: syncGlobalURL, options: .atomic)
        try! syncSkillStore.importGlobalSkills()
        expect((try? Data(contentsOf: syncLocalURL)) == syncThird, "Restored imported skills continue synchronizing after an extension override")
        try! syncLocalEdit.write(to: syncLocalURL, options: .atomic)
        try! Data("# Shared Skill\n\nFourth global version.".utf8).write(to: syncGlobalURL, options: .atomic)
        try! syncSkillStore.importGlobalSkills()
        expect((try? Data(contentsOf: syncLocalURL)) == syncLocalEdit, "Global skill synchronization preserves locally edited Lattice copies")
        _ = try! syncSkillStore.writeGeneratedSkill(.init(id: "shared-skill", title: "Generated", summary: "Generated replacement.", markdown: "# Generated\n\nGenerated replacement."))
        try! syncSkillStore.importGlobalSkills()
        expect(syncSkillStore.load().first?.source == .generated && (try? Data(contentsOf: syncLocalURL)) == Data("# Generated\n\nGenerated replacement.".utf8), "Global skill synchronization never overwrites generated replacements")
        try? FileManager.default.removeItem(at: syncSkillRoot)
        try? FileManager.default.removeItem(at: syncGlobalRoot)

        try! extensionStore.restoreExtension(manifestID: replacement.id, previousManifestData: previousData)
        expect(extensionStore.load().first?.version == "1.0.0", "Extension rollback restores previous manifest")
        let mismatchedRollback = LatticeExtensionManifest(id: "com.lattice.other-theme", name: "Other", version: "1.0.0", summary: "Wrong target.")
        do {
            try extensionStore.restoreExtension(manifestID: replacement.id, previousManifestData: JSONEncoder().encode(mismatchedRollback))
            expect(false, "Extension rollback rejects mismatched manifest id")
        } catch {
            expect(error.localizedDescription.contains("does not match"), "Extension rollback rejects mismatched manifest id")
        }
        expect(extensionStore.load().first?.id == manifest.id, "Rejected rollback keeps existing extension manifest")
        try! extensionStore.restoreExtension(manifestID: replacement.id, previousManifestData: nil)
        expect(extensionStore.load().isEmpty, "Extension rollback removes new manifest")
        let jobStore = LatticeExtensionJobStore(fileURL: extensionRoot.appendingPathComponent("self-edit-jobs.json"))
        let job = LatticeExtensionJobRecord(
            sessionID: UUID(),
            harnessThreadID: "thread-1",
            request: "Make Lattice warmer",
            manifestID: replacement.id,
            manifestName: replacement.name,
            summary: replacement.summary,
            previousManifestData: previousData,
            previousDisabledSkillIDs: ["subagents"],
            previousEnabled: false,
            appliedManifestData: Data("applied-manifest".utf8),
            appliedEnabled: true
        )
        let recordedJobs = try! jobStore.record(job, in: [])
        expect(recordedJobs.first?.manifestID == replacement.id, "Self-edit job persisted")
        expect(recordedJobs.first?.previousEnabled == false, "Self-edit job persisted previous enabled state")
        expect(recordedJobs.first?.previousSkillSnapshots.isEmpty == true, "Self-edit job persists empty skill rollback snapshots")
        expect(recordedJobs.first?.previousDisabledSkillIDs == ["subagents"], "Self-edit job persists prior skill enablement")
        expect(recordedJobs.first?.appliedManifestData == Data("applied-manifest".utf8), "Self-edit job persists applied manifest conflict baseline")
        expect(recordedJobs.first?.appliedEnabled == true, "Self-edit job persists applied extension enablement baseline")
        let recordedOnlyJob = LatticeExtensionJobRecord(
            sessionID: UUID(),
            harnessThreadID: nil,
            request: "Move the composer",
            manifestID: "recorded-only",
            manifestName: "Recorded Only",
            summary: "No runtime patch.",
            previousManifestData: nil,
            status: .recorded,
            statusDetail: "Recorded plan."
        )
        expect(recordedOnlyJob.canRollback, "Recorded self-edit plans can be rolled back")
        let jobData = try! JSONEncoder().encode(job)
        var legacyJobObject = try! JSONSerialization.jsonObject(with: jobData) as! [String: Any]
        legacyJobObject.removeValue(forKey: "previousEnabled")
        legacyJobObject.removeValue(forKey: "previousSkillSnapshots")
        legacyJobObject.removeValue(forKey: "previousDisabledSkillIDs")
        legacyJobObject.removeValue(forKey: "appliedManifestData")
        legacyJobObject.removeValue(forKey: "appliedSkillSnapshots")
        legacyJobObject.removeValue(forKey: "appliedEnabled")
        let legacyJobData = try! JSONSerialization.data(withJSONObject: legacyJobObject)
        let legacyJob = try! JSONDecoder().decode(LatticeExtensionJobRecord.self, from: legacyJobData)
        expect(legacyJob.previousEnabled == nil, "Legacy self-edit jobs decode without previous enabled state")
        expect(legacyJob.previousSkillSnapshots.isEmpty, "Legacy self-edit jobs decode without skill snapshots")
        expect(legacyJob.previousDisabledSkillIDs == nil, "Legacy self-edit jobs decode without skill enablement snapshots")
        expect(legacyJob.appliedManifestData == nil && legacyJob.appliedSkillSnapshots.isEmpty, "Legacy self-edit jobs decode without applied conflict baselines")
        expect(legacyJob.appliedEnabled == nil, "Legacy self-edit jobs decode without applied extension enablement baseline")
        let revertedJobs = try! jobStore.markReverted(job.id, detail: "Rolled back", in: recordedJobs)
        expect(revertedJobs.first?.status == .reverted, "Self-edit job rollback persisted")
        let previewStore = LatticeExtensionPreviewStore(fileURL: extensionRoot.appendingPathComponent("self-edit-previews.json"))
        let preview = LatticeExtensionPreviewRecord(
            sessionID: job.sessionID!,
            harnessThreadID: job.harnessThreadID,
            request: "Preview warmer UI",
            manifest: replacement,
            previousManifestData: previousData
        )
        let recordedPreviews = try! previewStore.record(preview, in: [])
        expect(recordedPreviews.first?.manifest == replacement, "Self-edit preview persisted")
        expect(previewStore.load().first?.previousManifestData == previousData, "Self-edit preview rollback baseline persisted")
        let editableManifest = LatticeExtensionManifest(
            id: "com.lattice.skills",
            name: "Lattice Skills",
            version: "1",
            summary: "Adds skills.",
            permissions: [.editUI],
            stylePatches: [.init(target: .composer, tintHex: "#223344", accentHex: "#8899AA", cornerRadius: 18)],
            layoutPatches: [.init(target: .composer, density: .compact)],
            copyPatches: [.init(target: .promptPlaceholder, text: "Ask Lattice")],
            promptTemplates: [.init(invocation: "/review", title: "Review", detail: "Review a change", prompt: "Review this change.")],
            skillPatches: [
                .init(id: "review-buddy", title: "Review Buddy", summary: "Review changes.", markdown: "# Review Buddy\n\nReview patches for risk."),
                .init(id: "subagents", title: "Subagents", summary: "Use helpers.", markdown: "# Subagents\n\nUse helper agents.")
            ],
            operationPreviews: [.init(targetSurfaceID: "extensions", operation: .addSkill, summary: "Add skills.", detail: "Creates reusable skills.")]
        )
        let editablePreview = LatticeExtensionPreviewRecord(
            sessionID: job.sessionID!,
            harnessThreadID: job.harnessThreadID,
            request: "Add better skills",
            manifest: editableManifest,
            previousManifestData: previousData,
            previousSkillSnapshots: [
                .init(id: "review-buddy", skillData: nil, sourceRaw: nil, originalPath: nil, ownerExtensionID: nil, wasDeletedGlobalSkill: false),
                .init(id: "subagents", skillData: nil, sourceRaw: nil, originalPath: nil, ownerExtensionID: nil, wasDeletedGlobalSkill: false)
            ],
            previousDisabledSkillIDs: ["review-buddy"],
            previousEnabled: false,
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let editedMetadataPreview = LatticeExtensionPreviewEditor.replacingMetadata(
            in: editablePreview,
            name: "Better Skills",
            version: "1.1.0",
            summary: "Adds reviewed reusable skills."
        )
        let metadataIdentityPreserved = editedMetadataPreview.id == editablePreview.id && editedMetadataPreview.sessionID == editablePreview.sessionID
        expect(metadataIdentityPreserved, "Self-edit metadata preview edits preserve preview identity")
        let metadataRollbackBaselinesPreserved = editedMetadataPreview.previousManifestData == previousData && editedMetadataPreview.previousSkillSnapshots == editablePreview.previousSkillSnapshots
        expect(metadataRollbackBaselinesPreserved, "Self-edit metadata preview edits preserve rollback baselines")
        let metadataEnablementBaselinesPreserved = editedMetadataPreview.previousDisabledSkillIDs == ["review-buddy"] && editedMetadataPreview.previousEnabled == false && editedMetadataPreview.createdAt == editablePreview.createdAt
        expect(metadataEnablementBaselinesPreserved, "Self-edit metadata preview edits preserve enablement baselines")
        expect(editedMetadataPreview.manifest.id == editableManifest.id, "Self-edit metadata preview edits preserve manifest id")
        expect(editedMetadataPreview.manifest.name == "Better Skills", "Self-edit metadata preview edits replace name")
        expect(editedMetadataPreview.manifest.version == "1.1.0", "Self-edit metadata preview edits replace version")
        expect(editedMetadataPreview.manifest.summary == "Adds reviewed reusable skills.", "Self-edit metadata preview edits replace summary")
        expect(editedMetadataPreview.manifest.skillPatches == editableManifest.skillPatches, "Self-edit metadata preview edits leave skill patches unchanged")
        let metadataReview = LatticeExtensionChangeReviewBuilder.review(current: editedMetadataPreview.manifest, previous: editableManifest)
        expect(
            metadataReview.changes.contains("Rename the extension to “Better Skills”.")
                && metadataReview.changes.contains("Update the extension version to 1.1.0.")
                && metadataReview.changes.contains("Update the extension summary to “Adds reviewed reusable skills.”."),
            "Self-edit review lists extension metadata updates instead of applying hidden visible changes"
        )
        let editedStylePreview = try! LatticeExtensionPreviewEditor.replacingStylePatch(
            in: editablePreview,
            index: 0,
            tintHex: "#334455",
            accentHex: "#AABBCC",
            cornerRadius: 24
        )
        expect(editedStylePreview.previousManifestData == editablePreview.previousManifestData, "Self-edit style preview edits preserve manifest rollback baseline")
        expect(editedStylePreview.manifest.stylePatches[0].tintHex == "#334455", "Self-edit style preview edits replace tint")
        expect(editedStylePreview.manifest.stylePatches[0].accentHex == "#AABBCC", "Self-edit style preview edits replace accent")
        expect(editedStylePreview.manifest.stylePatches[0].cornerRadius == 24, "Self-edit style preview edits replace corner radius")
        expect(editedStylePreview.manifest.layoutPatches == editableManifest.layoutPatches, "Self-edit style preview edits leave layout patches unchanged")
        let editedLayoutPreview = try! LatticeExtensionPreviewEditor.replacingLayoutPatch(in: editablePreview, index: 0, density: .spacious)
        expect(editedLayoutPreview.previousSkillSnapshots == editablePreview.previousSkillSnapshots, "Self-edit layout preview edits preserve skill rollback baselines")
        expect(editedLayoutPreview.manifest.layoutPatches[0].density == .spacious, "Self-edit layout preview edits replace density")
        expect(editedLayoutPreview.manifest.stylePatches == editableManifest.stylePatches, "Self-edit layout preview edits leave style patches unchanged")
        let editedCopyPreview = try! LatticeExtensionPreviewEditor.replacingCopyPatch(in: editablePreview, target: .promptPlaceholder, text: "Ask calmly")
        expect(editedCopyPreview.previousSkillSnapshots == editablePreview.previousSkillSnapshots, "Self-edit copy preview edits preserve skill rollback baselines")
        expect(editedCopyPreview.previousDisabledSkillIDs == ["review-buddy"], "Self-edit copy preview edits preserve skill enablement baselines")
        expect(editedCopyPreview.manifest.copyPatches.first { $0.target == .promptPlaceholder }?.text == "Ask calmly", "Self-edit copy preview edits replace selected copy")
        expect(editedCopyPreview.manifest.promptTemplates == editableManifest.promptTemplates, "Self-edit copy preview edits leave templates unchanged")
        let editedTemplatePreview = try! LatticeExtensionPreviewEditor.replacingPromptTemplate(
            in: editablePreview,
            originalInvocation: "/review",
            invocation: "/careful-review",
            title: "Careful Review",
            detail: "Review for risk",
            prompt: "Review this change for correctness and risk."
        )
        expect(editedTemplatePreview.previousManifestData == editablePreview.previousManifestData, "Self-edit template preview edits preserve manifest rollback baseline")
        expect(editedTemplatePreview.manifest.promptTemplates.first?.invocation == "/careful-review", "Self-edit template preview edits replace invocation")
        expect(editedTemplatePreview.manifest.promptTemplates.first?.title == "Careful Review", "Self-edit template preview edits replace title")
        expect(editedTemplatePreview.manifest.copyPatches == editableManifest.copyPatches, "Self-edit template preview edits leave copy patches unchanged")
        let editedOperationPreview = try! LatticeExtensionPreviewEditor.replacingOperationPreview(
            in: editablePreview,
            index: 0,
            summary: "Add safer reusable skills.",
            detail: "Creates skill commands after Apply."
        )
        expect(editedOperationPreview.previousEnabled == false, "Self-edit operation preview edits preserve extension enablement baseline")
        expect(editedOperationPreview.manifest.operationPreviews[0].summary == "Add safer reusable skills.", "Self-edit operation preview edits replace summary")
        expect(editedOperationPreview.manifest.operationPreviews[0].detail == "Creates skill commands after Apply.", "Self-edit operation preview edits replace detail")
        expect(editedOperationPreview.manifest.skillPatches == editableManifest.skillPatches, "Self-edit operation preview edits leave skill patches unchanged")
        let editedPreview = try! LatticeExtensionPreviewEditor.replacingSkillPatch(
            in: editablePreview,
            skillID: "review-buddy",
            title: "Careful Reviewer",
            summary: "Review patches carefully.",
            markdown: "# Careful Reviewer\n\nCheck risks and edge cases."
        )
        let previewIdentityPreserved = editedPreview.id == editablePreview.id && editedPreview.sessionID == editablePreview.sessionID
        expect(previewIdentityPreserved, "Self-edit skill preview edits preserve preview identity")
        let rollbackBaselinesPreserved = editedPreview.previousManifestData == previousData && editedPreview.previousSkillSnapshots == editablePreview.previousSkillSnapshots
        expect(rollbackBaselinesPreserved, "Self-edit skill preview edits preserve rollback baselines")
        let enablementBaselinesPreserved = editedPreview.previousDisabledSkillIDs == ["review-buddy"] && editedPreview.previousEnabled == false && editedPreview.createdAt == editablePreview.createdAt
        expect(enablementBaselinesPreserved, "Self-edit skill preview edits preserve enablement baselines")
        expect(editedPreview.manifest.skillPatches.first { $0.id == "review-buddy" }?.title == "Careful Reviewer", "Self-edit skill preview edits replace selected skill title")
        expect(editedPreview.manifest.skillPatches.first { $0.id == "review-buddy" }?.markdown.contains("edge cases") == true, "Self-edit skill preview edits replace selected skill markdown")
        expect(editedPreview.manifest.skillPatches.first { $0.id == "subagents" } == editableManifest.skillPatches[1], "Self-edit skill preview edits leave other skills unchanged")
        do {
            _ = try LatticeExtensionPreviewEditor.replacingSkillPatch(in: editablePreview, skillID: "missing", title: "Missing", summary: "", markdown: "# Missing")
            expect(false, "Self-edit skill preview edit rejects missing skill")
        } catch {
            expect(true, "Self-edit skill preview edit rejects missing skill")
        }
        do {
            _ = try LatticeExtensionPreviewEditor.replacingStylePatch(in: editablePreview, index: 9, tintHex: nil, accentHex: nil, cornerRadius: nil)
            expect(false, "Self-edit style preview edit rejects missing style patch")
        } catch {
            expect(true, "Self-edit style preview edit rejects missing style patch")
        }
        do {
            _ = try LatticeExtensionPreviewEditor.replacingLayoutPatch(in: editablePreview, index: 9, density: .comfortable)
            expect(false, "Self-edit layout preview edit rejects missing layout patch")
        } catch {
            expect(true, "Self-edit layout preview edit rejects missing layout patch")
        }
        do {
            _ = try LatticeExtensionPreviewEditor.replacingCopyPatch(in: editablePreview, target: .askButton, text: "Ask")
            expect(false, "Self-edit copy preview edit rejects missing copy patch")
        } catch {
            expect(true, "Self-edit copy preview edit rejects missing copy patch")
        }
        do {
            _ = try LatticeExtensionPreviewEditor.replacingPromptTemplate(in: editablePreview, originalInvocation: "/missing", invocation: "/missing", title: "Missing", detail: "", prompt: "Missing")
            expect(false, "Self-edit template preview edit rejects missing template")
        } catch {
            expect(true, "Self-edit template preview edit rejects missing template")
        }
        do {
            _ = try LatticeExtensionPreviewEditor.replacingOperationPreview(in: editablePreview, index: 9, summary: "Missing", detail: "")
            expect(false, "Self-edit operation preview edit rejects missing operation")
        } catch {
            expect(true, "Self-edit operation preview edit rejects missing operation")
        }
        let enabledPreview = LatticeExtensionPreviewRecord(
            sessionID: job.sessionID!,
            harnessThreadID: job.harnessThreadID,
            request: "Preview enabled warmer UI",
            manifest: replacement,
            previousManifestData: previousData,
            previousDisabledSkillIDs: ["subagents"],
            previousEnabled: true
        )
        let enabledPreviewData = try! JSONEncoder().encode(enabledPreview)
        expect((try! JSONDecoder().decode(LatticeExtensionPreviewRecord.self, from: enabledPreviewData)).previousEnabled == true, "Self-edit preview persists previous enabled state")
        expect((try! JSONDecoder().decode(LatticeExtensionPreviewRecord.self, from: enabledPreviewData)).previousDisabledSkillIDs == ["subagents"], "Self-edit preview persists prior skill enablement")
        var legacyPreviewObject = try! JSONSerialization.jsonObject(with: enabledPreviewData) as! [String: Any]
        legacyPreviewObject.removeValue(forKey: "previousEnabled")
        legacyPreviewObject.removeValue(forKey: "previousSkillSnapshots")
        legacyPreviewObject.removeValue(forKey: "previousDisabledSkillIDs")
        let legacyPreviewData = try! JSONSerialization.data(withJSONObject: legacyPreviewObject)
        expect((try! JSONDecoder().decode(LatticeExtensionPreviewRecord.self, from: legacyPreviewData)).previousEnabled == nil, "Legacy self-edit previews decode without previous enabled state")
        expect((try! JSONDecoder().decode(LatticeExtensionPreviewRecord.self, from: legacyPreviewData)).previousSkillSnapshots.isEmpty, "Legacy self-edit previews decode without skill snapshots")
        expect((try! JSONDecoder().decode(LatticeExtensionPreviewRecord.self, from: legacyPreviewData)).previousDisabledSkillIDs == nil, "Legacy self-edit previews decode without skill enablement snapshots")
        let priorDisabledSkills = LatticeSkillEnablementRollbackPolicy.disabledSnapshot(affectedSkillIDs: ["subagents", "review"], disabledSkillIDs: ["subagents", "unrelated"])
        expect(priorDisabledSkills == ["subagents"], "Self-edit captures only affected disabled skills")
        let restoredDisabledSkills = LatticeSkillEnablementRollbackPolicy.restoredDisabledIDs(current: ["review", "unrelated"], affectedSkillIDs: ["subagents", "review"], previousDisabledSkillIDs: Set(priorDisabledSkills))
        expect(restoredDisabledSkills == ["subagents", "unrelated"], "Self-edit rollback restores affected skill enablement without changing unrelated skills")
        let clearedPreviews = try! previewStore.remove(preview.id, from: recordedPreviews)
        expect(clearedPreviews.isEmpty, "Self-edit preview decision persisted")
        let invalid = LatticeExtensionManifest(id: "../bad", name: "Bad", version: "1", summary: "", permissions: [.writeWorkspace], entrypoint: "../run.sh")
        expect(!extensionStore.validate(invalid).isEmpty, "Unsafe extension rejected")
        let emptyEntrypoint = LatticeExtensionManifest(id: "empty-entrypoint", name: "Empty Entrypoint", version: "1", summary: "", entrypoint: "")
        expect(extensionStore.validate(emptyEntrypoint).isEmpty, "Empty extension entrypoint remains equivalent to unset")
        let whitespaceEntrypoint = LatticeExtensionManifest(id: "whitespace-entrypoint", name: "Whitespace Entrypoint", version: "1", summary: "", entrypoint: " run.js ")
        expect(extensionStore.validate(whitespaceEntrypoint).contains("Entrypoint must not have leading or trailing whitespace."), "Extension entrypoint rejects surrounding whitespace")
        let multilineEntrypoint = LatticeExtensionManifest(id: "multiline-entrypoint", name: "Multiline Entrypoint", version: "1", summary: "", entrypoint: "run\n.js")
        expect(extensionStore.validate(multilineEntrypoint).contains("Entrypoint must be one line."), "Extension entrypoint rejects newlines")
        let escapingEntrypoint = LatticeExtensionManifest(id: "escaping-entrypoint", name: "Escaping Entrypoint", version: "1", summary: "", entrypoint: "scripts/../run.js")
        expect(extensionStore.validate(escapingEntrypoint).contains("Entrypoint must stay inside the extension bundle."), "Extension entrypoint rejects path traversal")
        let badStyle = LatticeExtensionManifest(id: "bad-style", name: "Bad Style", version: "1", summary: "", permissions: [], stylePatches: [.init(target: .composer, tintHex: "nope")])
        expect(extensionStore.validate(badStyle).count >= 2, "Unsafe style rejected")
        let badLayout = LatticeExtensionManifest(id: "bad-layout", name: "Bad Layout", version: "1", summary: "", layoutPatches: [.init(target: .composer, density: .compact)])
        expect(extensionStore.validate(badLayout).contains("Layout patches require Edit UI permission."), "Layout patches require edit permission")
        let badLayoutTarget = LatticeExtensionManifest(id: "bad-layout-target", name: "Bad Layout Target", version: "1", summary: "", permissions: [.editUI], uiTargets: ["overlay"], layoutPatches: [.init(target: .composer, density: .compact)])
        expect(extensionStore.validate(badLayoutTarget).contains("Composer layout patches require composer in uiTargets."), "Layout patches require matching UI target")
        let badCopy = LatticeExtensionManifest(id: "bad-copy", name: "Bad Copy", version: "1", summary: "", copyPatches: [.init(target: .promptPlaceholder, text: " Ask\n")])
        expect(extensionStore.validate(badCopy).contains("Copy patches require Edit UI permission."), "Copy patches require edit permission")
        expect(extensionStore.validate(badCopy).contains { $0.contains("must be one line") }, "Unsafe copy patch rejected")
        let templateOnly = LatticeExtensionManifest(id: "template", name: "Template", version: "1", summary: "", permissions: [.editUI], promptTemplates: [.init(invocation: "/brief", title: "Brief", prompt: "Make this concise.")])
        expect(templateOnly.hasRuntimePatches, "Prompt-template-only extension has runtime patches")
        let badTemplate = LatticeExtensionManifest(id: "bad-template", name: "Bad Template", version: "1", summary: "", permissions: [.editUI], promptTemplates: [.init(invocation: "/self-edit", title: "", prompt: "")])
        let badTemplateMessages = extensionStore.validate(badTemplate)
        expect(badTemplateMessages.contains { $0.contains("cannot replace /self-edit") }, "Prompt template cannot replace self-edit")
        expect(badTemplateMessages.contains { $0.contains("prompt is empty") }, "Prompt template prompt is required")
        let collidingTemplateSkill = LatticeExtensionManifest(
            id: "template-skill-collision",
            name: "Template Skill Collision",
            version: "1",
            summary: "",
            permissions: [.editUI],
            promptTemplates: [.init(invocation: "/brief", title: "Brief", prompt: "Make this concise.")],
            skillPatches: [.init(id: "brief", title: "Brief Skill", summary: "Use a skill.", markdown: "# Brief Skill\n\nUse a skill.")]
        )
        expect(extensionStore.validate(collidingTemplateSkill).contains { $0.contains("conflicts with prompt template /brief") }, "Extension rejects prompt template and skill slash-command collisions")
        let messyTemplate = LatticeExtensionManifest(id: "messy-template", name: "Messy Template", version: "1", summary: "", permissions: [.editUI], promptTemplates: [.init(invocation: "/messy", title: " Messy\nTitle ", detail: " Detail\nmetadata ", prompt: "Line one\nLine two")])
        let messyTemplateMessages = extensionStore.validate(messyTemplate)
        expect(messyTemplateMessages.contains("Prompt template /messy title must not have leading or trailing whitespace."), "Prompt template title rejects surrounding whitespace")
        expect(messyTemplateMessages.contains("Prompt template /messy title must be one line."), "Prompt template title rejects newlines")
        expect(messyTemplateMessages.contains("Prompt template /messy detail must not have leading or trailing whitespace."), "Prompt template detail rejects surrounding whitespace")
        expect(messyTemplateMessages.contains("Prompt template /messy detail must be one line."), "Prompt template detail rejects newlines")
        let badOperation = LatticeExtensionManifest(id: "bad-operation", name: "Bad Operation", version: "1", summary: "", operationPreviews: [.init(targetSurfaceID: "models", operation: .addControl, summary: "Add a button where controls are unsupported.")])
        expect(!badOperation.hasRuntimePatches, "Operation-preview-only extension has no runtime patches")
        expect(extensionStore.validate(badOperation).contains { $0.contains("Add control is not supported on Models") }, "Unsupported operation preview rejected")
        let missingOperationPermissions = LatticeExtensionManifest(
            id: "missing-operation-permissions",
            name: "Missing Operation Permissions",
            version: "1",
            summary: "Missing permissions.",
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .relayout, summary: "Move composer."),
                .init(targetSurfaceID: "extensions", operation: .addAutomation, summary: "Add morning brief.")
            ]
        )
        let missingOperationPermissionMessages = extensionStore.validate(missingOperationPermissions)
        expect(missingOperationPermissionMessages.contains("Relayout operation previews require Edit UI permission."), "Relayout preview requires edit permission")
        expect(missingOperationPermissionMessages.contains("Add automation operation previews require Edit UI permission."), "Automation preview requires edit permission")
        expect(missingOperationPermissionMessages.contains("Add automation operation previews require Automation permission."), "Automation preview requires automation permission")
        let permittedOperation = LatticeExtensionManifest(id: "permitted-operation", name: "Permitted Operation", version: "1", summary: "Permitted.", permissions: [.editUI], operationPreviews: [.init(targetSurfaceID: "composer", operation: .relayout, summary: "Move composer.")])
        expect(extensionStore.validate(permittedOperation).isEmpty, "Declared operation preview permission accepted")
        expect(LatticeExtensionOperationRuntimePolicy.execution(for: permittedOperation.operationPreviews[0], in: permittedOperation) == .recordedOnly, "Unsupported operation preview remains recorded-only")
        let executableRestyleOperation = LatticeExtensionManifest(
            id: "executable-restyle",
            name: "Executable Restyle",
            version: "1",
            summary: "",
            permissions: [.editUI],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF")],
            operationPreviews: [.init(targetSurfaceID: "composer", operation: .restyle, summary: "Tint the composer.")]
        )
        expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableRestyleOperation.operationPreviews[0], in: executableRestyleOperation) == .executable, "Restyle operation is executable when backed by a matching style patch")
        let executableLayoutOperation = LatticeExtensionManifest(
            id: "executable-layout",
            name: "Executable Layout",
            version: "1",
            summary: "",
            permissions: [.editUI],
            uiTargets: ["composer"],
            layoutPatches: [.init(target: .composer, density: .compact)],
            operationPreviews: [.init(targetSurfaceID: "composer", operation: .relayout, summary: "Make the composer compact.")]
        )
        expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableLayoutOperation.operationPreviews[0], in: executableLayoutOperation) == .executable, "Relayout operation is executable when backed by a composer layout patch")
        let executableCopyOperation = LatticeExtensionManifest(
            id: "executable-copy",
            name: "Executable Copy",
            version: "1",
            summary: "",
            permissions: [.editUI],
            copyPatches: [.init(target: .askButton, text: "Ask softly")],
            operationPreviews: [.init(targetSurfaceID: "overlay", operation: .rewriteCopy, summary: "Rename the ask button.")]
        )
        expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableCopyOperation.operationPreviews[0], in: executableCopyOperation) == .executable, "Rewrite-copy operation is executable when backed by copy patches")
        let executableControlOperation = LatticeExtensionManifest(
            id: "executable-control",
            name: "Executable Control",
            version: "1",
            summary: "",
            permissions: [.editUI],
            promptTemplates: [.init(invocation: "/calm", title: "Calm", prompt: "Make this calmer.")],
            operationPreviews: [.init(targetSurfaceID: "composer", operation: .addControl, summary: "Add a calm prompt command.")]
        )
        expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableControlOperation.operationPreviews[0], in: executableControlOperation) == .executable, "Add-control operation is executable when backed by a prompt template")
        let executableSkillOperation = LatticeExtensionManifest(
            id: "executable-skill",
            name: "Executable Skill",
            version: "1",
            summary: "",
            permissions: [.editUI],
            skillPatches: [.init(id: "subagents", title: "Subagents", summary: "Use helper agents.", markdown: "# Subagents\n\nUse helper agents.")],
            operationPreviews: [.init(targetSurfaceID: "extensions", operation: .addSkill, summary: "Add a subagents skill.")]
        )
        expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableSkillOperation.operationPreviews[0], in: executableSkillOperation) == .executable, "Add-skill operation is executable when backed by a skill patch")
        expect(LatticeExtensionOperationRuntimePolicy.executableOperationCount(in: executableControlOperation) == 1 && LatticeExtensionOperationRuntimePolicy.recordedOnlyOperationCount(in: executableControlOperation) == 0, "Operation runtime policy counts executable previews")
        let badOperationTarget = LatticeExtensionManifest(id: "bad-operation-target", name: "Bad Operation Target", version: "1", summary: "", operationPreviews: [.init(targetSurfaceID: " composer\n", operation: .relayout, summary: "Move composer.")])
        let badOperationTargetMessages = extensionStore.validate(badOperationTarget)
        expect(badOperationTargetMessages.contains { $0.contains("must not have leading or trailing whitespace") }, "Operation preview target rejects surrounding whitespace")
        expect(badOperationTargetMessages.contains("Operation preview target must be one line."), "Operation preview target rejects newlines")
        let badOperationText = LatticeExtensionManifest(id: "bad-operation-text", name: "Bad Operation Text", version: "1", summary: "", operationPreviews: [.init(targetSurfaceID: "composer", operation: .relayout, summary: " Move\ncomposer ", detail: " Details\nhere ")])
        let badOperationTextMessages = extensionStore.validate(badOperationText)
        expect(badOperationTextMessages.contains("Operation preview summary for Composer must not have leading or trailing whitespace."), "Operation preview summary rejects surrounding whitespace")
        expect(badOperationTextMessages.contains("Operation preview summary for Composer must be one line."), "Operation preview summary rejects newlines")
        expect(badOperationTextMessages.contains("Operation preview detail for Composer must not have leading or trailing whitespace."), "Operation preview detail rejects surrounding whitespace")
        expect(badOperationTextMessages.contains("Operation preview detail for Composer must be one line."), "Operation preview detail rejects newlines")
        let duplicatePatchTargets = LatticeExtensionManifest(
            id: "duplicate-patch-targets",
            name: "Duplicate Patch Targets",
            version: "1",
            summary: "",
            permissions: [.editUI],
            stylePatches: [
                .init(target: .composer, tintHex: "#223344"),
                .init(target: .composer, accentHex: "#8899AA")
            ],
            layoutPatches: [
                .init(target: .composer, density: .compact),
                .init(target: .composer, density: .comfortable)
            ],
            copyPatches: [
                .init(target: .askButton, text: "Ask"),
                .init(target: .askButton, text: "Ask again")
            ],
            operationPreviews: [
                .init(targetSurfaceID: "models", operation: .addModelRecommendation, summary: "Add recommendation one."),
                .init(targetSurfaceID: "models", operation: .addModelRecommendation, summary: "Add recommendation two.")
            ]
        )
        let duplicatePatchMessages = extensionStore.validate(duplicatePatchTargets)
        expect(duplicatePatchMessages.contains("Duplicate style patch target: composer."), "Duplicate style patch targets are rejected before review")
        expect(duplicatePatchMessages.contains("Duplicate layout patch target: composer."), "Duplicate layout patch targets are rejected before review")
        expect(duplicatePatchMessages.contains("Duplicate copy patch target: askButton."), "Duplicate copy patch targets are rejected before review")
        expect(duplicatePatchMessages.contains("Duplicate operation preview for models Add model recommendation."), "Duplicate operation preview keys are rejected before review")
        let duplicateCurrentReview = LatticeExtensionManifest(
            id: "duplicate-review-defensive",
            name: "Duplicate Review Defensive",
            version: "1",
            summary: "",
            permissions: [.editUI],
            copyPatches: [
                .init(target: .askButton, text: "Ask softly"),
                .init(target: .askButton, text: "Ask calmer")
            ]
        )
        expect(!LatticeExtensionChangeReviewBuilder.review(current: duplicateCurrentReview, previous: nil).changes.isEmpty, "Self-edit review diff remains defensive for malformed duplicate-key manifests")
        let badTargets = LatticeExtensionManifest(id: "bad-targets", name: "Bad Targets", version: "1", summary: "", uiTargets: [" composer", "spaceship", "composer"])
        let badTargetMessages = extensionStore.validate(badTargets)
        expect(badTargetMessages.contains { $0.contains("must not have leading or trailing whitespace") }, "UI target rejects surrounding whitespace")
        expect(badTargetMessages.contains("Unknown UI target: spaceship."), "Unknown UI target rejected")
        expect(badTargetMessages.contains("Duplicate UI target: composer."), "Duplicate UI target rejected")
        let runtimeRecord = LatticeExtensionRecord(
            id: "runtime",
            name: "Runtime",
            version: "1",
            summary: "Has runtime patches.",
            permissions: [.editUI],
            uiTargets: [],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF")],
            manifestURL: extensionRoot.appendingPathComponent("runtime"),
            bundleURL: extensionRoot.appendingPathComponent("runtime"),
            validationMessages: []
        )
        let layoutRuntimeRecord = LatticeExtensionRecord(
            id: "layout-runtime",
            name: "Layout Runtime",
            version: "1",
            summary: "Has layout runtime patches.",
            permissions: [.editUI],
            uiTargets: ["composer"],
            layoutPatches: [.init(target: .composer, density: .compact)],
            manifestURL: extensionRoot.appendingPathComponent("layout-runtime"),
            bundleURL: extensionRoot.appendingPathComponent("layout-runtime"),
            validationMessages: []
        )
        let previewOnlyRecord = LatticeExtensionRecord(
            id: "preview",
            name: "Preview",
            version: "1",
            summary: "Preview-only.",
            permissions: [],
            uiTargets: [],
            operationPreviews: [.init(targetSurfaceID: "composer", operation: .relayout, summary: "Move composer.")],
            manifestURL: extensionRoot.appendingPathComponent("preview"),
            bundleURL: extensionRoot.appendingPathComponent("preview"),
            validationMessages: []
        )
        let invalidRuntimeRecord = LatticeExtensionRecord(
            id: "invalid",
            name: "Invalid",
            version: "1",
            summary: "Invalid runtime.",
            permissions: [.editUI],
            uiTargets: [],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF")],
            manifestURL: extensionRoot.appendingPathComponent("invalid"),
            bundleURL: extensionRoot.appendingPathComponent("invalid"),
            validationMessages: ["Invalid"]
        )
        let enablement = LatticeExtensionEnablementPolicy.refresh(
            records: [runtimeRecord, layoutRuntimeRecord, previewOnlyRecord, invalidRuntimeRecord],
            storedEnabledIDs: ["preview", "invalid", "missing"],
            knownIDs: []
        )
        expect(enablement.enabledIDs.isEmpty, "First-seen runtime extensions stay disabled until explicitly applied")
        expect(enablement.knownIDs == ["layout-runtime", "runtime"], "Extension known set tracks valid runtime extensions")
        let explicitlyAppliedEnablement = LatticeExtensionEnablementPolicy.refresh(
            records: [runtimeRecord],
            storedEnabledIDs: ["runtime"],
            knownIDs: []
        )
        expect(explicitlyAppliedEnablement.enabledIDs == ["runtime"], "Explicitly applied runtime extension remains enabled")
        let disabledKnownEnablement = LatticeExtensionEnablementPolicy.refresh(
            records: [runtimeRecord],
            storedEnabledIDs: [],
            knownIDs: ["runtime", "formerly-invalid"]
        )
        expect(disabledKnownEnablement.enabledIDs.isEmpty, "Known disabled runtime extension stays disabled on refresh")
        expect(disabledKnownEnablement.knownIDs == ["runtime", "formerly-invalid"], "Known extension IDs survive invalid or missing refreshes")
        let selfMap = LatticeSelfMap()
        expect(selfMap.surfaces.contains { $0.id == "overlay" && $0.operations.contains(.restyle) }, "Self map overlay")

        // Conversation scroll + per-session new-content awareness / Jump to Latest.
        let scrollNear = ConversationScrollMetrics(contentOffsetY: 900, containerHeight: 400, contentHeight: 1_300)
        let scrollBrowse = ConversationScrollMetrics(contentOffsetY: 120, containerHeight: 400, contentHeight: 1_300)
        expect(ConversationScrollPolicy.tailSentinelID == "lattice.conversation.scroll.tail", "Scroll tail sentinel id is stable")
        let scrollMessageID = UUID()
        let scrollInitial = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            lastMessageCharacterCount: 10,
            lastMessageRevision: 1,
            lastMessageIsUser: false,
            isStreaming: true
        )
        let scrollFirstEstablish = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse),
            content: scrollInitial,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        )
        expect(scrollFirstEstablish.command == .none && scrollFirstEstablish.state.pendingNewContentCount == 0, "Initial scroll snapshot does not invent pending new content")
        let scrollDelta = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            lastMessageCharacterCount: 80,
            lastMessageRevision: 2,
            lastMessageIsUser: false,
            isStreaming: true
        )
        let scrollStreaming = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(
                isFollowingTail: false,
                metrics: scrollBrowse,
                preservedOffsetY: scrollBrowse.contentOffsetY,
                contentSnapshot: scrollInitial
            ),
            content: scrollDelta,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        )
        expect(scrollStreaming.command == .none, "Streaming while browsing does not move the viewport")
        expect(scrollStreaming.state.pendingNewContentCount == 1, "Streaming while browsing increments one logical update")
        expect(ConversationScrollPolicy.logicalNewContentIncrement(from: scrollInitial, to: scrollDelta, changeKind: .bottomTailGrowth) == 1, "Streamed delta is one logical update, not a character count")
        let scrollFollowing = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: true, metrics: scrollNear, contentSnapshot: scrollInitial),
            content: scrollDelta,
            measuredMetrics: scrollNear,
            reduceMotion: false
        )
        expect(scrollFollowing.command == .followTail(animated: false) && scrollFollowing.state.pendingNewContentCount == 0, "Streaming while following keeps zero pending and follows tail")
        let scrollAssistant = ConversationScrollContentSnapshot(messageCount: 3, lastMessageID: UUID(), lastMessageCharacterCount: 12, lastMessageIsUser: false)
        let scrollAssistantResult = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, contentSnapshot: ConversationScrollContentSnapshot(messageCount: 2, lastMessageIsUser: false)),
            content: scrollAssistant,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        )
        expect(scrollAssistantResult.state.pendingNewContentCount == 1 && scrollAssistantResult.command == .none, "Assistant append while browsing increments pending without scrolling")
        let scrollPermission = ConversationScrollContentSnapshot(messageCount: 2, lastMessageIsUser: false, hasPermissionNotice: true, permissionNoticeID: UUID())
        expect(ConversationScrollPolicy.classifyContentChange(from: ConversationScrollContentSnapshot(messageCount: 2), to: scrollPermission) == .bottomTailGrowth, "Permission row is bottom-tail growth")
        expect(ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, contentSnapshot: ConversationScrollContentSnapshot(messageCount: 2)),
            content: scrollPermission,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        ).state.pendingNewContentCount == 1, "Permission row while browsing increments pending")
        let scrollError = ConversationScrollContentSnapshot(messageCount: 2, lastMessageIsUser: false, hasVisibleError: true, visibleErrorRevision: 3)
        expect(ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, contentSnapshot: ConversationScrollContentSnapshot(messageCount: 2)),
            content: scrollError,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        ).state.pendingNewContentCount == 1, "Visible error row while browsing increments pending")
        let scrollSelfEdit = ConversationScrollContentSnapshot(messageCount: 2, lastMessageIsUser: false, selfEditPreviewCount: 1, selfEditPreviewRevision: 1)
        expect(ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, contentSnapshot: ConversationScrollContentSnapshot(messageCount: 2)),
            content: scrollSelfEdit,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        ).state.pendingNewContentCount == 1, "Self-edit preview while browsing increments pending")
        let scrollTailActivityPrevious = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            activityCount: 1,
            activityCharacterCount: 10,
            activityRevision: 1,
            tailActivityCount: 0,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 10,
            aboveActivityRevision: 1
        )
        let scrollTailActivityNext = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            activityCount: 2,
            activityCharacterCount: 40,
            activityRevision: 2,
            tailActivityCount: 1,
            tailActivityCharacterCount: 30,
            tailActivityRevision: 2,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 10,
            aboveActivityRevision: 1
        )
        expect(ConversationScrollPolicy.classifyContentChange(from: scrollTailActivityPrevious, to: scrollTailActivityNext) == .bottomTailGrowth, "Tail tool/action arrival is bottom-tail growth")
        expect(ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, contentSnapshot: scrollTailActivityPrevious),
            content: scrollTailActivityNext,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        ).state.pendingNewContentCount == 1, "Tail tool/action arrival while browsing increments pending")
        let scrollAboveActivityNext = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            activityCount: 1,
            activityCharacterCount: 80,
            activityRevision: 9,
            tailActivityCount: 0,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 80,
            aboveActivityRevision: 9
        )
        expect(ConversationScrollPolicy.classifyContentChange(from: scrollTailActivityPrevious, to: scrollAboveActivityNext) == .structuralOrAbove, "Above-transcript activity reflow is structural")
        expect(ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, contentSnapshot: scrollTailActivityPrevious, pendingNewContentCount: 2),
            content: scrollAboveActivityNext,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        ).state.pendingNewContentCount == 2, "Above-transcript activity reflow does not invent new pending content")
        let scrollLegacyActivity = ConversationScrollPolicy.classifyContentChange(
            from: ConversationScrollContentSnapshot(messageCount: 3, activityCount: 1, activityCharacterCount: 20),
            to: ConversationScrollContentSnapshot(messageCount: 3, activityCount: 1, activityCharacterCount: 80)
        )
        expect(scrollLegacyActivity == .structuralOrAbove, "Unscoped activity reflow remains structural")
        let scrollReflowState = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: scrollBrowse,
            preservedOffsetY: scrollBrowse.contentOffsetY,
            lastContentHeight: scrollBrowse.contentHeight,
            pendingNewContentCount: 2
        )
        let scrollReflowMetrics = ConversationScrollMetrics(
            contentOffsetY: scrollBrowse.contentOffsetY,
            containerHeight: scrollBrowse.containerHeight,
            contentHeight: scrollBrowse.contentHeight + 80
        )
        let scrollReflow = ConversationScrollPolicy.decideGeometryChange(scrollReflowMetrics, state: scrollReflowState)
        expect(scrollReflow.state.pendingNewContentCount == 2, "Pure geometry reflow never increments pending new content")
        expect({
            if case .restoreOffset(let y, false) = scrollReflow.command { return abs(y - (scrollBrowse.contentOffsetY + 80)) < 0.01 }
            return false
        }(), "Pure geometry reflow compensates offset while browsing")
        var scrollNearClear = ConversationScrollSessionState(
            isFollowingTail: false,
            metrics: scrollBrowse,
            preservedOffsetY: scrollBrowse.contentOffsetY,
            pendingNewContentCount: 4
        )
        scrollNearClear = ConversationScrollPolicy.ingestGeometry(scrollNear, state: scrollNearClear)
        expect(scrollNearClear.isFollowingTail && scrollNearClear.pendingNewContentCount == 0, "Manual near-bottom clears pending new content")
        let scrollJump = ConversationScrollPolicy.decideJumpToLatest(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, pendingNewContentCount: 5),
            reduceMotion: true
        )
        expect(scrollJump.command == .followTail(animated: false) && scrollJump.state.pendingNewContentCount == 0 && !scrollJump.state.pendingOutgoingFollow, "Jump to Latest follows exactly once and clears pending")
        expect(!ConversationScrollPolicy.shouldShowJumpToLatest(state: scrollJump.state), "Jump affordance hides after Jump to Latest")
        let scrollOutgoing = ConversationScrollPolicy.decideOutgoingUserAction(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, pendingNewContentCount: 3),
            reduceMotion: false
        )
        expect(scrollOutgoing.command == .followTail(animated: true) && scrollOutgoing.state.pendingNewContentCount == 0, "Outgoing action follows tail and clears pending")
        let scrollSwitch = ConversationScrollPolicy.decideSessionActivation(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, preservedOffsetY: 180, pendingNewContentCount: 7),
            reduceMotion: false
        )
        expect(scrollSwitch.state.pendingNewContentCount == 7, "Session switch preserves pending new-content count")
        expect({
            if case .restoreOffset(let y, false) = scrollSwitch.command { return abs(y - 180) < 0.01 }
            return false
        }(), "Session switch restores preserved browse offset")
        expect(ConversationScrollPolicy.freshBranchState().pendingNewContentCount == 0 && ConversationScrollPolicy.freshBranchState().isFollowingTail, "Branch state starts with zero pending and follows tail")
        let scrollDelete = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(
                isFollowingTail: false,
                metrics: scrollBrowse,
                contentSnapshot: ConversationScrollContentSnapshot(messageCount: 6, lastMessageIsUser: false),
                pendingNewContentCount: 4
            ),
            content: ConversationScrollContentSnapshot(messageCount: 2, lastMessageIsUser: false),
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        )
        expect(scrollDelete.state.pendingNewContentCount == 0 && scrollDelete.state.pendingGeometryChange == .structuralOrAbove, "Message deletion clears stale pending new content")
        let scrollStopOnlyPrevious = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            lastMessageCharacterCount: 40,
            lastMessageRevision: 4,
            lastMessageIsUser: false,
            isStreaming: true
        )
        let scrollStopOnlyCurrent = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            lastMessageCharacterCount: 40,
            lastMessageRevision: 4,
            lastMessageIsUser: false,
            isStreaming: false
        )
        expect(ConversationScrollPolicy.classifyContentChange(from: scrollStopOnlyPrevious, to: scrollStopOnlyCurrent) == .none, "Stop-only streaming transition is not content growth")
        expect(ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, contentSnapshot: scrollStopOnlyPrevious, pendingNewContentCount: 2),
            content: scrollStopOnlyCurrent,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        ).state.pendingNewContentCount == 2, "Stop-only transition preserves truthful pending content")
        expect(ConversationScrollPolicy.shouldShowJumpToLatest(state: ConversationScrollSessionState(isFollowingTail: false, pendingNewContentCount: 2)), "Jump affordance visible when browsing with pending content")
        expect(!ConversationScrollPolicy.shouldShowJumpToLatest(state: ConversationScrollSessionState(isFollowingTail: true, pendingNewContentCount: 2)), "Jump affordance hidden while following tail")
        expect(ConversationScrollPolicy.displayedPendingCount(1) == "1" && ConversationScrollPolicy.displayedPendingCount(100) == "99+", "Pending count display handles singular and large counts")
        expect(ConversationScrollPolicy.jumpToLatestAccessibilityValue(count: 1) == "1 new update", "Jump accessibility value is singular")
        expect(ConversationScrollPolicy.jumpToLatestAccessibilityValue(count: 4) == "4 new updates", "Jump accessibility value is plural")
        expect(ConversationScrollPolicy.jumpToLatestAccessibilityLabel() == "Jump to Latest", "Jump accessibility label is stable")
        let scrollQueued = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(
                isFollowingTail: false,
                metrics: scrollBrowse,
                contentSnapshot: ConversationScrollContentSnapshot(messageCount: 2, queuedFollowUpCount: 0)
            ),
            content: ConversationScrollContentSnapshot(messageCount: 2, queuedFollowUpCount: 1),
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        )
        expect(scrollQueued.command == .none && scrollQueued.state.pendingNewContentCount == 1 && !scrollQueued.state.isFollowingTail, "Queued content below increments pending without moving the browsing viewport")
        let scrollMixedPrevious = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            lastMessageCharacterCount: 20,
            lastMessageRevision: 1,
            activityCount: 1,
            activityCharacterCount: 10,
            activityRevision: 1,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 10,
            aboveActivityRevision: 1,
            isStreaming: true
        )
        let scrollMixedCurrent = ConversationScrollContentSnapshot(
            messageCount: 2,
            lastMessageID: scrollMessageID,
            lastMessageCharacterCount: 60,
            lastMessageRevision: 2,
            activityCount: 1,
            activityCharacterCount: 30,
            activityRevision: 2,
            aboveActivityCount: 1,
            aboveActivityCharacterCount: 30,
            aboveActivityRevision: 2,
            isStreaming: true
        )
        let scrollMixed = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(isFollowingTail: false, metrics: scrollBrowse, contentSnapshot: scrollMixedPrevious),
            content: scrollMixedCurrent,
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        )
        expect(scrollMixed.command == .none && scrollMixed.state.pendingGeometryChange == .structuralOrAbove && scrollMixed.state.pendingNewContentCount == 1, "Simultaneous above reflow and tail streaming still counts only the real tail update")
        let scrollRemovedNotice = ConversationScrollPolicy.decideContentChange(
            state: ConversationScrollSessionState(
                isFollowingTail: false,
                metrics: scrollBrowse,
                contentSnapshot: ConversationScrollContentSnapshot(messageCount: 2, hasPermissionNotice: true, permissionNoticeID: scrollMessageID),
                pendingNewContentCount: 1
            ),
            content: ConversationScrollContentSnapshot(messageCount: 2),
            measuredMetrics: scrollBrowse,
            reduceMotion: false
        )
        expect(scrollRemovedNotice.state.pendingNewContentCount == 0, "Removing an unread tail accessory clears the stale pending claim")
        expect(ConversationScrollPolicy.compensatedOffset(previousOffset: 150, previousContentHeight: 800, newContentHeight: 1_200, newContainerHeight: 400, changeKind: .bottomTailGrowth) == 150, "Bottom growth preserves browse offset")

        // Session save coordinator: failure visibility, retry-latest, coalesce, flush, gate, storm suppression
        final class Box<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: T
            init(_ value: T) { storage = value }
            var value: T {
                get { lock.lock(); defer { lock.unlock() }; return storage }
                set { lock.lock(); storage = newValue; lock.unlock() }
            }
        }
        let diskFull = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [NSLocalizedDescriptionKey: "No space left on device"])
        let permission = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        expect(SessionSaveFailureClassifier.kind(for: diskFull) == .diskFull, "Save classifier detects disk full")
        expect(SessionSaveFailureClassifier.kind(for: permission) == .permissionDenied, "Save classifier detects permission denied")
        expect(SessionSaveFailureClassifier.kind(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError, userInfo: nil)) == .permissionDenied, "Save classifier treats read-only volumes as permission failures")
        expect(SessionSaveFailureClassifier.kind(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)) == .writeFailed, "Save classifier detects generic write failure")
        expect(SessionSaveFailureClassifier.isWriteBlocked(DurableStoreRecoveryError.writeBlocked(storeName: "Chat sessions")), "Write-blocked is recognized and must not become save-failure UI")

        let saveNotify = Box(0)
        let failCoord = SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: "/tmp/lattice-verify-sessions.json",
            writeGate: DurableStoreWriteGate(),
            saveHandler: { _ in throw diskFull },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            failureObserver: { _ in saveNotify.value += 1 }
        )
        if case .failed(let failure) = failCoord.saveNow([LatticeSession(title: "A", backend: .codex(model: "gpt-5.4"), draft: "keep")]) {
            expect(failure.kind == .diskFull && failure.summary.contains("in memory"), "Save failure is visible and non-destructive")
            expect(failure.kind.rawValue != DurableStoreIssueKind.corrupt.rawValue, "Save failure is classified separately from load recovery")
        } else {
            expect(false, "Save failure is visible and non-destructive")
        }
        expect(saveNotify.value == 1, "First save failure notifies once")
        if case .coalescedFailure = failCoord.saveNow([LatticeSession(title: "A", backend: .codex(model: "gpt-5.4"), draft: "again")]) {
            expect(saveNotify.value == 1, "Equivalent save failures coalesce without error storms")
        } else {
            expect(false, "Equivalent save failures coalesce without error storms")
        }

        let written = Box<[LatticeSession]?>(nil)
        let shouldFail = Box(true)
        let retryCoord = SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: "/tmp/lattice-verify-sessions.json",
            writeGate: DurableStoreWriteGate(),
            saveHandler: { sessions in
                if shouldFail.value { throw permission }
                written.value = sessions
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        _ = retryCoord.saveNow([LatticeSession(title: "Stale", backend: .codex(model: "gpt-5.4"), draft: "old")])
        shouldFail.value = false
        let retryResult = retryCoord.retry([LatticeSession(title: "Latest", backend: .codex(model: "gpt-5.4"), draft: "newest exact")])
        expect(retryResult == .saved && retryCoord.currentFailure == nil, "Later success clears save failure status")
        expect(written.value?.first?.draft == "newest exact" && written.value?.first?.title == "Latest", "Retry writes latest snapshot not the stale failed one")

        let debouncedWrites = Box(0)
        let debouncedDraft = Box<String?>(nil)
        let debounceCoord = SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: "/tmp/lattice-verify-sessions.json",
            writeGate: DurableStoreWriteGate(),
            debounceNanoseconds: 5_000_000,
            saveHandler: { sessions in
                debouncedWrites.value += 1
                debouncedDraft.value = sessions.first?.draft
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        debounceCoord.scheduleDebounced([LatticeSession(title: "D", backend: .codex(model: "gpt-5.4"), draft: "one")])
        debounceCoord.scheduleDebounced([LatticeSession(title: "D", backend: .codex(model: "gpt-5.4"), draft: "two")])
        debounceCoord.scheduleDebounced([LatticeSession(title: "D", backend: .codex(model: "gpt-5.4"), draft: "three exact")])
        expect(debounceCoord.pendingDebouncedSnapshot?.first?.draft == "three exact", "Debounced drafts coalesce to latest pending snapshot")
        try? await Task.sleep(nanoseconds: 40_000_000)
        expect(debouncedWrites.value == 1 && debouncedDraft.value == "three exact", "Debounced save writes once with latest exact draft")

        let stressWrites = Box(0)
        let stressDraft = Box<String?>(nil)
        let stressCoord = SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: "/tmp/lattice-verify-stress.json",
            writeGate: DurableStoreWriteGate(),
            debounceNanoseconds: 100_000_000,
            saveHandler: { sessions in
                stressWrites.value += 1
                stressDraft.value = sessions.first?.draft
            }
        )
        for index in 0..<2_000 {
            stressCoord.scheduleDebounced([
                LatticeSession(title: "Stress", backend: .codex(model: "gpt-5.4"), draft: "draft-\(index)")
            ])
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        expect(stressWrites.value == 1 && stressDraft.value == "draft-1999", "Rapid debounce cancellation keeps only the latest generation")

        let boundaryWrites = Box<[String]>([])
        let boundaryCoord = SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: "/tmp/lattice-verify-sessions.json",
            writeGate: DurableStoreWriteGate(),
            debounceNanoseconds: 200_000_000,
            saveHandler: { sessions in boundaryWrites.value.append(sessions.first?.draft ?? "") },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        boundaryCoord.scheduleDebounced([LatticeSession(title: "B", backend: .codex(model: "gpt-5.4"), draft: "pending")])
        expect(boundaryCoord.saveNow([LatticeSession(title: "B", backend: .codex(model: "gpt-5.4"), draft: "immediate")]) == .saved, "Immediate safe-boundary save succeeds")
        expect(!boundaryCoord.hasPendingDebouncedSave && boundaryWrites.value == ["immediate"], "Immediate save cancels/absorbs pending debounce")
        let exactTermination = "typed before debounce\n  exact  "
        expect(boundaryCoord.flush([LatticeSession(title: "Selected", backend: .codex(model: "gpt-5.4"), draft: exactTermination)]) == .saved, "Termination flush succeeds")
        expect(boundaryWrites.value.last == exactTermination, "Termination flush writes exact latest draft snapshot")

        let gateBlocked = DurableStoreWriteGate()
        gateBlocked.block()
        let gateWrites = Box(0)
        let gateFailures = Box(0)
        let gateCoord = SessionSaveCoordinator(
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            filePath: "/tmp/lattice-verify-sessions.json",
            writeGate: gateBlocked,
            saveHandler: { _ in gateWrites.value += 1 },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            failureObserver: { _ in gateFailures.value += 1 }
        )
        expect(gateCoord.saveNow([LatticeSession(title: "G", backend: .codex(model: "gpt-5.4"))]) == .blockedByWriteGate, "Blocked gate save is not a write")
        expect(gateCoord.flush([LatticeSession(title: "G", backend: .codex(model: "gpt-5.4"))]) == .blockedByWriteGate, "Blocked gate flush is not a write")
        expect(gateCoord.retry([LatticeSession(title: "G", backend: .codex(model: "gpt-5.4"))]) == .blockedByWriteGate, "Blocked gate retry is not a write")
        expect(gateWrites.value == 0 && gateCoord.currentFailure == nil && gateFailures.value == 0, "Blocked gate never becomes save-failure UI")

        let saveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-save-coord-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: saveRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: saveRoot) }
        let saveURL = saveRoot.appendingPathComponent("sessions.json")
        let liveGate = DurableStoreWriteGate()
        let livePersistence = SessionPersistence(fileURL: saveURL, writeGate: liveGate)
        let liveCoord = SessionSaveCoordinator(persistence: livePersistence)
        liveGate.block()
        expect(liveCoord.saveNow([LatticeSession(title: "Live", backend: .codex(model: "gpt-5.4"), draft: "blocked")]) == .blockedByWriteGate, "Persistence-backed coordinator respects write gate")
        expect(!FileManager.default.fileExists(atPath: saveURL.path), "Blocked persistence-backed save leaves no file")
        liveGate.unblock()
        let liveDraft = "durable draft\nexact"
        expect(liveCoord.flush([LatticeSession(title: "Live", backend: .codex(model: "gpt-5.4"), draft: liveDraft)]) == .saved, "Persistence-backed flush saves")
        if case .loaded(let loaded) = livePersistence.loadResult() {
            expect(loaded.first?.draft == liveDraft, "Persistence-backed flush preserves exact draft content")
        } else {
            expect(false, "Persistence-backed flush preserves exact draft content")
        }

        try? FileManager.default.removeItem(at: extensionRoot)

        // MARK: Portable session archive safety invariants
        let archiveDate = Date(timeIntervalSince1970: 1_700_000_100)
        let archiveMessageID = UUID()
        let archiveThread = "provider-thread-DO-NOT-EXPORT"
        let archiveSession = LatticeSession(
            title: "Archive safety",
            messages: [
                ChatMessage(id: archiveMessageID, role: .user, text: "Visible transcript", date: archiveDate, isPinned: true),
                ChatMessage(role: .assistant, text: "Reply", date: archiveDate.addingTimeInterval(1))
            ],
            backend: .codex(model: "gpt-5.5"),
            harnessID: "codex",
            reasoningEffort: .low,
            harnessThreadID: archiveThread,
            workspacePath: "/Users/secret/workspace",
            attachments: [ContextAttachment(path: "/Users/secret/file.txt")],
            policy: .ask,
            privacyMode: .localOnly,
            actions: [
                SessionAction(messageID: archiveMessageID, kind: .tool, toolKind: .read, title: "Read secret-token", detail: "provider-secret-value", status: .completed, createdAt: archiveDate, updatedAt: archiveDate),
                SessionAction(messageID: archiveMessageID, kind: .tool, title: "Running", detail: "live", status: .running, createdAt: archiveDate, updatedAt: archiveDate),
                SessionAction(messageID: archiveMessageID, kind: .approval, title: "Wait", detail: "approval", status: .waiting, createdAt: archiveDate, updatedAt: archiveDate),
                SessionAction(messageID: archiveMessageID, kind: .reasoning, title: "Think", detail: "Visible reasoning summary", status: .completed, createdAt: archiveDate, updatedAt: archiveDate)
            ],
            queuedFollowUps: [QueuedFollowUp(text: "queued later", date: archiveDate)],
            draft: "ordinary unsent draft",
            isPinned: true,
            isStreaming: true,
            lastUpdated: archiveDate
        )
        let archiveJSON = try! SessionPortableArchiveExporter.exportData(
            from: archiveSession,
            options: .init(includeQueuedFollowUps: false, format: .jsonArchive, exportedAt: archiveDate)
        )
        let archiveText = String(data: archiveJSON, encoding: .utf8) ?? ""
        expect(archiveText.contains(SessionPortableArchive.formatID), "JSON archive uses lattice.session.archive format id")
        expect(!archiveText.contains(archiveThread), "JSON archive never includes provider thread IDs")
        expect(!archiveText.contains("ordinary unsent draft"), "JSON archive never includes ordinary composer draft")
        expect(!archiveText.contains("/Users/secret"), "JSON archive never includes absolute attachment/workspace paths")
        expect(!archiveText.contains("queued later"), "Queued follow-ups are excluded by default")
        expect(!archiveText.contains("\"running\""), "JSON archive never includes running action status")
        expect(!archiveText.contains("\"waiting\""), "JSON archive never includes waiting action status")
        expect(!archiveText.contains("secret-token") && !archiveText.contains("provider-secret-value"), "Action export uses typed summaries without provider free-form secrets")
        expect(SessionPortableArchivePrivacy.assertExportPrivacy(in: archiveJSON).isEmpty, "JSON archive privacy forbidden substrings are absent")
        let archiveWithQueued = try! SessionPortableArchiveExporter.exportData(
            from: archiveSession,
            options: .init(includeQueuedFollowUps: true, format: .jsonArchive, exportedAt: archiveDate)
        )
        expect(String(data: archiveWithQueued, encoding: .utf8)?.contains("queued later") == true, "Queued follow-ups export only when explicitly included")
        let archiveMarkdown = SessionPortableArchiveExporter.exportMarkdown(
            from: archiveSession,
            options: .init(includeQueuedFollowUps: false, format: .markdown, exportedAt: archiveDate)
        )
        expect(archiveMarkdown.contains("Lattice Chat Export"), "Markdown export is labeled as Lattice Chat Export")
        expect(archiveMarkdown.lowercased().contains("not") && archiveMarkdown.lowercased().contains("import"), "Markdown export states it is not importable")
        expect(archiveMarkdown.contains("Visible transcript"), "Markdown export includes visible transcript")
        expect(!archiveMarkdown.contains(archiveThread), "Markdown export never includes provider thread IDs")
        expect(!archiveMarkdown.contains("ordinary unsent draft"), "Markdown export never includes ordinary composer draft")
        expect(!archiveMarkdown.contains("Visible reasoning summary"), "Markdown export never includes provider free-form reasoning detail")
        do {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(archiveMarkdown.utf8), existingSessions: [])
            expect(false, "Markdown export must not be importable")
        } catch SessionPortableArchive.ArchiveError.markdownNotImportable {
            expect(true, "Markdown export is rejected on import")
        } catch {
            expect(false, "Markdown export is rejected on import")
        }
        let importPlan = try! SessionPortableArchiveImporter.prepareImport(data: archiveJSON, existingSessions: [])
        expect(importPlan.session.id != archiveSession.id, "Import remaps session identity")
        expect(importPlan.session.harnessThreadID == nil, "Import never restores provider thread IDs")
        expect(importPlan.session.isStreaming == false, "Import never restores streaming state")
        expect(importPlan.session.draft.isEmpty, "Import never restores ordinary draft")
        expect(importPlan.session.attachments.allSatisfy(\.isMissing), "Imported attachments are missing metadata only")
        expect(importPlan.session.attachments.allSatisfy { $0.path.hasPrefix(SessionPortableArchive.missingAttachmentScheme) }, "Imported attachment paths use non-resolvable missing scheme")
        expect(importPlan.session.actions.allSatisfy { $0.status != .running && $0.status != .waiting }, "Imported actions are inert terminal summaries")
        expect(importPlan.session.lastUpdated == archiveSession.lastUpdated, "Import preserves the exported chat timestamp")
        let modelLessCodexArchive = #"{"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"No model","backendRoute":"codex","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}"#
        let modelLessCodexPlan = try! SessionPortableArchiveImporter.prepareImport(data: Data(modelLessCodexArchive.utf8), existingSessions: [])
        expect(modelLessCodexPlan.session.backend == .codex(model: ""), "Model-less Codex archive imports as a non-runnable empty sentinel")
        let explicitCodexArchive = #"{"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"Explicit model","backendRoute":"codex","backendModel":"archive-model-provenance","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}"#
        let explicitCodexPlan = try! SessionPortableArchiveImporter.prepareImport(data: Data(explicitCodexArchive.utf8), existingSessions: [])
        expect(explicitCodexPlan.session.backend == .codex(model: "archive-model-provenance"), "Codex archive preserves explicit model provenance without rewriting it")
        expect(importPlan.session.queuedFollowUps.isEmpty, "Default export excludes queued follow-ups on import")
        expect(importPlan.preview.messageCount == 2, "Import preview reports message count")
        expect(importPlan.preview.attachmentCount == 1, "Import preview reports attachment count")
        let existingForDup = importPlan.session
        let sourceDupPlan = try! SessionPortableArchiveImporter.prepareImport(data: archiveJSON, existingSessions: [archiveSession])
        expect(sourceDupPlan.preview.isDuplicate && sourceDupPlan.preview.duplicateSessionIDs == [archiveSession.id], "Duplicate detection recognizes the original exported session")
        let dupPlan = try! SessionPortableArchiveImporter.prepareImport(data: archiveJSON, existingSessions: [existingForDup])
        expect(dupPlan.preview.isDuplicate, "Duplicate portable fingerprint is detected")
        expect(dupPlan.preview.duplicateSessionIDs == [existingForDup.id], "Duplicate warning points at matching local sessions")
        let commit = SessionPortableArchiveImporter.commit(plan: importPlan, into: [archiveSession], selectedSessionID: archiveSession.id)
        expect(commit.sessions.count == 2, "Import commit is additive")
        expect(commit.sessions.contains(where: { $0.id == archiveSession.id }), "Import commit never overwrites the source session identity slot")
        expect(commit.selectedSessionID == archiveSession.id, "Pure commit leaves selection unchanged")
        let oversize = Data(repeating: 0x42, count: SessionPortableArchive.maxArchiveBytes + 1)
        do {
            _ = try SessionPortableArchiveImporter.prepareImport(data: oversize, existingSessions: [])
            expect(false, "Oversize archives are rejected")
        } catch SessionPortableArchive.ArchiveError.fileTooLarge {
            expect(true, "Oversize archives are rejected before decode")
        } catch {
            expect(false, "Oversize archives are rejected before decode")
        }
        let futureArchive = """
        {"format":"lattice.session.archive","version":9,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[],"actions":[],"queuedFollowUps":[]}}
        """
        do {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(futureArchive.utf8), existingSessions: [])
            expect(false, "Future archive versions are rejected")
        } catch SessionPortableArchive.ArchiveError.unsupportedVersion(9) {
            expect(true, "Future archive versions are rejected safely")
        } catch {
            expect(false, "Future archive versions are rejected safely")
        }
        let wrongTypedArchive = #"{"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":"false","chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed"}}"#
        do {
            _ = try SessionPortableArchiveImporter.prepareImport(data: Data(wrongTypedArchive.utf8), existingSessions: [])
            expect(false, "Wrong-typed archive fields are rejected")
        } catch SessionPortableArchive.ArchiveError.invalidField("includeQueuedFollowUps") {
            expect(true, "Wrong-typed archive fields are rejected instead of receiving legacy defaults")
        } catch {
            expect(false, "Wrong-typed archive fields are rejected instead of receiving legacy defaults")
        }
        let traversalArchive = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","includeQueuedFollowUps":false,"chat":{"title":"x","backendRoute":"ollama","backendModel":"m","policy":"Ask","privacyMode":"cloudAllowed","messages":[],"attachments":[{"name":"../../etc/passwd","kind":"file","availability":"metadata-only"}],"actions":[],"queuedFollowUps":[]}}
        """
        let traversalPlan = try! SessionPortableArchiveImporter.prepareImport(data: Data(traversalArchive.utf8), existingSessions: [])
        expect(traversalPlan.session.attachments.first?.isMissing == true, "Traversal attachment names import as missing")
        expect(traversalPlan.session.attachments.first?.path.contains("..") != true, "Imported attachment tokens never retain path traversal")
        expect(!FileManager.default.fileExists(atPath: traversalPlan.session.attachments.first?.path ?? "/"), "Import does not produce openable filesystem paths for attachments")
        let legacyArchive = """
        {"format":"lattice.session.archive","version":1,"exportedAt":"2024-01-01T00:00:00Z","chat":{"title":"Legacy","backendRoute":"appleIntelligence","policy":"Ask","privacyMode":"cloudAllowed"}}
        """
        let legacyPlan = try! SessionPortableArchiveImporter.prepareImport(data: Data(legacyArchive.utf8), existingSessions: [])
        expect(legacyPlan.session.messages.isEmpty && legacyPlan.session.policy == .ask && legacyPlan.session.isStreaming == false, "Legacy-compatible omissions decode with safe defaults")
        let fingerprintSession = LatticeSession(title: "fp", backend: .ollama(model: "m"), portableArchiveFingerprint: "abc")
        let decodedFingerprintMissing = try! JSONDecoder().decode(
            LatticeSession.self,
            from: JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString,
                "title": "old",
                "messages": [],
                "backend": ["ollama": ["model": "m"]],
                "attachments": [["id": UUID().uuidString, "path": "/tmp/a"]],
                "policy": "Ask",
                "privacyMode": "cloudAllowed",
                "actions": [],
                "queuedFollowUps": [],
                "draft": "",
                "isPinned": false,
                "isStreaming": false,
                "lastUpdated": 0
            ])
        )
        expect(decodedFingerprintMissing.portableArchiveFingerprint == nil, "Missing portableArchiveFingerprint defaults to nil")
        expect(decodedFingerprintMissing.attachments.first?.isMissing == false, "Missing attachment isMissing defaults to false")
        expect(fingerprintSession.portableArchiveFingerprint == "abc", "Fingerprint can be stored on session metadata")

        let provenanceRequestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let provenance = ApprovalProvenance(
            harnessID: "hermes",
            providerName: "Hermes",
            requestID: provenanceRequestID,
            requestedOptionKinds: ["allow_once", "reject_once"],
            toolKind: .write,
            workspaceScoped: true,
            policy: .smart,
            policyReason: "Material changes require confirmation.",
            actor: .user,
            selectedOptionKind: "allow_once",
            outcome: .forwarded,
            providerAcknowledgement: .acceptedByHarness
        )
        let provenanceAction = SessionAction(
            messageID: UUID(),
            kind: .approval,
            toolKind: .write,
            title: "Approval",
            detail: "bounded summary",
            status: .allowed,
            workspaceScoped: true,
            approvalProvenance: provenance
        )
        let provenanceData = try! JSONEncoder().encode(provenanceAction)
        let decodedProvenanceAction = try! JSONDecoder().decode(SessionAction.self, from: provenanceData)
        expect(decodedProvenanceAction.approvalProvenance == provenance, "Approval provenance survives durable session JSON")
        let redactedCLIMessage = CLIActionStatusPolicy.failureMessage(
            prefix: "Install failed",
            output: Data("authorization: Bearer abcdefghijklmnop sk-proj-abcdefghijklmnop\n".utf8)
        )
        expect(redactedCLIMessage.contains("[REDACTED]"), "CLI failure summaries redact credential-shaped output")
        expect(!redactedCLIMessage.contains("abcdefghijklmnop"), "CLI failure summaries do not expose token material")
        let redactedHarnessDetail = CLIActionStatusPolicy.redactedDetail("$ curl -H 'Authorization: Bearer abcdefghijklmnop'")
        expect(redactedHarnessDetail.contains("[REDACTED]") && !redactedHarnessDetail.contains("abcdefghijklmnop"), "Harness activity details redact credential-shaped command arguments")

        expect(
            AntigravityCLIProtocol.detect(helpOutput: "--print --conversation")
                == .transcript(reason: "This Antigravity CLI does not advertise stream-json output."),
            "Antigravity protocol detection keeps transcript-only runtimes degraded"
        )
        expect(
            AntigravityCLIProtocol.detect(helpOutput: "--output-format text|json|stream-json") == .streamJSON,
            "Antigravity protocol detection enables an explicitly advertised JSONL surface"
        )
        let antigravityWorkspace = URL(fileURLWithPath: "/tmp/Lattice-Antigravity")
        let antigravityInit = AntigravityCLIHarness.structuredEvent(
            from: Data(#"{"type":"init","session_id":"provider-session"}"#.utf8),
            workspace: antigravityWorkspace
        )
        expect(antigravityInit == [.harnessSessionStarted("provider-session")], "Antigravity structured init exposes the provider session boundary")
        let antigravityTool = AntigravityCLIHarness.structuredEvent(
            from: Data(#"{"type":"tool_use","tool_id":"tool-1","tool_name":"run_command","parameters":{"command":"swift test"}}"#.utf8),
            workspace: antigravityWorkspace
        )
        if case .toolRequested(let request)? = antigravityTool.first {
            expect(request.kind == .command && request.detail == "$ swift test", "Antigravity structured tool calls expose bounded command metadata")
        } else {
            expect(false, "Antigravity structured tool calls expose bounded command metadata")
        }
        let antigravityMalformed = AntigravityCLIHarness.structuredEvent(from: Data("not-json".utf8), workspace: antigravityWorkspace)
        expect(antigravityMalformed.contains(where: { if case .providerDiagnostic = $0 { return true }; return false }), "Malformed Antigravity JSONL becomes an observable diagnostic")
        let antigravityUnknown = AntigravityCLIHarness.structuredEvent(from: Data(#"{"type":"invented","secret":"not surfaced"}"#.utf8), workspace: antigravityWorkspace)
        if case .providerDiagnostic(let diagnostic)? = antigravityUnknown.first {
            expect(diagnostic.eventType == "invented" && !diagnostic.detail.contains("not surfaced"), "Unknown Antigravity events retain metadata without payload values")
        } else {
            expect(false, "Unknown Antigravity events retain metadata without payload values")
        }

        let selectedLaneID = UUID()
        let backgroundLaneID = UUID()
        var laneStore = ThreadActivityLaneStore(selectedSessionID: selectedLaneID)
        laneStore.apply(.started, to: selectedLaneID)
        laneStore.apply(.started, to: backgroundLaneID)
        laneStore.apply(.approvalRequested, to: backgroundLaneID)
        laneStore.apply(.completed, to: selectedLaneID)
        expect(laneStore.lane(for: selectedLaneID).status == .completed, "Selected thread completion is independently visible")
        expect(!laneStore.lane(for: selectedLaneID).hasUnreadActivity, "Selected thread completion is not marked unread")
        expect(laneStore.lane(for: backgroundLaneID).status == .waitingForApproval, "Background approval wait remains independent")
        expect(laneStore.lane(for: backgroundLaneID).requiresAttention && laneStore.lane(for: backgroundLaneID).hasUnreadActivity, "Background approval wait marks attention and unread")
        laneStore.select(backgroundLaneID)
        expect(!laneStore.lane(for: backgroundLaneID).hasUnreadActivity && laneStore.lane(for: backgroundLaneID).requiresAttention, "Selection clears unread without dismissing approval attention")
        laneStore.apply(.cancelled, to: backgroundLaneID)
        expect(laneStore.lane(for: backgroundLaneID).status == .cancelled, "Cancellation changes only its target lane")
        expect(laneStore.lane(for: selectedLaneID).status == .completed, "Cancellation preserves another thread terminal state")
        laneStore.apply(.queued(2), to: selectedLaneID)
        expect(laneStore.lane(for: selectedLaneID).queuedCount == 2, "Queued follow-ups are counted per thread")

        var controlAction = ControlActionState()
        expect(!controlAction.begin(progressMessage: "Blocked", disabledReason: "Runtime unavailable"), "Disabled control prerequisite prevents dispatch")
        expect(controlAction.begin(progressMessage: "Checking…"), "Control action dispatch starts from idle")
        expect(!controlAction.begin(progressMessage: "Duplicate"), "Control action suppresses duplicate dispatch while running")
        controlAction.fail("Unavailable")
        expect(controlAction.phase == .failed && controlAction.message == "Unavailable", "Control action surfaces failure")
        expect(controlAction.begin(progressMessage: "Retrying…"), "Failed control action can recover through retry")
        controlAction.succeed("Ready")
        expect(controlAction.phase == .succeeded && controlAction.message == "Ready", "Retried control action surfaces success")

        expect(LatticeResponsiveLayoutPolicy.horizontalPadding(forAvailableWidth: 640) == 16, "Narrow pages use compact horizontal insets")
        expect(LatticeResponsiveLayoutPolicy.contentWidth(forAvailableWidth: 640) == 608, "Narrow pages preserve a usable content region")
        expect(LatticeResponsiveLayoutPolicy.contentWidth(forAvailableWidth: 900) == 852, "Regular pages preserve comfortable margins")
        expect(LatticeResponsiveLayoutPolicy.contentWidth(forAvailableWidth: 1_600) == 1_280, "Wide pages cap their reading region")
        expect(!LatticeResponsiveLayoutPolicy.usesSideBySideSections(forContentWidth: 1_039), "Secondary sections stay stacked before the wide breakpoint")
        expect(LatticeResponsiveLayoutPolicy.canFitMultipleCards(contentWidth: 694, minimumCardWidth: 340), "Card collections split only when both minimum widths fit")

        // Workspace checkpoint service (Git plumbing, durable store, guarded revert).
        do {
            func expectThrowsInvalidPath(_ path: String, _ message: String) {
                do {
                    _ = try WorkspaceCheckpointValidation.validateRepoRelativePath(path)
                    expect(false, message)
                } catch let error as WorkspaceCheckpointError {
                    if case .invalidRepoRelativePath = error {
                        checks += 1
                    } else {
                        expect(false, message)
                    }
                } catch {
                    expect(false, message)
                }
            }
            expectThrowsInvalidPath("/abs", "Absolute review paths are rejected")
            expectThrowsInvalidPath("../escape", "Parent-escaping review paths are rejected")
            do {
                try WorkspaceCheckpointValidation.validateLineRange(.init(start: 0, end: 2))
                expect(false, "Non-positive line ranges are rejected")
            } catch let error as WorkspaceCheckpointError {
                if case .invalidLineRange = error { checks += 1 } else { expect(false, "Non-positive line ranges are rejected") }
            } catch {
                expect(false, "Non-positive line ranges are rejected")
            }

            let storeRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("lattice-verify-checkpoint-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: storeRoot) }
            let storeURL = storeRoot.appendingPathComponent("workspace-checkpoints.json")
            let ownership = WorkspaceCheckpointOwnership(
                worktreePath: "/tmp/example",
                worktreeIdentity: "identity",
                sessionID: UUID(),
                runID: UUID()
            )
            let legacyID = UUID()
            let legacy: [String: Any] = [
                "version": 1,
                "checkpoints": [[
                    "id": legacyID.uuidString,
                    "ownership": [
                        "worktreePath": ownership.worktreePath,
                        "worktreeIdentity": ownership.worktreeIdentity,
                        "sessionID": ownership.sessionID.uuidString,
                        "runID": ownership.runID.uuidString
                    ],
                    "boundary": "beforeRun",
                    "status": "captured",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "treeOID": "deadbeef"
                ]]
            ]
            try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]).write(to: storeURL)
            let store = WorkspaceCheckpointStore(fileURL: storeURL)
            let migrated = try store.load()
            expect(migrated.version == WorkspaceCheckpointStoreDocument.currentVersion, "Legacy checkpoint store migrates to current version")
            expect(migrated.notes.isEmpty, "Legacy checkpoint store without notes migrates empty notes")
            expect(migrated.checkpoints.count == 1 && migrated.checkpoints[0].id == legacyID, "Legacy checkpoint rows survive migration")
            expect(migrated.checkpoints[0].untrackedFiles.isEmpty, "Missing untracked metadata defaults empty on migration")
            expect(migrated.checkpoints[0].hasTrackedDirtiness == false, "Missing dirtiness defaults false on migration")

            guard let gitURL = ExecutableDiscovery.locate("git") else {
                expect(false, "Git executable is required for checkpoint verification")
                throw WorkspaceCheckpointError.gitExecutableUnavailable
            }

            func runGit(_ directory: URL, _ args: [String], input: Data? = nil) async throws -> String {
                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                let result = await BoundedSubprocess.run(
                    BoundedSubprocessRequest(
                    executableURL: gitURL,
                    arguments: args,
                    stdinData: input,
                    currentDirectoryURL: directory,
                        environment: env,
                        deadline: 30
                    )
                )
                guard result.isSuccess else {
                    let detail = String(data: result.stderr + result.stdout, encoding: .utf8) ?? "git failed"
                    throw WorkspaceCheckpointError.subprocessFailed(operation: args.joined(separator: " "), detail: detail)
                }
                return String(data: result.stdout, encoding: .utf8) ?? ""
            }

            let repo = FileManager.default.temporaryDirectory
                .appendingPathComponent("lattice-verify-checkpoint-repo-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }
            _ = try await runGit(repo, ["init"])
            _ = try await runGit(repo, ["config", "user.email", "verify@lattice.local"])
            _ = try await runGit(repo, ["config", "user.name", "Lattice Verify"])
            _ = try await runGit(repo, ["config", "commit.gpgsign", "false"])
            try "hello\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            _ = try await runGit(repo, ["add", "tracked.txt"])
            _ = try await runGit(repo, ["commit", "-m", "init"])

            let liveStoreURL = storeRoot.appendingPathComponent("live-checkpoints.json")
            let liveStore = WorkspaceCheckpointStore(fileURL: liveStoreURL)
            let service = WorkspaceCheckpointService(store: liveStore, gitExecutableURL: gitURL, deadline: 30)
            let sessionID = UUID()
            let runID = UUID()

            let clean = try await service.capture(
                worktreeURL: repo,
                sessionID: sessionID,
                runID: runID,
                boundary: .beforeRun
            )
            expect(clean.status == .captured && clean.hasTrackedDirtiness == false, "Clean worktree checkpoint reports no tracked dirtiness")
            expect(clean.refName?.hasPrefix("refs/lattice/checkpoints/") == true, "Checkpoint refs use Lattice namespace")
            expect(clean.refName?.contains(sessionID.uuidString.lowercased()) == true, "Checkpoint refs embed session ownership")
            expect(clean.refName?.contains(runID.uuidString.lowercased()) == true, "Checkpoint refs embed run ownership")
            let resolvedRef = try await runGit(repo, ["rev-parse", clean.refName!]).trimmingCharacters(in: .whitespacesAndNewlines)
            expect(resolvedRef == clean.snapshotCommitOID, "Checkpoint ref resolves to snapshot commit")

            try "dirty\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            let secret = "verify-secret-\(UUID().uuidString)\n"
            try secret.write(to: repo.appendingPathComponent("scratch.secret"), atomically: true, encoding: .utf8)
            try "staged addition\n".write(to: repo.appendingPathComponent("staged-new.txt"), atomically: true, encoding: .utf8)
            _ = try await runGit(repo, ["add", "staged-new.txt"])
            let outsideSecret = storeRoot.appendingPathComponent("outside-secret.txt")
            let outsidePayload = "must-not-be-read-through-symlink-\(UUID().uuidString)"
            try outsidePayload.write(to: outsideSecret, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: repo.appendingPathComponent("outside-link"),
                withDestinationURL: outsideSecret
            )
            let dirty = try await service.capture(
                worktreeURL: repo,
                sessionID: sessionID,
                runID: UUID(),
                boundary: .beforeRun
            )
            expect(dirty.hasTrackedDirtiness == true, "Tracked dirty checkpoint is truthful")
            expect(dirty.untrackedFiles.contains(where: { $0.path == "scratch.secret" }), "Untracked metadata records non-ignored paths")
            expect(dirty.untrackedFiles.allSatisfy({ $0.canRestoreContent == false }), "Untracked contents are explicitly unrestorable")
            let stagedSnapshot = try await runGit(repo, ["show", "\(dirty.treeOID!):staged-new.txt"])
            expect(stagedSnapshot == "staged addition\n", "Checkpoint tree includes staged additions")
            let symlinkMetadata = dirty.untrackedFiles.first(where: { $0.path == "outside-link" })
            expect(symlinkMetadata?.isSymbolicLink == true, "Untracked symlink is recorded without following its target")
            expect(symlinkMetadata?.contentOID.hasPrefix("symlink-sha256:") == true, "Untracked symlink hashes link text, not target content")
            let storeBody = try String(contentsOf: liveStoreURL, encoding: .utf8)
            expect(!storeBody.contains("verify-secret-"), "Durable store never retains untracked contents")
            expect(!storeBody.contains("must-not-be-read-through-symlink"), "Durable store never reads symlink target contents")
            if let oid = dirty.untrackedFiles.first(where: { $0.path == "scratch.secret" })?.contentOID {
                let cat = await BoundedSubprocess.run(
                    BoundedSubprocessRequest(
                        executableURL: gitURL,
                        arguments: ["cat-file", "-t", oid],
                        currentDirectoryURL: repo,
                        deadline: 10
                    )
                )
                expect(!cat.isSuccess, "Untracked hash-object does not write objects into the repository")
            } else {
                expect(false, "Untracked hash-object does not write objects into the repository")
            }

            // Restore clean content then exercise before/after + guarded revert.
            try "hello\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: repo.appendingPathComponent("scratch.secret"))
            let pairSession = UUID()
            let pairRun = UUID()
            let before = try await service.capture(
                worktreeURL: repo,
                sessionID: pairSession,
                runID: pairRun,
                boundary: .beforeRun
            )
            try "mutated\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            try "created\n".write(to: repo.appendingPathComponent("agent-temp.txt"), atomically: true, encoding: .utf8)
            let after = try await service.capture(
                worktreeURL: repo,
                sessionID: pairSession,
                runID: pairRun,
                boundary: .afterRun
            )
            let changes = try await service.changes(beforeCheckpointID: before.id, afterCheckpointID: after.id)
            expect(changes.files.contains(where: { $0.path == "tracked.txt" }), "Before/after diff lists modified tracked files")
            expect(changes.files.contains(where: { $0.path == "tracked.txt" && !$0.hunks.isEmpty }), "Before/after diff includes parsed hunks")

            let note = try service.addReviewNote(
                checkpointID: after.id,
                path: "tracked.txt",
                body: "Follow up on mutation",
                kind: .followUpPrompt,
                lineRange: .init(start: 1, end: 1),
                hunkHeader: "@@ -1 +1 @@"
            )
            expect(note.sessionID == pairSession && note.runID == pairRun, "Review notes bind session and run ownership")
            let persistedNotes = try service.reviewNotes(checkpointID: after.id)
            expect(persistedNotes.count == 1, "Review notes persist outside the repository")

            let preview = try await service.previewRevert(afterCheckpointID: after.id)
            expect(preview.confirmationToken.hasPrefix("lattice-revert-v1:"), "Revert confirmation tokens are bound to preview inputs")
            do {
                _ = try await service.confirmRevert(afterCheckpointID: after.id, confirmationToken: "lattice-revert-v1:stale")
                expect(false, "Stale revert confirmation is refused")
            } catch let error as WorkspaceCheckpointError {
                expect(error == .revertConfirmationStale, "Stale revert confirmation is refused")
            } catch {
                expect(false, "Stale revert confirmation is refused")
            }
            _ = try await service.confirmRevert(afterCheckpointID: after.id, confirmationToken: preview.confirmationToken)
            let restored = try String(contentsOf: repo.appendingPathComponent("tracked.txt"), encoding: .utf8)
            expect(restored == "hello\n", "Guarded revert restores tracked content via reverse apply")
            let agentTempExists = FileManager.default.fileExists(atPath: repo.appendingPathComponent("agent-temp.txt").path)
            expect(!agentTempExists, "Guarded revert deletes exact run-created untracked files")

            // Divergence refusal after after-run.
            let divergeSession = UUID()
            let divergeRun = UUID()
            _ = try await service.capture(worktreeURL: repo, sessionID: divergeSession, runID: divergeRun, boundary: .beforeRun)
            try "after\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            let divergeAfter = try await service.capture(worktreeURL: repo, sessionID: divergeSession, runID: divergeRun, boundary: .afterRun)
            try "newer\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            do {
                _ = try await service.previewRevert(afterCheckpointID: divergeAfter.id)
                expect(false, "Revert preview refuses target-path divergence from after-run state")
            } catch let error as WorkspaceCheckpointError {
                if case .revertDivergence = error { checks += 1 } else { expect(false, "Revert preview refuses target-path divergence from after-run state") }
            } catch {
                expect(false, "Revert preview refuses target-path divergence from after-run state")
            }

            let baseOID = try await runGit(repo, ["rev-parse", "HEAD:tracked.txt"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let oursOID = try await runGit(repo, ["hash-object", "-w", "--stdin"], input: Data("ours\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            let theirsOID = try await runGit(repo, ["hash-object", "-w", "--stdin"], input: Data("theirs\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            let indexInfo = "100644 \(baseOID) 1\ttracked.txt\n100644 \(oursOID) 2\ttracked.txt\n100644 \(theirsOID) 3\ttracked.txt\n"
            _ = try await runGit(repo, ["update-index", "--index-info"], input: Data(indexInfo.utf8))
            do {
                _ = try await service.previewRevert(afterCheckpointID: divergeAfter.id)
                expect(false, "Revert preview refuses unresolved index conflicts")
            } catch let error as WorkspaceCheckpointError {
                if case .revertDivergence(let detail) = error, detail.contains("unresolved conflicts") {
                    checks += 1
                } else {
                    expect(false, "Revert preview refuses unresolved index conflicts")
                }
            } catch {
                expect(false, "Revert preview refuses unresolved index conflicts")
            }

            // Parallel worktree ownership / ref collision freedom.
            try "hello\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            let worktree = repo.deletingLastPathComponent()
                .appendingPathComponent("lattice-verify-wt-\(UUID().uuidString)", isDirectory: true)
            _ = try await runGit(repo, ["worktree", "add", "--detach", worktree.path, "HEAD"])
            defer {
                try? FileManager.default.removeItem(at: worktree)
                let prune = Process()
                prune.executableURL = gitURL
                prune.arguments = ["-C", repo.path, "worktree", "prune"]
                try? prune.run()
                prune.waitUntilExit()
            }
            let primaryCapture = try await service.capture(
                worktreeURL: repo,
                sessionID: UUID(),
                runID: UUID(),
                boundary: .beforeRun
            )
            let linkedCapture = try await service.capture(
                worktreeURL: worktree,
                sessionID: UUID(),
                runID: UUID(),
                boundary: .beforeRun
            )
            expect(primaryCapture.ownership.worktreeIdentity != linkedCapture.ownership.worktreeIdentity, "Parallel worktrees get distinct identities")
            expect(primaryCapture.refName != linkedCapture.refName, "Parallel worktrees get collision-free Lattice refs")

            let numstat = WorkspaceCheckpointService.parseNumstat("1\t0\tfile.txt\n2\t3\tother.txt\n")
            expect(numstat.filesChanged == 2, "Numstat parser counts changed files")
            expect(numstat.additions == 3, "Numstat parser aggregates additions")
            expect(numstat.deletions == 3, "Numstat parser aggregates deletions")
            let samplePatch = """
            diff --git a/file.txt b/file.txt
            --- a/file.txt
            +++ b/file.txt
            @@ -1 +1,2 @@
             hello
            +world
            """
            let hunks = WorkspaceCheckpointService.parseUnifiedDiffHunks(samplePatch)
            let fileHunks = hunks["file.txt"] ?? []
            expect(fileHunks.first?.newStart == 1, "Unified diff parser extracts hunk line ranges")
            let hasWorldAddition = fileHunks.first?.lines.contains(where: { line in
                line.kind == .addition && line.text == "world"
            }) == true
            expect(hasWorldAddition, "Unified diff parser retains addition lines for review UI")
        } catch {
            fputs("FAILED: Workspace checkpoint verification threw \(error)\n", stderr)
            exit(1)

        // Screenshot / Appshot LatticeCore foundation (migration, transport, frames, storage, permissions).
        let legacyAttachmentJSON = Data(#"{"id":"00000000-0000-0000-0000-0000000000aa","path":"/tmp/note.txt","isMissing":false}"#.utf8)
        if let legacyAttachment = try? JSONDecoder().decode(ContextAttachment.self, from: legacyAttachmentJSON) {
            expect(legacyAttachment.imageMetadata == nil && legacyAttachment.path == "/tmp/note.txt", "Legacy ContextAttachment JSON decodes without image metadata")
        } else {
            expect(false, "Legacy ContextAttachment JSON decodes without image metadata")
        }
        let defaultAttachment = ContextAttachment(path: "/tmp/shot.png", isMissing: false)
        expect(defaultAttachment.isImage && defaultAttachment.imageMetadata == nil, "ContextAttachment(path:isMissing:) remains available")
        let unauthorizedMeta = ContextAttachmentImageMetadata(
            isLatticeManaged: true,
            source: .regionCapture,
            accessibilityTextAuthorized: false,
            accessibilityText: "SECRET",
            imageOnlyFallback: .imageOnly(reason: "not authorized")
        )
        expect(unauthorizedMeta.accessibilityText == nil && unauthorizedMeta.imageOnlyFallback.isImageOnly, "Unauthorized accessibility text is never retained")
        let legacyModelJSON = Data(#"{"id":"gpt-test","name":"GPT Test","description":"","reasoningOptions":[],"isDefault":false}"#.utf8)
        if let legacyModel = try? JSONDecoder().decode(ProviderModel.self, from: legacyModelJSON) {
            // Nil means the runtime never advertised modalities; never invent image support.
            expect(legacyModel.inputModalities == nil && !legacyModel.acceptsImages, "Missing ProviderModel modalities fail closed as unknown (no image support)")
        } else {
            expect(false, "Missing ProviderModel modalities fail closed as unknown (no image support)")
        }
        expect(ProviderModelMetadata.inputModalities(from: ["inputModalities": ["text", "image"]]) == [.text, .image], "Structured model metadata parses advertised image input")
        expect(ProviderModelMetadata.inputModalities(from: [:]) == [.text], "Missing input modalities fail closed to text")
        let textOnlyModel = ProviderModel(id: "t", name: "Text Only")
        if case .blocked = AttachmentTransportPolicy.evaluate(attachments: [ContextAttachment(path: "/tmp/a.png")], model: textOnlyModel) {
            expect(true, "Transport policy blocks images when models do not advertise image input")
        } else {
            expect(false, "Transport policy blocks images when models do not advertise image input")
        }
        let visionModel = ProviderModel(id: "v", name: "Vision", inputModalities: [.text, .image])
        expect(AttachmentTransportPolicy.evaluate(attachments: [ContextAttachment(path: "/tmp/a.png")], model: visionModel) == .allowed, "Transport policy allows images when advertised")

        var frameAccumulator = ComputerFrameAccumulator(minimumInterval: 1, recentCapacity: 2)
        let frameT0 = Date(timeIntervalSince1970: 2_000)
        expect(frameAccumulator.offer(ComputerFrame(provider: "codex", imagePath: "https://example.com/x.png"), observedAt: frameT0) == .rejectedInvalidPath, "Frame accumulator rejects non-file URLs")
        expect(frameAccumulator.offer(ComputerFrame(provider: "codex", imagePath: "/tmp/f1.png"), observedAt: frameT0) == .accepted, "Frame accumulator accepts local file paths")
        expect(frameAccumulator.offer(ComputerFrame(provider: "codex", imagePath: "/tmp/f2.png"), observedAt: frameT0.addingTimeInterval(0.2)) == .rejectedRateLimited, "Frame accumulator rate-limits excess frames")
        expect(frameAccumulator.offer(ComputerFrame(provider: "codex", imagePath: "/tmp/f3.png"), observedAt: frameT0.addingTimeInterval(1.0)) == .accepted, "Frame accumulator accepts frames after interval")
        frameAccumulator.stop()
        expect(frameAccumulator.offer(ComputerFrame(provider: "codex", imagePath: "/tmp/f4.png"), observedAt: frameT0.addingTimeInterval(3.0)) == .rejectedStopped, "Stopped frame accumulator rejects new frames")
        let framePresentation = ComputerFramePresentationPolicy.presentation(for: frameAccumulator)
        expect(framePresentation.isStopped && framePresentation.controlsRemainProviderOwned, "Frame presentation marks stopped streams and provider-owned controls")
        let frameID = UUID(uuidString: "00000000-0000-0000-0000-0000000000cf")!
        let typedFrame = ComputerFrame(id: frameID, provider: "codex", timestamp: Date(timeIntervalSince1970: 1), imagePath: "/tmp/f.png")
        expect(AgentEvent.computerFrame(typedFrame) == .computerFrame(typedFrame), "AgentEvent.computerFrame is typed and equatable")
        let codexComputerEvent = CodexExecHarness.appServerEvent(from: [
            "method": "item/completed",
            "params": ["item": [
                "type": "dynamicToolCall", "id": "computer-1", "tool": "computer_use", "status": "completed",
                "contentItems": [["type": "inputImage", "imageUrl": "file:///tmp/provider-frame.png"]]
            ]]
        ], workspace: URL(fileURLWithPath: "/tmp"))
        if case .computerFrame(let frame)? = codexComputerEvent {
            expect(frame.imageURL?.path == "/tmp/provider-frame.png" && frame.controlBoundary.state == .observeOnly, "Codex maps only structured local computer image output to observe-only frames")
        } else {
            expect(false, "Codex maps only structured local computer image output to observe-only frames")
        }

        let captureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-verify-captures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: captureRoot) }
        final class CaptureClock: @unchecked Sendable {
            var value = Date(timeIntervalSince1970: 3_000)
        }
        let captureClock = CaptureClock()
        let captureStore = CaptureStorage(
            rootURL: captureRoot,
            configuration: .init(maxCaptureCount: 1, maxAge: 50),
            now: { captureClock.value }
        )
        if let written = try? captureStore.writeCapture(
            imageData: Data([0x89, 0x50]),
            imageExtension: "png",
            metadata: CaptureSidecarMetadata(
                source: .regionCapture,
                capturedAt: captureClock.value,
                accessibilityTextAuthorized: false,
                accessibilityText: "nope",
                imageOnlyFallback: .imageOnly(reason: "denied"),
                imageFileName: "x.png"
            )
        ) {
            expect(written.attachment.isLatticeManagedCapture && written.attachment.imageMetadata?.accessibilityText == nil, "Capture storage writes managed attachments without unauthorized text")
            captureClock.value = captureClock.value.addingTimeInterval(10)
            _ = try? captureStore.writeCapture(
                imageData: Data([0x01]),
                imageExtension: "png",
                metadata: CaptureSidecarMetadata(source: .clipboard, capturedAt: captureClock.value, imageFileName: "y.png")
            )
            expect(!FileManager.default.fileExists(atPath: written.imageURL.path), "Capture storage enforces bounded capture count")
            do {
                try captureStore.removeCapture(at: captureRoot.deletingLastPathComponent().appendingPathComponent("escape.png"))
                expect(false, "Capture storage rejects out-of-root deletion")
            } catch {
                expect(true, "Capture storage rejects out-of-root deletion")
            }
        } else {
            expect(false, "Capture storage writes managed attachments without unauthorized text")
        }

        let needsRecording = ScreenCapturePermissionPolicy.capability(
            screenRecording: .notDetermined,
            accessibility: .authorized,
            includeAccessibilityText: true
        )
        expect(needsRecording == .needsScreenRecordingPermission && !needsRecording.allowsImageCapture, "Screen Recording is required and distinct from Accessibility")
        let imageOnlyCapability = ScreenCapturePermissionPolicy.capability(
            screenRecording: .authorized,
            accessibility: .denied,
            includeAccessibilityText: true
        )
        expect(imageOnlyCapability.allowsImageCapture && !imageOnlyCapability.allowsAuthorizedAccessibilityText, "Denied Accessibility falls back to image-only capture")
        expect(!CaptureLifecyclePolicy.allowsHiddenOrContinuousCapture(), "Capture policy never allows hidden or continuous capture")
        var lifecycle = CaptureLifecycleState()
        if case .applied(let userStarted) = CaptureLifecyclePolicy.reduce(.userInitiatedCapture(includeAccessibilityText: false), into: lifecycle) {
            lifecycle = userStarted
            expect(lifecycle.phase == .userInitiated, "Capture lifecycle starts only from explicit user initiation")
            if case .rejected = CaptureLifecyclePolicy.reduce(.userInitiatedCapture(includeAccessibilityText: true), into: lifecycle) {
                expect(true, "Active capture cannot stack into continuous capture")
            } else {
                expect(false, "Active capture cannot stack into continuous capture")
            }
            if case .applied(let capturing) = CaptureLifecyclePolicy.reduce(.captureStarted, into: lifecycle) {
                if case .applied(let completed) = CaptureLifecyclePolicy.reduce(.completedImageOnly, into: capturing) {
                    expect(completed.phase == .completedImageOnly && completed.isTerminal, "Image-only completion is a terminal lifecycle state")
                } else {
                    expect(false, "Image-only completion is a terminal lifecycle state")
                }
            } else {
                expect(false, "Capture can start after user initiation")
            }
        } else {
            expect(false, "Capture lifecycle starts only from explicit user initiation")
        }

        print("Core verification passed: \(checks) checks")
    }
}
