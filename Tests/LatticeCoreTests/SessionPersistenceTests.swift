import Testing
import Foundation
import Darwin
@testable import LatticeCore

@Suite("Session persistence")
struct SessionPersistenceTests {
    @Test func messageEditContextIsScopedToItsOriginatingChat() {
        let chatA = UUID()
        let chatB = UUID()
        let context = MessageEditContext(sessionID: chatA, messageID: UUID())
        #expect(context.belongs(to: chatA))
        #expect(!context.belongs(to: chatB))
        #expect(!context.belongs(to: nil))
    }

    @Test func messageEditDraftStatePreservesAndRestoresComposerDraft() {
        let sessionID = UUID()
        let messageID = UUID()
        let began = MessageEditDraftState.begin(
            sessionID: sessionID,
            messageID: messageID,
            messageText: "edited message",
            currentDraft: "prior draft",
            existing: nil
        )
        #expect(began.draft == "edited message")
        #expect(began.state.preservedComposerDraft == "prior draft")
        #expect(began.state.context.messageID == messageID)

        let switched = MessageEditDraftState.begin(
            sessionID: sessionID,
            messageID: UUID(),
            messageText: "second edit",
            currentDraft: "edited message",
            existing: began.state
        )
        #expect(switched.state.preservedComposerDraft == "prior draft")
        #expect(MessageEditDraftState.cancel(switched.state) == "prior draft")
        #expect(MessageEditDraftState.complete(switched.state) == "prior draft")
    }

    @Test func composerSessionDraftTransitionSwitchesTwoChatsExactlyIncludingEmpty() {
        let chatA = UUID()
        let chatB = UUID()
        #expect(ComposerSessionDraftTransition.initialComposerDraft(selectedID: chatA, storedDraftForSelected: "restored\n  exactly  ") == "restored\n  exactly  ")
        #expect(ComposerSessionDraftTransition.initialComposerDraft(selectedID: chatB, storedDraftForSelected: "") == "")
        #expect(ComposerSessionDraftTransition.initialComposerDraft(selectedID: nil, storedDraftForSelected: "must not leak") == "")
        let leaveA = ComposerSessionDraftTransition.selecting(
            from: chatA,
            to: chatB,
            composerText: "alpha\n  draft  ",
            edit: nil,
            storedDraftForNext: "beta draft"
        )
        #expect(leaveA.previousSessionDraft == "alpha\n  draft  ")
        #expect(leaveA.composerDraft == "beta draft")
        #expect(!leaveA.clearsEditState)

        let leaveBEmpty = ComposerSessionDraftTransition.selecting(
            from: chatB,
            to: chatA,
            composerText: "",
            edit: nil,
            storedDraftForNext: "alpha\n  draft  "
        )
        #expect(leaveBEmpty.previousSessionDraft == "")
        #expect(leaveBEmpty.composerDraft == "alpha\n  draft  ")
        #expect(!leaveBEmpty.clearsEditState)
    }

    @Test func composerSessionDraftTracksRapidSelectionIndependentlyOfTranscriptHydration() {
        let chats = (0..<3).map { _ in UUID() }
        var stored = [chats[0]: "A saved", chats[1]: "B saved", chats[2]: "C saved"]
        var selected = chats[0]
        var composer = stored[selected] ?? ""

        for next in [chats[1], chats[2]] {
            let transition = ComposerSessionDraftTransition.selecting(
                from: selected,
                to: next,
                composerText: composer + " edited",
                edit: nil,
                storedDraftForNext: stored[next] ?? ""
            )
            stored[selected] = transition.previousSessionDraft
            selected = next
            composer = transition.composerDraft
        }

        #expect(selected == chats[2])
        #expect(composer == "C saved")
        #expect(stored[chats[0]] == "A saved edited")
        #expect(stored[chats[1]] == "B saved edited")
    }

    @Test func composerSessionDraftTransitionCancelsEditWithoutLeakingEditText() {
        let chatA = UUID()
        let chatB = UUID()
        let edit = MessageEditDraftState(
            context: MessageEditContext(sessionID: chatA, messageID: UUID()),
            preservedComposerDraft: "ordinary A"
        )
        let switchWhileEditing = ComposerSessionDraftTransition.selecting(
            from: chatA,
            to: chatB,
            composerText: "transient edited message text",
            edit: edit,
            storedDraftForNext: "ordinary B"
        )
        #expect(switchWhileEditing.previousSessionDraft == "ordinary A")
        #expect(switchWhileEditing.composerDraft == "ordinary B")
        #expect(switchWhileEditing.clearsEditState)
        #expect(ComposerSessionDraftTransition.clearingOrdinaryDraft() == "")
        #expect(ComposerSessionDraftTransition.preservingOrdinaryDraft("keep me") == "keep me")
        #expect(MessageEditDraftState.complete(edit) == "ordinary A")
    }

    @Test func sessionDeletionPolicyCancelsTargetByOwnID() {
        let target = UUID()
        #expect(SessionDeletionPolicy.decision(forStreamingTarget: target, isStreaming: false) == .deleteIdle)
        if case .cancelTargetThenDelete(let id) = SessionDeletionPolicy.decision(forStreamingTarget: target, isStreaming: true) {
            #expect(id == target)
        } else {
            Issue.record("Streaming deletion must cancel the target session by id")
        }
    }

    @Test func commandPaletteSelectionMovesClampsAndRefusesDisabledExecution() {
        let items = [
            LatticeCommandPaletteItem(id: "new-chat", title: "New Chat", detail: "Start a fresh conversation"),
            LatticeCommandPaletteItem(id: "continue", title: "Continue Response", detail: "Resume", isEnabled: false, disabledReason: "No response"),
            LatticeCommandPaletteItem(id: "models", title: "Show Models", detail: "Catalog")
        ]
        // Clamping: prefer current enabled, else first enabled, else nil.
        #expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: nil, in: items) == "new-chat")
        #expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "continue", in: items) == "new-chat")
        #expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "missing", in: items) == "new-chat")
        #expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "models", in: items) == "models")

        // Hover shares the same enabled selection; disabled/missing leaves selection unchanged (nil = no update).
        #expect(LatticeCommandPaletteSelection.selectionAfterHover(hoveredID: "models", in: items) == "models")
        #expect(LatticeCommandPaletteSelection.selectionAfterHover(hoveredID: "new-chat", in: items) == "new-chat")
        #expect(LatticeCommandPaletteSelection.selectionAfterHover(hoveredID: "continue", in: items) == nil)
        #expect(LatticeCommandPaletteSelection.selectionAfterHover(hoveredID: "missing", in: items) == nil)

        // Arrow navigation continues from shared selection and skips disabled rows.
        #expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "new-chat", in: items, delta: 1) == "models")
        #expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "models", in: items, delta: -1) == "new-chat")
        #expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "continue", in: items, delta: 1) == "new-chat")
        // Hover then arrow: selection after hovering models, then up, lands on new-chat.
        let afterHover = LatticeCommandPaletteSelection.selectionAfterHover(hoveredID: "models", in: items)
        #expect(LatticeCommandPaletteSelection.movedSelection(selectedID: afterHover, in: items, delta: -1) == "new-chat")

        // Boundaries: cannot move past first/last enabled rows.
        #expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "new-chat", in: items, delta: -1) == "new-chat")
        #expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "models", in: items, delta: 1) == "models")
        #expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "models", in: items, delta: -2) == "new-chat")

        // Execution gating: only enabled selections are executable.
        #expect(LatticeCommandPaletteSelection.executableSelection(selectedID: "continue", in: items) == nil)
        #expect(LatticeCommandPaletteSelection.executableSelection(selectedID: nil, in: items) == nil)
        #expect(LatticeCommandPaletteSelection.executableSelection(selectedID: "missing", in: items) == nil)
        #expect(LatticeCommandPaletteSelection.executableSelection(selectedID: "models", in: items)?.id == "models")

        // Filter changes clamp to an enabled visible row.
        let filtered = LatticeCommandPaletteMatcher.filtered(items, query: "models")
        #expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "new-chat", in: filtered) == "models")
        #expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "models", in: filtered) == "models")

        // All-disabled / no enabled visible rows → nil selection and no execution.
        let disabledOnly = [
            LatticeCommandPaletteItem(id: "continue", title: "Continue Response", detail: "Resume", isEnabled: false, disabledReason: "No response"),
            LatticeCommandPaletteItem(id: "stop", title: "Stop", detail: "Cancel", isEnabled: false, disabledReason: "Idle")
        ]
        #expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "continue", in: disabledOnly) == nil)
        #expect(LatticeCommandPaletteSelection.movedSelection(selectedID: "continue", in: disabledOnly, delta: 1) == nil)
        #expect(LatticeCommandPaletteSelection.selectionAfterHover(hoveredID: "continue", in: disabledOnly) == nil)
        #expect(LatticeCommandPaletteSelection.executableSelection(selectedID: "continue", in: disabledOnly) == nil)

        let disabledFiltered = LatticeCommandPaletteMatcher.filtered(items, query: "response")
        #expect(disabledFiltered.map(\.id) == ["continue"])
        #expect(LatticeCommandPaletteSelection.clampedSelection(selectedID: "new-chat", in: disabledFiltered) == nil)
    }

    @Test func applicationSupportMigrationCopiesLegacyWithoutOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Nisa", isDirectory: true)
        let modern = root.appendingPathComponent("Lattice", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("sessions.json"))

        #expect(!FileManager.default.fileExists(atPath: modern.path))
        #expect(LatticeApplicationSupport.migrateLegacyProductDataIfNeeded(base: root))
        #expect((try String(contentsOf: modern.appendingPathComponent("sessions.json"), encoding: .utf8)) == "legacy")

        // Do not overwrite newer Lattice data.
        try Data("newer".utf8).write(to: modern.appendingPathComponent("sessions.json"))
        #expect(!LatticeApplicationSupport.migrateLegacyProductDataIfNeeded(base: root))
        #expect((try String(contentsOf: modern.appendingPathComponent("sessions.json"), encoding: .utf8)) == "newer")
    }

    @Test func applicationSupportMigrationSkipsSecretsAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Nisa", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: legacy.appendingPathComponent("sessions.json"))
        try Data("provider-token".utf8).write(to: legacy.appendingPathComponent("auth.json"))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: legacy.appendingPathComponent("captures"),
            withDestinationURL: outside
        )

        #expect(LatticeApplicationSupport.migrateLegacyProductDataIfNeeded(base: root))
        let modern = root.appendingPathComponent("Lattice", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: modern.appendingPathComponent("sessions.json").path))
        #expect(!FileManager.default.fileExists(atPath: modern.appendingPathComponent("auth.json").path))
        #expect(!FileManager.default.fileExists(atPath: modern.appendingPathComponent("captures").path))
    }

    @Test func skillDeleteAuthorityRejectsPrefixCollisionAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let sibling = root.appendingPathComponent("managed-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingSkill = sibling.appendingPathComponent("skill", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingSkill, withIntermediateDirectories: true)
        let siblingURL = siblingSkill.appendingPathComponent("SKILL.md")
        try Data("# outside".utf8).write(to: siblingURL)
        let record = LatticeSkillRecord(id: "skill", title: "Skill", summary: "", source: .userAuthored, skillURL: siblingURL)
        #expect(record.canDelete == false)
    }

    @Test func legacySkillSidecarsRetainDeleteAndOwnershipSemantics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let global = root.appendingPathComponent("global", isDirectory: true)
        let globalSkill = global.appendingPathComponent("legacy-import", isDirectory: true)
        let managedImport = managed.appendingPathComponent("legacy-import", isDirectory: true)
        try FileManager.default.createDirectory(at: globalSkill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedImport, withIntermediateDirectories: true)
        let markdown = Data("# Legacy Import\n\nImported skill.".utf8)
        try markdown.write(to: globalSkill.appendingPathComponent("SKILL.md"))
        try markdown.write(to: managedImport.appendingPathComponent("SKILL.md"))
        try Data(LatticeSkillSource.importedGlobal.rawValue.utf8).write(
            to: managedImport.appendingPathComponent(LatticeLegacyBrandCompatibility.skillSourceMarker)
        )
        try Data(globalSkill.appendingPathComponent("SKILL.md").path.utf8).write(
            to: managedImport.appendingPathComponent(LatticeLegacyBrandCompatibility.skillOriginalPathMarker)
        )

        let store = LatticeSkillStore(rootURL: managed, globalRoots: [global])
        try store.deleteSkill(id: "legacy-import")
        try store.importGlobalSkills()
        #expect(store.load().allSatisfy { $0.id != "legacy-import" })

        let owned = managed.appendingPathComponent("legacy-owned", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try Data("# Legacy Owned\n\nOwned skill.".utf8).write(to: owned.appendingPathComponent("SKILL.md"))
        try Data("com.lattice.owner".utf8).write(
            to: owned.appendingPathComponent(LatticeLegacyBrandCompatibility.skillOwnerMarker)
        )
        #expect(try store.deleteSkill(id: "legacy-owned", ownedByExtensionID: "com.lattice.other") == false)
        #expect(try store.deleteSkill(id: "legacy-owned", ownedByExtensionID: "com.lattice.owner"))
    }

    @Test func environmentAliasesPreferLatticeAndFallBackToLegacy() {
        // Pure helper accepts primary over legacy when both are conceptually set by caller.
        #expect(LatticeApplicationSupport.environmentValue(primary: "PATH", legacy: "HOME")?.isEmpty == false)
        #expect(LatticeApplicationSupport.productFolderName == "Lattice")
        #expect(LatticeApplicationSupport.legacyProductFolderName == "Nisa")
        #expect(LatticeLegacyBrandCompatibility.extensionManifestOpeningTag.contains("nisa-extension-manifest"))
    }

    @Test func extensionManifestEnvelopeAcceptsLegacyBrandTags() throws {
        let json = #"{"schemaVersion":1,"id":"com.lattice.legacy","name":"Legacy","version":"1","summary":"Legacy."}"#
        let modern = "<lattice-extension-manifest>\(json)</lattice-extension-manifest>"
        let legacy = "<nisa-extension-manifest>\(json)</nisa-extension-manifest>"
        #expect(try LatticeExtensionManifestEnvelope.decode(from: modern).id == "com.lattice.legacy")
        #expect(try LatticeExtensionManifestEnvelope.decode(from: legacy).id == "com.lattice.legacy")
    }

    @Test func selfEditSlashCommandIsExplicitAndDiscoverable() {
        #expect(LatticeSelfEditCommand.prompt(in: "/self-edit make the composer calmer") == "make the composer calmer")
        #expect(LatticeSelfEditCommand.prompt(in: "/self-editor nope") == nil)
        #expect(LatticeSelfEditCommand.prompt(in: "make Lattice glassy") == nil)
        #expect(LatticeAppCommandCatalog.suggestions(for: "/").first?.invocation == "/self-edit")
        #expect(LatticeAppCommandCatalog.suggestions(for: "/self").first?.id == "self-edit")
        #expect(LatticeAppCommandCatalog.completion(for: "/")?.id == "self-edit")
        #expect(LatticeAppCommandCatalog.completion(for: "/self")?.id == "self-edit")
        #expect(LatticeAppCommandCatalog.suggestions(for: "/self-edit ").isEmpty)
        #expect(LatticeAppCommandCatalog.completion(for: "/self-edit ") == nil)
        #expect(LatticeAppCommandCatalog.suggestions(for: "/self-edit make it calmer").isEmpty)
        #expect(LatticeAppCommandCatalog.suggestions(for: "self-edit").isEmpty)
    }

    @Test func appCommandCatalogCanIncludeExtensionTemplates() {
        let template = LatticePromptTemplate(invocation: "/brief", title: "Brief", detail: "Make concise", prompt: "Make this concise.")
        let commands = LatticeAppCommandCatalog.all + [template.command]
        #expect(LatticeAppCommandCatalog.suggestions(for: "/b", commands: commands).first?.invocation == "/brief")
        #expect(LatticeAppCommandCatalog.completion(for: "/b", commands: commands)?.replacementText == "Make this concise.")
        #expect(LatticeAppCommandCatalog.suggestions(for: "/brief now", commands: commands).isEmpty)
    }

    @Test func appCommandCatalogDeduplicatesExtensionTemplateInvocations() {
        let first = LatticePromptTemplate(invocation: "/brief", title: "Brief", detail: "Make concise", prompt: "Make this concise.")
        let second = LatticePromptTemplate(invocation: "/brief", title: "Brief Again", detail: "Different prompt", prompt: "Use this other prompt.")
        let commands = LatticeAppCommandCatalog.all + [first.command, second.command]
        let suggestions = LatticeAppCommandCatalog.suggestions(for: "/b", commands: commands)
        #expect(suggestions.map(\.title) == ["Brief"])
        #expect(LatticeAppCommandCatalog.completion(for: "/b", commands: commands)?.replacementText == "Make this concise.")
    }

    @Test func commandPaletteMatcherFindsActionsWithoutRunningDisabledItems() {
        let items = [
            LatticeCommandPaletteItem(id: "new-chat", title: "New Chat", detail: "Start a fresh conversation", keywords: ["session"]),
            LatticeCommandPaletteItem(id: "continue", title: "Continue Response", detail: "Resume the selected assistant answer", keywords: ["more"], isEnabled: false, disabledReason: "No completed assistant response"),
            LatticeCommandPaletteItem(id: "models", title: "Show Models", detail: "Review connected provider models", keywords: ["provider catalog"])
        ]

        #expect(LatticeCommandPaletteMatcher.filtered(items, query: "").map(\.id) == ["new-chat", "continue", "models"])
        #expect(LatticeCommandPaletteMatcher.filtered(items, query: "provider models").map(\.id) == ["models"])
        #expect(LatticeCommandPaletteMatcher.filtered(items, query: "fresh session").map(\.id) == ["new-chat"])
        #expect(LatticeCommandPaletteMatcher.firstEnabled(in: items, query: "response") == nil)
        #expect(LatticeCommandPaletteMatcher.firstEnabled(in: items, query: "show")?.id == "models")
    }

    @Test func contextBudgetEstimateIncludesDraftTranscriptAndAttachedPaths() {
        let session = LatticeSession(
            title: "Budget",
            messages: [.init(role: .user, text: String(repeating: "a", count: 40))],
            backend: .codex(model: "gpt-5.4"),
            attachments: [.init(path: "/tmp/Lattice/PLAN.md")]
        )
        let estimate = LatticeContextBudgetEstimator.estimate(session: session, draft: String(repeating: "b", count: 20), tokenLimit: 100)

        #expect(estimate.transcriptTokens > 0)
        #expect(estimate.draftTokens == 5)
        #expect(estimate.attachmentTokens > 8)
        #expect(estimate.status == .comfortable)
        #expect(LatticeContextBudgetEstimate(tokenLimit: 100, transcriptTokens: 75, draftTokens: 0, attachmentTokens: 0).status == .tight)
        #expect(LatticeContextBudgetEstimate(tokenLimit: 100, transcriptTokens: 90, draftTokens: 0, attachmentTokens: 0).status == .nearLimit)
        #expect(LatticeContextBudgetEstimate(tokenLimit: 100, transcriptTokens: 101, draftTokens: 0, attachmentTokens: 0).status == .overLimit)
        #expect(ProviderModelMetadata.contextWindow(from: ["limit": ["context": 200_000]]) == 200_000)
        #expect(ProviderModelMetadata.contextWindow(from: ["contextWindow": "128k"]) == 128_000)
        #expect(LatticeContextBudgetEstimator.tokenLimit(for: .openCode(model: "opencode/qwen3-coder"), openCodeModels: [.init(id: "opencode/qwen3-coder", name: "Qwen3 Coder", contextWindow: 64_000)]) == 64_000)
    }

    @Test func contextHandoffUsesRawPromptForHealthyResumedCLIThread() {
        let session = LatticeSession(
            title: "Resumed",
            messages: [.init(role: .user, text: "Previous"), .init(role: .assistant, text: "Answer"), .init(role: .user, text: "Next"), .init(role: .assistant, text: "")],
            backend: .codex(model: "gpt-5.4"),
            harnessThreadID: "thread-1"
        )
        let plan = LatticeContextHandoffPlanner.plan(session: session, submittedText: "Next", existingHarnessThreadID: session.harnessThreadID, compactionThreshold: 0.95)
        #expect(plan.prompt == "Next")
        #expect(!plan.usesVisibleTranscriptHandoff)
        #expect(!plan.resetsHarnessSession)
    }

    @Test func contextHandoffSendsVisibleTranscriptWhenThreadIsMissing() {
        let session = LatticeSession(
            title: "Restored",
            messages: [.init(role: .user, text: "Original request"), .init(role: .assistant, text: "Original answer"), .init(role: .user, text: "Continue"), .init(role: .assistant, text: "")],
            backend: .openCode(model: "opencode/model")
        )
        let plan = LatticeContextHandoffPlanner.plan(session: session, submittedText: "Continue", additionalContext: "\n\nAttached paths:\n/tmp/a.swift", existingHarnessThreadID: nil)
        #expect(plan.usesVisibleTranscriptHandoff)
        #expect(plan.resetsHarnessSession)
        #expect(!plan.didCompact)
        #expect(plan.prompt.contains("full"))
        #expect(plan.prompt.contains("[User] Original request"))
        #expect(plan.prompt.contains("[Assistant] Original answer"))
        #expect(plan.prompt.contains("Current user request:\nContinue"))
        #expect(plan.prompt.contains("/tmp/a.swift"))
    }

    @Test func resumedCLIKeepsProviderSessionForNativeContextManagement() {
        let old = String(repeating: "older context ", count: 120)
        let session = LatticeSession(
            title: "Large",
            messages: [
                .init(role: .user, text: old),
                .init(role: .assistant, text: old),
                .init(role: .user, text: old),
                .init(role: .assistant, text: old),
                .init(role: .user, text: old),
                .init(role: .assistant, text: "Recent answer"),
                .init(role: .user, text: "Now answer this"),
                .init(role: .assistant, text: "")
            ],
            backend: .grok(model: "grok-code-fast-1"),
            harnessThreadID: "grok-acp:existing"
        )
        let plan = LatticeContextHandoffPlanner.plan(session: session, submittedText: "Now answer this", tokenLimit: 120, existingHarnessThreadID: session.harnessThreadID, compactionThreshold: 0.5)
        #expect(plan.prompt == "Now answer this")
        #expect(!plan.usesVisibleTranscriptHandoff)
        #expect(!plan.didCompact)
        #expect(!plan.resetsHarnessSession)

        let recoveryPlan = LatticeContextHandoffPlanner.plan(session: session, submittedText: "Now answer this", tokenLimit: 120, existingHarnessThreadID: nil, compactionThreshold: 0.5)
        #expect(recoveryPlan.usesVisibleTranscriptHandoff)
        #expect(recoveryPlan.didCompact)
        #expect(recoveryPlan.resetsHarnessSession)
        #expect(recoveryPlan.prompt.contains("Older messages condensed by Lattice"))
        #expect(recoveryPlan.prompt.contains("Current user request:\nNow answer this"))

        let hugeHistory = String(repeating: "Detailed old context that can be safely condensed. ", count: 500)
        let adaptiveSession = LatticeSession(
            title: "Adaptive",
            messages: [
                .init(role: .user, text: hugeHistory),
                .init(role: .assistant, text: hugeHistory),
                .init(role: .user, text: hugeHistory),
                .init(role: .assistant, text: hugeHistory),
                .init(role: .user, text: "Current request"),
                .init(role: .assistant, text: "")
            ],
            backend: .ollama(model: "small")
        )
        let adaptivePlan = LatticeContextHandoffPlanner.plan(
            session: adaptiveSession,
            submittedText: "Please continue with the current task and preserve only the context needed to answer correctly.",
            tokenLimit: 260,
            existingHarnessThreadID: "structured-message-list",
            managementMode: .latticeManagedVisibleTranscript,
            compactionThreshold: 0.5
        )
        #expect(adaptivePlan.didCompact)
        #expect(adaptivePlan.deliveryIssue == nil)
        #expect(LatticeContextBudgetEstimator.estimateTokens(in: adaptivePlan.prompt) < 260)
    }

    @Test func roundTripsCanonicalSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let response = ChatMessage(role: .assistant, text: "Done")
        let action = SessionAction(messageID: response.id, kind: .tool, toolKind: .write, title: "Edit file", detail: "file.txt", status: .completed, workspaceScoped: true)
        let session = LatticeSession(
            title: "Persistent chat",
            messages: [.init(role: .user, text: "Hello"), response],
            backend: .codex(model: "gpt-5.4"),
            harnessID: "pi",
            harnessThreadID: "thread-1",
            workspacePath: "/tmp/project",
            attachments: [.init(path: "/tmp/file.txt")],
            privacyMode: .localOnly,
            actions: [action],
            draft: "unsent ordinary draft\nwith newline",
            isPinned: true
        )
        try store.save([session])
        let restored = try store.load()
        var persistedSession = session
        persistedSession.harnessThreadID = nil
        #expect(restored == [persistedSession])
        #expect(restored.first?.privacyMode == .localOnly)
        #expect(restored.first?.isPinned == true)
        #expect(restored.first?.draft == "unsent ordinary draft\nwith newline")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func failedSidecarCommitCleansOnlyFilesCreatedByThatAttempt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL)
        let original = LatticeSession(
            title: "Sidecar cleanup",
            messages: [.init(role: .user, text: "original")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([original])
        let manifestBefore = try Data(contentsOf: fileURL)
        let transcriptNamesBefore = try sidecarNames(in: store.transcriptDirectoryURL)

        var changed = original
        changed.messages = [.init(role: .user, text: "changed")]
        let searchIndexProbe = SaveFailureProbe(target: .searchIndex, searchIndexURL: store.searchIndexURL, manifestURL: fileURL)
        let failingIndexStore = SessionPersistence(fileURL: fileURL, io: searchIndexProbe.io)
        _ = failingIndexStore.loadLazyResult()
        #expect(throws: Error.self) {
            try failingIndexStore.save([changed])
        }
        #expect(try Data(contentsOf: fileURL) == manifestBefore)
        #expect(try sidecarNames(in: store.transcriptDirectoryURL) == transcriptNamesBefore)

        let manifestProbe = SaveFailureProbe(target: .manifest, searchIndexURL: store.searchIndexURL, manifestURL: fileURL)
        let failingManifestStore = SessionPersistence(fileURL: fileURL, io: manifestProbe.io)
        _ = failingManifestStore.loadLazyResult()
        #expect(throws: Error.self) {
            try failingManifestStore.save([changed])
        }
        // The manifest is still the last known-good commit. A thrown manifest write with a
        // mismatching payload is ambiguous, so the new sidecar must be retained in case the
        // adapter published a manifest that could not be confirmed.
        #expect(try Data(contentsOf: fileURL) == manifestBefore)
        #expect(try sidecarNames(in: store.transcriptDirectoryURL).count == transcriptNamesBefore.count + 1)
        // Reload uses the authoritative manifest and repairs any index that was committed
        // before the manifest failure; it must never try to resolve the removed sidecar.
        #expect(try store.load().first?.messages == original.messages)

        try store.save([changed])
        #expect(try sidecarNames(in: store.transcriptDirectoryURL).count == 1)
        #expect(try store.load().first?.messages == changed.messages)
    }

    @Test func invalidExistingSidecarIsValidatedAndRepaired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL)
        let session = LatticeSession(
            title: "Repair sidecar",
            messages: [.init(role: .user, text: "durable")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        let sidecar = try #require(try FileManager.default.contentsOfDirectory(
            at: store.transcriptDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first)
        try Data("{corrupt".utf8).write(to: sidecar, options: .atomic)

        // The deterministic filename is retained, but bytes are not trusted merely because
        // the name contains a matching fingerprint prefix.
        try store.save([session])
        #expect(try store.load().first?.messages == session.messages)
        let repaired = try Data(contentsOf: sidecar)
        #expect(try JSONDecoder().decode([ChatMessage].self, from: repaired).count == 1)
        let reference = try #require(store.loadLazyResult().value?.sessions.first?.transcriptStorage)
        #expect(DurableStoreRecovery.contentFingerprint(for: repaired) == reference.contentFingerprint)
    }

    @Test func writeThenThrowAfterManifestPublishIsConfirmedAsSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL)
        let original = LatticeSession(
            title: "Publish confirmation",
            messages: [.init(role: .user, text: "before")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([original])
        var changed = original
        changed.messages = [.init(role: .user, text: "after")]
        let io = DurableStoreFileIO(writeDataAtomically: { data, url in
            try data.write(to: url, options: .atomic)
            if url.lastPathComponent == SessionPersistence.fileName {
                throw NSError(domain: "SessionPersistenceTests", code: 99)
            }
        })

        // The adapter reports an error after replacing the manifest. Exact-byte confirmation
        // must treat this as a committed save, preserving the newly referenced sidecar.
        let throwingStore = SessionPersistence(fileURL: fileURL, io: io)
        _ = throwingStore.loadLazyResult()
        try throwingStore.save([changed])
        #expect(try store.load().first?.messages == changed.messages)
        #expect(try sidecarNames(in: store.transcriptDirectoryURL).count == 1)
    }

    @Test func orphanCleanupDoesNotTrustInjectedDirectoryListing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let listingCalls = LockedCounter()
        let io = DurableStoreFileIO(contentsOfDirectory: { _ in
            listingCalls.increment()
            return []
        })
        let store = SessionPersistence(fileURL: fileURL, io: io)
        let session = LatticeSession(title: "Listing", backend: .codex(model: "gpt-5.4"))
        try store.save([session])
        let orphan = store.transcriptDirectoryURL.appendingPathComponent("orphan.json")
        try Data("orphan".utf8).write(to: orphan)
        try store.save([session])
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(listingCalls.value == 0)
    }

    @Test func lazyIndexRepairWaitsForAnInFlightSaveTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DurableStoreWriteGate()
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL, writeGate: gate)
        try store.save([LatticeSession(
            title: "Index repair",
            messages: [.init(role: .user, text: "hydrate")],
            backend: .codex(model: "gpt-5.4")
        )])
        try FileManager.default.removeItem(at: store.searchIndexURL)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            gate.withExclusiveWrite {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = store.loadLazyResult()
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut)
        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(FileManager.default.fileExists(atPath: store.searchIndexURL.path))
    }

    @Test func perChatComposerDraftsRoundTripIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let chatA = LatticeSession(title: "A", backend: .codex(model: "gpt-5.4"), draft: "alpha\n  spaced  ")
        let chatB = LatticeSession(title: "B", backend: .codex(model: "gpt-5.4"), draft: "")
        try store.save([chatA, chatB])
        let restored = try store.load()
        #expect(restored.first(where: { $0.id == chatA.id })?.draft == "alpha\n  spaced  ")
        #expect(restored.first(where: { $0.id == chatB.id })?.draft == "")
        try? FileManager.default.removeItem(at: root)
    }

    private func sidecarNames(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent))
    }

    private final class SaveFailureProbe: @unchecked Sendable {
        enum Target: Sendable, Equatable { case searchIndex, manifest }
        let target: Target
        let searchIndexURL: URL
        let manifestURL: URL

        init(target: Target, searchIndexURL: URL, manifestURL: URL) {
            self.target = target
            self.searchIndexURL = searchIndexURL
            self.manifestURL = manifestURL
        }

        var io: DurableStoreFileIO {
            DurableStoreFileIO(writeDataAtomically: { data, url in
                if (self.target == .searchIndex && url == self.searchIndexURL)
                    || (self.target == .manifest && url == self.manifestURL) {
                    throw NSError(domain: "SessionPersistenceTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected write failure"])
                }
                try data.write(to: url, options: .atomic)
            })
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    @Test func decodesLegacySessionWithoutActionsQueueOrPin() throws {
        let session = LatticeSession(title: "Legacy", backend: .codex(model: "gpt-5.4"))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object["actions"] = nil
        object["queuedFollowUps"] = nil
        object["isPinned"] = nil
        object["privacyMode"] = nil
        object["draft"] = nil
        let decoded = try JSONDecoder().decode(LatticeSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.actions.isEmpty)
        #expect(decoded.queuedFollowUps.isEmpty)
        #expect(decoded.isPinned == false)
        #expect(decoded.privacyMode == .cloudAllowed)
        #expect(decoded.draft == "")
    }

    @Test func sessionPrivacyPolicyAllowsOnlyLocalBackendsInLocalOnlyMode() {
        #expect(SessionPrivacyPolicy.allows(.codex(model: "gpt-5.5"), in: .cloudAllowed))
        #expect(!SessionPrivacyPolicy.allows(.codex(model: "gpt-5.5"), in: .localOnly))
        #expect(!SessionPrivacyPolicy.allows(.grok(model: "grok"), in: .localOnly))
        #expect(SessionPrivacyPolicy.allows(.appleIntelligence, in: .localOnly))
        #expect(SessionPrivacyPolicy.allows(.ollama(model: "llama3.2:latest"), in: .localOnly))
        #expect(SessionPrivacyPolicy.blockedMessage(for: .openCode(model: "opencode/model"), in: .localOnly)?.contains("Local-only") == true)
    }

    @Test func pinnedMessagesPersistAndLegacyMessagesDefaultToUnpinned() throws {
        let message = ChatMessage(role: .assistant, text: "Important answer", isPinned: true)
        let encoded = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: encoded).isPinned)

        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["isPinned"] = nil
        let decodedLegacy = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decodedLegacy.isPinned == false)
    }

    @Test func pinnedSessionsSortBeforeNewerUnpinnedSessions() {
        let olderPinned = LatticeSession(title: "Pinned", backend: .codex(model: "gpt-5.4"), isPinned: true, lastUpdated: Date(timeIntervalSince1970: 1))
        let newerUnpinned = LatticeSession(title: "Recent", backend: .codex(model: "gpt-5.4"), lastUpdated: Date(timeIntervalSince1970: 2))
        #expect(LatticeSessionListOrdering.sorted([newerUnpinned, olderPinned]).map(\.id) == [olderPinned.id, newerUnpinned.id])
    }

    @Test func restoresStreamingSessionsAsStopped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let session = LatticeSession(title: "Interrupted", backend: .ollama(model: "qwen3:8b"), isStreaming: true)
        try store.save([session])
        #expect(try store.load().first?.isStreaming == false)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func restoresPendingActionsAsInterrupted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let response = ChatMessage(role: .assistant, text: "Partial response")
        let action = SessionAction(messageID: response.id, kind: .tool, toolKind: .command, title: "Build", detail: "$ swift build", status: .running)
        try store.save([LatticeSession(title: "Interrupted", messages: [response], backend: .codex(model: "gpt-5.4"), actions: [action], isStreaming: true)])
        let restored = try #require(try store.load().first)
        #expect(restored.isStreaming == false)
        #expect(restored.actions.first?.status == .interrupted)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func completedTurnClosesOpenActionsTruthfully() {
        let response = ChatMessage(role: .assistant, text: "Done")
        var actions = [
            SessionAction(messageID: response.id, kind: .tool, toolKind: .command, title: "Build", detail: "$ swift build", status: .running),
            SessionAction(messageID: response.id, kind: .approval, title: "Allow edit", detail: "Sources/App.swift", status: .waiting),
            SessionAction(messageID: response.id, kind: .tool, toolKind: .write, title: "Patch", detail: "Sources/App.swift", status: .failed),
            SessionAction(messageID: response.id, kind: .plan, title: "Plan", detail: "Inspect\nEdit", status: .running),
            SessionAction(messageID: response.id, kind: .reasoning, title: "Reasoning summary", detail: "Checking the result", status: .running)
        ]
        #expect(SessionActionTrail.finishCompletedTurn(for: response.id, in: &actions) == 4)
        #expect(actions.map(\.status) == [.completed, .cancelled, .failed, .completed, .completed])
    }

    @Test func reasoningSummaryDeltasAppendToDurableActionDetail() {
        let response = ChatMessage(role: .assistant, text: "Working")
        let action = SessionAction(messageID: response.id, kind: .reasoning, title: "Reasoning summary", detail: "Inspect", status: .running)
        var actions = [action]

        let appended = SessionActionTrail.appendDetail(id: action.id, delta: " then verify", in: &actions)
        let ignored = SessionActionTrail.appendDetail(id: UUID(), delta: "ignored", in: &actions)
        #expect(appended)
        #expect(actions[0].detail == "Inspect then verify")
        #expect(!ignored)
    }

    @Test func codexProjectsPlansAndSafeReasoningSummaries() {
        let workspace = URL(fileURLWithPath: "/tmp/Lattice")
        let reasoning: [String: Any] = [
            "method": "item/reasoning/summaryTextDelta",
            "params": ["itemId": "reasoning-1", "delta": "I’ll inspect the relevant view."]
        ]
        if case .reasoningSummary(_, let delta)? = CodexExecHarness.appServerEvent(from: reasoning, workspace: workspace) {
            #expect(delta == "I’ll inspect the relevant view.")
        } else {
            Issue.record("Expected a Codex reasoning summary event")
        }

        let privateReasoning: [String: Any] = [
            "method": "item/reasoning/textDelta",
            "params": ["itemId": "reasoning-1", "delta": "private chain of thought"]
        ]
        #expect(CodexExecHarness.appServerEvent(from: privateReasoning, workspace: workspace) == nil)

        let plan: [String: Any] = [
            "method": "turn/plan/updated",
            "params": [
                "turnId": "turn-1",
                "explanation": "Updating the chat surface",
                "plan": [
                    ["step": "Inspect", "status": "completed"],
                    ["step": "Verify", "status": "inProgress"]
                ]
            ]
        ]
        if case .plan(_, let title, let explanation, let steps)? = CodexExecHarness.appServerEvent(from: plan, workspace: workspace) {
            #expect(title == "Plan")
            #expect(explanation == "Updating the chat surface")
            #expect(steps.map(\.title) == ["Inspect", "Verify"])
            #expect(steps.map(\.status) == [.completed, .inProgress])
        } else {
            Issue.record("Expected a Codex plan event")
        }
    }

    @Test func unknownAndMalformedProviderEventsBecomeSafeDiagnostics() {
        let workspace = URL(fileURLWithPath: "/tmp/Lattice")
        let unknownPi: [String: Any] = ["type": "future_provider_event", "secret": "must not be retained"]
        if case .providerDiagnostic(let diagnostic)? = HarnessToolEventDecoder.piEvent(from: unknownPi, workspace: workspace) {
            #expect(diagnostic.provider == "Lattice Agent")
            #expect(diagnostic.eventType == "future_provider_event")
            #expect(!diagnostic.detail.contains("must not be retained"))
        } else { Issue.record("Unknown Pi event must remain observable as a diagnostic") }

        let malformedPi: [String: Any] = ["type": "tool_execution_start", "toolName": "read"]
        if case .providerDiagnostic(let diagnostic)? = HarnessToolEventDecoder.piEvent(from: malformedPi, workspace: workspace) {
            #expect(diagnostic.reason.contains("toolCallId"))
        } else { Issue.record("Malformed Pi event must remain observable as a diagnostic") }

        let unknownHermes: [String: Any] = ["method": "session/update", "params": ["update": ["sessionUpdate": "future_update", "toolCallId": "tool-1"]]]
        if case .providerDiagnostic(let diagnostic)? = HarnessToolEventDecoder.hermesEvent(from: unknownHermes, workspace: workspace) {
            #expect(diagnostic.provider == "Hermes")
            #expect(diagnostic.eventType == "future_update")
        } else { Issue.record("Unknown Hermes event must remain observable as a diagnostic") }

        let unknownCodex: [String: Any] = ["method": "item/started", "params": ["item": ["id": "item-1", "type": "future_item"]]]
        if case .providerDiagnostic(let diagnostic) = CodexExecHarness.appServerEvent(from: unknownCodex, workspace: workspace) {
            #expect(diagnostic.provider == "Codex")
            #expect(diagnostic.eventType == "future_item")
        } else { Issue.record("Unknown Codex event must remain observable as a diagnostic") }

        if case .providerDiagnostic(let diagnostic) = HarnessToolEventDecoder.malformedEvent(provider: "Hermes", byteCount: 7) {
            #expect(diagnostic.detail.contains("7 bytes"))
        } else { Issue.record("Malformed JSON must remain observable as a diagnostic") }
    }

    @Test func providerDiagnosticPersistsAndReplayKeepsFailureStatus() throws {
        let response = ChatMessage(role: .assistant, text: "Partial response")
        let action = SessionAction(messageID: response.id, kind: .diagnostic, title: "Pi provider event not understood", detail: "Unsupported event", status: .failed)
        let session = LatticeSession(title: "Diagnostic", messages: [response], backend: .codex(model: "gpt-5.4"), actions: [action])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        try store.save([session])
        let restored = try #require(try store.load().first)
        #expect(restored.actions.first?.kind == .diagnostic)
        #expect(restored.actions.first?.status == .failed)
        var actions = restored.actions
        #expect(SessionActionTrail.finishCompletedTurn(for: response.id, in: &actions) == 0)
        #expect(actions.first?.status == .failed)

        let archive = try SessionPortableArchiveExporter.exportData(from: session)
        let imported = try SessionPortableArchiveImporter.prepareImport(data: archive, existingSessions: []).session
        #expect(imported.actions.count == 1)
        #expect(imported.actions.first?.kind == .diagnostic)
        #expect(imported.actions.first?.status == .failed)
        #expect(imported.actions.first?.title == "Provider event diagnostic")
        #expect(imported.actions.first?.detail == "")
    }

    @Test func providerDiagnosticActivitySurvivesWithoutAssistantActionTarget() {
        let diagnostic = ProviderEventDiagnostic(provider: "Lattice Agent", eventType: "future_event", reason: "Unsupported event.")
        #expect(ProviderDiagnosticRetentionPolicy.action(for: diagnostic, assistantMessageID: nil) == nil)

        let assistantID = UUID()
        let action = ProviderDiagnosticRetentionPolicy.action(for: diagnostic, assistantMessageID: assistantID)
        #expect(action?.messageID == assistantID)
        #expect(action?.kind == .diagnostic)
        #expect(action?.status == .failed)
    }

    @Test func deletingMessageTruncatesBranchAndProviderState() {
        let firstUser = ChatMessage(role: .user, text: "First")
        let firstAssistant = ChatMessage(role: .assistant, text: "First reply", isPinned: true)
        let secondUser = ChatMessage(role: .user, text: "Second")
        let secondAssistant = ChatMessage(role: .assistant, text: "Second reply")
        let retainedAction = SessionAction(messageID: firstAssistant.id, kind: .tool, title: "Read", detail: "README.md", status: .completed)
        let removedAction = SessionAction(messageID: secondAssistant.id, kind: .tool, title: "Write", detail: "README.md", status: .completed)
        var session = LatticeSession(
            title: "First",
            messages: [firstUser, firstAssistant, secondUser, secondAssistant],
            backend: .codex(model: "gpt-5.4"),
            harnessThreadID: "provider-thread",
            actions: [retainedAction, removedAction]
        )

        #expect(SessionTranscriptMutation.deleteMessageAndFollowing(messageID: secondUser.id, in: &session))
        #expect(session.messages.map(\.id) == [firstUser.id, firstAssistant.id])
        #expect(session.actions == [retainedAction])
        #expect(session.harnessThreadID == nil)
        #expect(!SessionTranscriptMutation.deleteMessageAndFollowing(messageID: UUID(), in: &session))
    }

    @Test func branchingCopiesVisibleTranscriptAndResetsProviderState() throws {
        let firstUser = ChatMessage(role: .user, text: "First")
        let firstAssistant = ChatMessage(role: .assistant, text: "First reply", isPinned: true)
        let secondUser = ChatMessage(role: .user, text: "Second")
        let secondAssistant = ChatMessage(role: .assistant, text: "Second reply")
        let retainedAction = SessionAction(messageID: firstAssistant.id, kind: .tool, title: "Read", detail: "README.md", status: .completed)
        let removedAction = SessionAction(messageID: secondAssistant.id, kind: .tool, title: "Write", detail: "README.md", status: .completed)
        let session = LatticeSession(
            title: "Source",
            messages: [firstUser, firstAssistant, secondUser, secondAssistant],
            backend: .codex(model: "gpt-5.4"),
            executionRoute: ExecutionRoute(
                mode: .code,
                providerID: "codex",
                modelID: "gpt-5.4",
                runtimeID: "codex"
            ),
            harnessID: "pi",
            harnessThreadID: "provider-thread",
            workspacePath: "/tmp/Lattice",
            attachments: [.init(path: "/tmp/Lattice/PLAN.md")],
            policy: .smart,
            privacyMode: .localOnly,
            actions: [retainedAction, removedAction],
            queuedFollowUps: [.init(text: "Later")],
            draft: "source ordinary draft",
            isPinned: true
        )

        let branch = try #require(SessionTranscriptMutation.branchFromMessage(messageID: secondUser.id, in: session))
        #expect(branch.id != session.id)
        #expect(branch.title.hasPrefix("Branch:"))
        #expect(branch.messages.map(\.id) == [firstUser.id, firstAssistant.id, secondUser.id])
        #expect(branch.messages.first(where: { $0.id == firstAssistant.id })?.isPinned == true)
        #expect(branch.actions == [retainedAction])
        #expect(branch.harnessThreadID == nil)
        #expect(branch.backend == session.backend)
        #expect(branch.executionRoute == session.executionRoute)
        #expect(branch.harnessID == session.harnessID)
        #expect(branch.workspacePath == session.workspacePath)
        #expect(branch.policy == session.policy)
        #expect(branch.privacyMode == session.privacyMode)
        #expect(branch.attachments == session.attachments)
        #expect(branch.queuedFollowUps.isEmpty)
        // Branch deliberately starts empty rather than copying the source unsent draft.
        #expect(branch.draft == "")
        #expect(!branch.isPinned)
        #expect(!branch.isStreaming)
        #expect(SessionTranscriptMutation.branchFromMessage(messageID: UUID(), in: session) == nil)
        #expect(SessionTranscriptMutation.branchFromMessage(messageID: firstUser.id, in: LatticeSession(title: "Running", messages: [firstUser], backend: .codex(model: "gpt-5.4"), isStreaming: true)) == nil)
    }

    @Test func branchAndDeleteRequireMaterializedTranscriptAndArtifacts() {
        let user = ChatMessage(role: .user, text: "Keep me")
        let transcriptReference = SessionTranscriptStorage(
            fileName: "placeholder.json",
            messageCount: 1,
            contentFingerprint: "fingerprint"
        )
        let artifactReference = SessionArtifactStorage(
            fileName: "placeholder.json",
            artifactCount: 1,
            contentFingerprint: "fingerprint"
        )
        var unloadedTranscript = LatticeSession(
            title: "Lazy transcript",
            messages: [],
            transcriptStorage: transcriptReference,
            isTranscriptLoaded: false,
            backend: .codex(model: "gpt-5.4")
        )
        let transcriptSnapshot = unloadedTranscript
        #expect(!SessionTranscriptMutation.canMutateContent(in: unloadedTranscript))
        #expect(SessionTranscriptMutation.branchFromMessage(messageID: user.id, in: unloadedTranscript) == nil)
        #expect(!SessionTranscriptMutation.deleteMessageAndFollowing(messageID: user.id, in: &unloadedTranscript))
        #expect(unloadedTranscript == transcriptSnapshot)

        var unloadedArtifacts = LatticeSession(
            title: "Lazy artifacts",
            messages: [user],
            artifacts: [],
            artifactStorage: artifactReference,
            isArtifactsLoaded: false,
            backend: .codex(model: "gpt-5.4")
        )
        let artifactSnapshot = unloadedArtifacts
        #expect(!SessionTranscriptMutation.canMutateContent(in: unloadedArtifacts))
        #expect(SessionTranscriptMutation.branchFromMessage(messageID: user.id, in: unloadedArtifacts) == nil)
        #expect(!SessionTranscriptMutation.deleteMessageAndFollowing(messageID: user.id, in: &unloadedArtifacts))
        #expect(unloadedArtifacts == artifactSnapshot)
    }

    @Test func deletingFirstUserTurnRestoresUnstartedChat() {
        let user = ChatMessage(role: .user, text: "Change Lattice")
        var session = LatticeSession(
            title: "Lattice self-edit",
            messages: [user, .init(role: .assistant, text: "Done")],
            backend: .grok(model: "grok"),
            intent: .selfEdit
        )

        #expect(SessionTranscriptMutation.deleteMessageAndFollowing(messageID: user.id, in: &session))
        #expect(session.messages.isEmpty)
        #expect(session.title == "New chat")
        #expect(session.intent == nil)
    }

    @Test func sessionSearchIncludesMessagesActionsAttachmentsAndRoute() {
        let assistant = ChatMessage(role: .assistant, text: "I checked the build.")
        let action = SessionAction(
            messageID: assistant.id,
            kind: .tool,
            toolKind: .command,
            title: "Run verifier",
            detail: "swift verify_core emitted sandbox denial details",
            status: .completed,
            workspaceScoped: true
        )
        let session = LatticeSession(
            title: "Release audit",
            messages: [.init(role: .user, text: "Ship check"), assistant],
            backend: .openCode(model: "opencode/qwen3-coder"),
            harnessID: "hermes",
            workspacePath: "/tmp/Lattice",
            attachments: [.init(path: "/tmp/Lattice/PLAN.md")],
            actions: [action]
        )

        #expect(session.matchesSearch("release audit"))
        #expect(session.matchesSearch("sandbox denial"))
        #expect(session.matchesSearch("PLAN.md"))
        #expect(session.matchesSearch("hermes qwen3"))
        #expect(!session.matchesSearch("unrelated token"))
    }

    @Test func sessionSearchIncludesPinnedMessageState() {
        let session = LatticeSession(
            title: "Pinned transcript",
            messages: [.init(role: .assistant, text: "Keep this answer", isPinned: true)],
            backend: .codex(model: "gpt-5.4")
        )

        #expect(session.matchesSearch("pinned answer"))
    }

    @Test func oversizedTranscriptIsRejectedBeforeAnyDurableWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL)
        let original = LatticeSession(
            title: "Bounded",
            messages: [.init(role: .user, text: "small")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([original])
        let manifestBefore = try Data(contentsOf: fileURL)
        let indexBefore = try Data(contentsOf: store.searchIndexURL)
        let sidecarsBefore = try sidecarNames(in: store.transcriptDirectoryURL)

        var oversized = original
        oversized.messages = [.init(
            role: .user,
            text: String(
                repeating: "x",
                count: DurableStoreRecovery.maximumStoreByteCount + 1_024
            )
        )]
        #expect(throws: SessionPersistenceStorageError.self) {
            try store.save([oversized])
        }

        var oversizedManifest = original
        oversizedManifest.draft = String(
            repeating: "d",
            count: DurableStoreRecovery.maximumStoreByteCount + 1_024
        )
        #expect(throws: SessionPersistenceStorageError.self) {
            try store.save([oversizedManifest])
        }

        #expect(try Data(contentsOf: fileURL) == manifestBefore)
        #expect(try Data(contentsOf: store.searchIndexURL) == indexBefore)
        #expect(try sidecarNames(in: store.transcriptDirectoryURL) == sidecarsBefore)
        #expect(try store.load().first?.messages == original.messages)
    }

    @Test func ambiguousWrongManifestPublicationPreservesPossiblyReferencedSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let seed = SessionPersistence(fileURL: fileURL)
        let original = LatticeSession(
            title: "Ambiguous publication",
            messages: [.init(role: .user, text: "before")],
            backend: .codex(model: "gpt-5.4")
        )
        try seed.save([original])
        let sidecarsBefore = try sidecarNames(in: seed.transcriptDirectoryURL)
        let wrongManifest = Data("published bytes are not the requested manifest".utf8)
        let ambiguousIO = DurableStoreFileIO(writeDataAtomically: { data, url in
            if url == fileURL {
                try wrongManifest.write(to: url, options: .atomic)
                throw NSError(domain: "SessionPersistenceTests", code: 301)
            }
            try data.write(to: url, options: .atomic)
        })
        let writer = SessionPersistence(fileURL: fileURL, io: ambiguousIO)
        _ = writer.loadLazyResult()
        var changed = original
        changed.messages = [.init(role: .user, text: "after")]

        #expect(throws: Error.self) {
            try writer.save([changed])
        }
        #expect(try Data(contentsOf: fileURL) == wrongManifest)
        #expect(try sidecarNames(in: seed.transcriptDirectoryURL).count == sidecarsBefore.count + 1)
    }

    @Test func durabilityUnconfirmedManifestIsNotDowngradedToSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let seed = SessionPersistence(fileURL: fileURL)
        let original = LatticeSession(
            title: "Durability",
            messages: [.init(role: .user, text: "before")],
            backend: .codex(model: "gpt-5.4")
        )
        try seed.save([original])
        let uncertainIO = DurableStoreFileIO(writeDataAtomically: { data, url in
            try data.write(to: url, options: .atomic)
            if url == fileURL {
                throw LatticeStorePathError.publishedButDurabilityUnconfirmed(url, EIO)
            }
        })
        let writer = SessionPersistence(fileURL: fileURL, io: uncertainIO)
        _ = writer.loadLazyResult()
        var changed = original
        changed.messages = [.init(role: .user, text: "published but sync failed")]

        #expect(throws: Error.self) {
            try writer.save([changed])
        }
        #expect(try sidecarNames(in: seed.transcriptDirectoryURL).count == 2)
        #expect(try SessionPersistence(fileURL: fileURL).load().first?.messages == changed.messages)
    }

    @Test func everyLazySidecarIsValidatedBeforeManifestPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL)
        let response = ChatMessage(role: .assistant, text: "artifact response")
        let artifact = AssistantArtifact(
            messageID: response.id,
            status: .available,
            displayName: "proof.png",
            mimeType: "image/png",
            byteCount: 1,
            canonicalPath: "/tmp/proof.png",
            provenance: .init(provider: "test", origin: .structuredToolResult)
        )
        let session = LatticeSession(
            title: "Lazy validation",
            messages: [response],
            artifacts: [artifact],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        let lazy = try #require(store.loadLazyResult().value?.sessions.first)
        let transcriptReference = try #require(lazy.transcriptStorage)
        let artifactReference = try #require(lazy.artifactStorage)
        let transcriptURL = store.transcriptDirectoryURL.appendingPathComponent(transcriptReference.fileName)
        let artifactURL = store.artifactDirectoryURL.appendingPathComponent(artifactReference.fileName)
        let transcriptBytes = try Data(contentsOf: transcriptURL)
        let artifactBytes = try Data(contentsOf: artifactURL)
        let manifestBefore = try Data(contentsOf: fileURL)

        try FileManager.default.removeItem(at: transcriptURL)
        #expect(throws: Error.self) { try store.save([lazy]) }
        #expect(try Data(contentsOf: fileURL) == manifestBefore)
        try transcriptBytes.write(to: transcriptURL, options: .atomic)

        try Data("corrupt transcript".utf8).write(to: transcriptURL, options: .atomic)
        #expect(throws: Error.self) { try store.save([lazy]) }
        #expect(try Data(contentsOf: fileURL) == manifestBefore)
        try transcriptBytes.write(to: transcriptURL, options: .atomic)

        try FileManager.default.removeItem(at: artifactURL)
        #expect(throws: Error.self) { try store.save([lazy]) }
        #expect(try Data(contentsOf: fileURL) == manifestBefore)
        try artifactBytes.write(to: artifactURL, options: .atomic)

        try Data("corrupt artifact metadata".utf8).write(to: artifactURL, options: .atomic)
        #expect(throws: Error.self) { try store.save([lazy]) }
        #expect(try Data(contentsOf: fileURL) == manifestBefore)
    }

    @Test func independentStaleWriterCannotReplaceNewerManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let seed = SessionPersistence(fileURL: fileURL)
        let original = LatticeSession(
            title: "Original",
            messages: [.init(role: .user, text: "original")],
            backend: .codex(model: "gpt-5.4")
        )
        try seed.save([original])

        let firstWriter = SessionPersistence(fileURL: fileURL)
        let staleWriter = SessionPersistence(fileURL: fileURL)
        _ = firstWriter.loadLazyResult()
        _ = staleWriter.loadLazyResult()
        var firstChange = original
        firstChange.title = "First writer won"
        try firstWriter.save([firstChange])
        var staleChange = original
        staleChange.title = "Stale writer"

        do {
            try staleWriter.save([staleChange])
            Issue.record("A stale writer replaced a newer session manifest")
        } catch let error as SessionPersistenceConflictError {
            #expect(error == .staleWriter(path: fileURL.path))
        }
        #expect(try SessionPersistence(fileURL: fileURL).load().first?.title == "First writer won")
    }

    @Test func copiedPersistenceValuesShareOptimisticRevisionState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL)
        let copiedStore = store
        let first = LatticeSession(title: "First", backend: .codex(model: "gpt-5.4"))
        try store.save([first])
        var second = first
        second.title = "Second"

        try copiedStore.save([second])
        #expect(try store.load().first?.title == "Second")
    }

    @Test func indexRepairFailureReturnsSessionsWithConservativeSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let seed = SessionPersistence(fileURL: fileURL)
        let session = LatticeSession(
            title: "Still visible",
            messages: [.init(role: .user, text: "indexed needle")],
            backend: .codex(model: "gpt-5.4")
        )
        try seed.save([session])
        try FileManager.default.removeItem(at: seed.searchIndexURL)
        let repairIO = DurableStoreFileIO(writeDataAtomically: { data, url in
            if url.lastPathComponent == SessionPersistence.searchIndexFileName {
                throw NSError(domain: "SessionPersistenceTests", code: 401)
            }
            try data.write(to: url, options: .atomic)
        })

        let result = SessionPersistence(fileURL: fileURL, io: repairIO).loadLazyResult()
        let snapshot = try #require(result.value)
        #expect(snapshot.sessions.map(\.id) == [session.id])
        #expect(snapshot.indexWarning?.kind == .repairFailed)
        let allIDs = Set(snapshot.sessions.map(\.id))
        #expect(snapshot.searchIndex.candidateSessionIDs(for: "definitely absent", allSessionIDs: allIDs) == allIDs)
    }

    @Test func corruptedGramSetCannotHideAConversationAndIsRepaired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL)
        let session = LatticeSession(
            title: "Search integrity",
            messages: [.init(role: .user, text: "needle in transcript")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        var corrupted = try JSONDecoder().decode(
            SessionSearchIndex.self,
            from: Data(contentsOf: store.searchIndexURL)
        )
        let entry = try #require(corrupted.entries[session.id])
        corrupted.entries[session.id] = SessionSearchIndex.Entry(
            transcriptFingerprint: entry.transcriptFingerprint,
            metadataFingerprint: entry.metadataFingerprint,
            gramHashes: [],
            integrityChecksum: entry.integrityChecksum
        )
        try JSONEncoder().encode(corrupted).write(to: store.searchIndexURL, options: .atomic)
        let allIDs: Set<UUID> = [session.id]
        #expect(!corrupted.hasValidIntegrity)
        #expect(corrupted.candidateSessionIDs(for: "absent", allSessionIDs: allIDs) == allIDs)

        let repaired = try #require(store.loadLazyResult().value)
        #expect(repaired.indexWarning == nil)
        #expect(repaired.searchIndex.hasValidIntegrity)
        #expect(repaired.searchIndex.candidateSessionIDs(for: "needle", allSessionIDs: allIDs) == allIDs)
        let onDisk = try JSONDecoder().decode(
            SessionSearchIndex.self,
            from: Data(contentsOf: store.searchIndexURL)
        )
        #expect(onDisk.hasValidIntegrity)
    }

    @Test func lazyReferenceRequiresExactUUIDAndFingerprintPrefixFileName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let store = SessionPersistence(fileURL: fileURL)
        let session = LatticeSession(
            title: "Strict reference",
            messages: [.init(role: .user, text: "durable")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        var lazy = try #require(store.loadLazyResult().value?.sessions.first)
        let reference = try #require(lazy.transcriptStorage)
        lazy.transcriptStorage = SessionTranscriptStorage(
            fileName: "\(session.id.uuidString.uppercased())-\(reference.contentFingerprint.prefix(16)).json",
            messageCount: reference.messageCount,
            contentFingerprint: reference.contentFingerprint,
            lastMessagePreview: reference.lastMessagePreview
        )
        let manifestBefore = try Data(contentsOf: fileURL)

        #expect(throws: SessionTranscriptStoreError.self) {
            try store.save([lazy])
        }
        #expect(try Data(contentsOf: fileURL) == manifestBefore)
    }

    @Test func orphanCleanupRemovesOnlyRegularNoFollowJSONFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent(SessionPersistence.fileName))
        let session = LatticeSession(title: "Cleanup", backend: .codex(model: "gpt-5.4"))
        try store.save([session])
        let regular = store.transcriptDirectoryURL.appendingPathComponent("regular-orphan.json")
        let directory = store.transcriptDirectoryURL.appendingPathComponent("directory-orphan.json", isDirectory: true)
        let unrelated = store.transcriptDirectoryURL.appendingPathComponent("notes.txt")
        let target = root.appendingPathComponent("symlink-target.txt")
        let link = store.transcriptDirectoryURL.appendingPathComponent("symlink-orphan.json")
        try Data("regular".utf8).write(to: regular)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: unrelated)
        try Data("target must survive".utf8).write(to: target)
        #expect(symlink(target.path, link.path) == 0)

        try store.save([session])
        #expect(!FileManager.default.fileExists(atPath: regular.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "unrelated")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "target must survive")
    }

    @Test func manifestAndSidecarDirectorySymlinksFailClosed() throws {
        let manifestRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: manifestRoot) }
        try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
        let target = manifestRoot.appendingPathComponent("target.json")
        let manifest = manifestRoot.appendingPathComponent(SessionPersistence.fileName)
        try Data("[]".utf8).write(to: target)
        #expect(symlink(target.path, manifest.path) == 0)
        #expect(throws: SessionPersistenceLoadError.self) {
            _ = try SessionPersistence(fileURL: manifest).load()
        }

        let sidecarRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sidecarRoot) }
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let transcriptLink = sidecarRoot.appendingPathComponent(SessionPersistence.transcriptDirectoryName)
        #expect(symlink(external.path, transcriptLink.path) == 0)
        #expect(throws: SessionPersistenceLoadError.self) {
            _ = try SessionPersistence(
                fileURL: sidecarRoot.appendingPathComponent(SessionPersistence.fileName)
            ).load()
        }

        let lockRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: lockRoot) }
        try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)
        let lockTarget = lockRoot.appendingPathComponent("lock-target.txt")
        let lockURL = lockRoot.appendingPathComponent(SessionPersistence.fileName + ".lock")
        try Data("must remain data".utf8).write(to: lockTarget)
        #expect(symlink(lockTarget.path, lockURL.path) == 0)
        #expect(throws: SessionPersistenceLoadError.self) {
            _ = try SessionPersistence(
                fileURL: lockRoot.appendingPathComponent(SessionPersistence.fileName)
            ).load()
        }
        #expect(try String(contentsOf: lockTarget, encoding: .utf8) == "must remain data")
    }

    @Test func fifoSearchIndexReturnsSessionsWithoutBlockingOrReplacingEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent(SessionPersistence.fileName))
        let session = LatticeSession(
            title: "FIFO safe",
            messages: [.init(role: .user, text: "visible")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        try FileManager.default.removeItem(at: store.searchIndexURL)
        #expect(mkfifo(store.searchIndexURL.path, mode_t(0o600)) == 0)

        let snapshot = try #require(SessionPersistence(fileURL: store.fileURL).loadLazyResult().value)
        #expect(snapshot.sessions.map(\.id) == [session.id])
        #expect(snapshot.indexWarning?.kind == .unreadable)
        let allIDs = Set(snapshot.sessions.map(\.id))
        #expect(snapshot.searchIndex.candidateSessionIDs(for: "absent", allSessionIDs: allIDs) == allIDs)
        var status = stat()
        #expect(lstat(store.searchIndexURL.path, &status) == 0)
        #expect((status.st_mode & S_IFMT) == S_IFIFO)
    }

    @Test func indexRepairAndWriterAreOneSerializedManifestTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(SessionPersistence.fileName)
        let seed = SessionPersistence(fileURL: fileURL)
        let original = LatticeSession(
            title: "Before repair",
            messages: [.init(role: .user, text: "repairable")],
            backend: .codex(model: "gpt-5.4")
        )
        try seed.save([original])
        let writer = SessionPersistence(fileURL: fileURL)
        _ = writer.loadLazyResult()
        try FileManager.default.removeItem(at: seed.searchIndexURL)

        let repairEntered = DispatchSemaphore(value: 0)
        let releaseRepair = DispatchSemaphore(value: 0)
        let repairFinished = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let repairIO = DurableStoreFileIO(writeDataAtomically: { data, url in
            if url.lastPathComponent == SessionPersistence.searchIndexFileName {
                repairEntered.signal()
                guard releaseRepair.wait(timeout: .now() + 3) == .success else {
                    throw NSError(domain: "SessionPersistenceTests", code: 501)
                }
            }
            try data.write(to: url, options: .atomic)
        })
        let repairStore = SessionPersistence(fileURL: fileURL, io: repairIO)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = repairStore.loadLazyResult()
            repairFinished.signal()
        }
        #expect(repairEntered.wait(timeout: .now() + 1) == .success)

        var changed = original
        changed.title = "Writer after repair"
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.save([changed])
            writerFinished.signal()
        }
        #expect(writerFinished.wait(timeout: .now() + 0.15) == .timedOut)
        releaseRepair.signal()
        #expect(repairFinished.wait(timeout: .now() + 2) == .success)
        #expect(writerFinished.wait(timeout: .now() + 2) == .success)

        #expect(try SessionPersistence(fileURL: fileURL).load().first?.title == "Writer after repair")
        let index = try JSONDecoder().decode(
            SessionSearchIndex.self,
            from: Data(contentsOf: seed.searchIndexURL)
        )
        #expect(index.hasValidIntegrity)
        #expect(index.containsValidEntry(for: changed))
    }
}

private extension DurableStoreLoadResult where Value == LazySessionLoad {
    var value: LazySessionLoad? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
