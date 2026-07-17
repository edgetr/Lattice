import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

enum SelfEditReviewHandlingResult {
    case notHandled
    case committed
    case failed
}

@MainActor
extension AppState {
    /// Mutating a lazy session while its sidecars are evicted would silently discard
    /// transcript/artifact content. Start selection hydration and fail closed until both
    /// authoritative content stores are materialized.
    @discardableResult
    func requireLoadedSessionContent(for id: UUID, at index: Int) -> Bool {
        guard sessions.indices.contains(index), sessions[index].id == id else { return false }
        guard SessionTranscriptMutation.canMutateContent(in: sessions[index]) else {
            if selectedSessionID == id, transcriptLoadingSessionID != id {
                prepareTranscriptSelection(selectedID: id)
            }
            setError("Loading this chat's conversation content. Try again when loading finishes.", sessionID: id)
            return false
        }
        return ensureLegacySelfEditIntentPersisted(at: index)
    }

    // MARK: - Derived route identity (no stored selectedRoute* authority)

    /// Derived route engine for composer/default when no session is selected.
    var selectedRouteEngineID: String {
        if let backend = composerSelectionBackend ?? Optional(defaultBackend) {
            return Self.engineID(for: backend)
        }
        return Self.engineID(for: defaultBackend)
    }

    /// Derived route harness/runtime for composer/default when no session is selected.
    var selectedRouteHarnessID: String {
        if let session = selectedSession {
            return effectiveHarnessID(for: session)
        }
        if let mode = composerSelectionMode, let backend = composerSelectionBackend,
           let route = ExecutionRouteResolver.resolve(mode: mode, backend: backend) {
            return route.runtimeID
        }
        return Self.defaultHarnessID(for: composerSelectionBackend ?? defaultBackend)
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        switch handleSelfEditReviewDecision(text) {
        case .committed:
            return true
        case .failed:
            return false
        case .notHandled:
            break
        }
        guard let submission = prepareSubmission(text) else { return false }
        if selectedSessionID == nil {
            guard materializeTransientSession() else {
                if sessionSaveFailure == nil, !needsPersistenceRecovery {
                    setError("Choose a mode and model before sending.", sessionID: nil)
                }
                return false
            }
        }
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming else { return false }
        return startPreparedSubmission(submission, for: id, at: index)
    }

    @discardableResult
    func materializeTransientSession() -> Bool {
        guard isTransientNewChat,
              let mode = composerSelectionMode,
              let backend = composerSelectionBackend,
              let preferredRoute = ExecutionRouteResolver.resolve(mode: mode, backend: backend) else { return false }
        let route: ExecutionRoute
        if mode == .code,
           let resolution = piFirstCodeResolution(for: preferredRoute, routeLocked: false) {
            guard resolution.isRunnable else {
                setError(resolution.blockingReason ?? resolution.disclosure, sessionID: nil)
                return false
            }
            route = resolution.route
        } else {
            guard composerUnavailableReason(for: backend, route: preferredRoute) == nil else { return false }
            route = preferredRoute
        }
        let session = LatticeSession(
            title: "New chat",
            backend: backend,
            executionRoute: route,
            harnessID: route.runtimeID,
            reasoningEffort: defaultReasoning(for: backend, harnessID: route.runtimeID),
            workspacePath: selectedWorkspacePath,
            policy: policy,
            privacyMode: activePrivacyMode,
            draft: draft
        )
        sessions.insert(session, at: 0)
        guard persist() == .saved else {
            sessions.removeAll { $0.id == session.id }
            refreshSearchIndexForLoadedSessions()
            if needsPersistenceRecovery {
                setError("Resolve chat store recovery before creating this conversation.", sessionID: nil)
            }
            return false
        }
        isTransientNewChat = false
        selectedSessionID = session.id
        selectedSection = .conversations
        clearError()
        return true
    }

    /// Admit a Pi-first route immediately before a prompt is appended. This is
    /// the last safe point at which an unlocked, empty chat may switch runtime.
    /// Persist the route before user content; rollback keeps the UI and durable
    /// store truthful if the write fails.
    @discardableResult
    func materializePiFirstCodeRouteIfNeeded(at index: Int) -> Bool {
        guard sessions.indices.contains(index),
              sessions[index].isTranscriptLoaded,
              sessions[index].totalMessageCount == 0 else { return true }
        let current = sessions[index].executionRoute
        guard let preferred = PiFirstCodeRoutingPolicy.preferredRoute(for: current)
                ?? (current.mode == .code && current.runtimeID == "pi" ? current : nil) else {
            return true
        }
        guard let resolution = piFirstCodeResolution(for: preferred, routeLocked: false) else { return true }
        guard resolution.isRunnable else {
            setError(resolution.blockingReason ?? resolution.disclosure, sessionID: sessions[index].id)
            return false
        }
        guard resolution.route != current else { return true }
        let previous = sessions[index]
        sessions[index].executionRoute = resolution.route
        sessions[index].harnessID = resolution.route.runtimeID
        sessions[index].reasoningEffort = defaultReasoning(for: sessions[index].backend, harnessID: resolution.route.runtimeID)
        sessions[index].harnessThreadID = nil
        sessions[index].lastUpdated = .now
        guard persist() == .saved else {
            sessions[index] = previous
            return false
        }
        setActivity(
            [.init(
                icon: resolution.usesProviderFallback ? "arrow.triangle.branch" : "cpu",
                title: resolution.usesProviderFallback ? "Provider fallback" : "Lattice Agent restored",
                detail: resolution.disclosure
            )],
            sessionID: sessions[index].id
        )
        return true
    }

    @discardableResult
    func handleSelfEditReviewDecision(_ text: String) -> SelfEditReviewHandlingResult {
        guard let decision = LatticeSelfEditReviewDecision.parse(text),
              let sessionID = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[sessionIndex].isStreaming,
              requireLoadedSessionContent(for: sessionID, at: sessionIndex),
              let preview = visibleSelfEditPreviews(for: sessionID).first else { return .notHandled }
        let previousSession = sessions[sessionIndex]
        let previousOutgoingSequence = conversationOutgoingActionSequence[sessionID]
        markConversationOutgoingAction(for: sessionID)
        sessions[sessionIndex].messages.append(.init(role: .user, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        sessions[sessionIndex].lastUpdated = .now
        guard persist() == .saved else {
            sessions[sessionIndex] = previousSession
            conversationOutgoingActionSequence[sessionID] = previousOutgoingSequence
            return .failed
        }
        switch decision {
        case .accept:
            acceptSelfEditPreview(preview)
        case .discard:
            discardSelfEditPreview(preview)
        }
        return .committed
    }

    func continueSelectedResponse() {
        guard let sessionID = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              requireLoadedSessionContent(for: sessionID, at: sessionIndex),
              let session = selectedSession,
              LatticeContinuationPolicy.canContinue(session) else { return }
        guard canRunSession(session) else {
            setError(routeUnavailableMessage(for: session) ?? "Choose a connected model.", sessionID: session.id)
            composerState = .expanded
            overlayControlState = .expanded
            return
        }
        send(LatticeContinuationPolicy.prompt)
    }

    @discardableResult
    func startPreparedSubmission(
        _ submission: PreparedSubmission,
        for id: UUID,
        at index: Int,
        sourceOutboxID: UUID? = nil
    ) -> Bool {
        guard sessions.indices.contains(index), sessions[index].id == id,
              requireLoadedSessionContent(for: id, at: index) else { return false }
        normalizeSessionBackendBeforeRun(at: index)
        guard materializePiFirstCodeRouteIfNeeded(at: index) else { return false }
        guard canRunSession(sessions[index]) else {
            setError(routeUnavailableMessage(for: sessions[index]) ?? "Choose a connected model.", sessionID: id)
            composerState = .expanded
            overlayControlState = .expanded
            return false
        }
        if let reason = attachmentUnavailableReason(for: sessions[index]) {
            setError(reason, sessionID: id)
            composerState = .expanded
            overlayControlState = .expanded
            return false
        }
        guard ensureUnsafeProviderRouteAcknowledged(for: sessions[index]) else { return false }
        let beforeSubmission = sessions[index]
        let previousSubmittedRequest = submittedRequests[id]
        let previousRetryableRequest = retryableRequests[id]
        let previousOutgoingSequence = conversationOutgoingActionSequence[id]
        markConversationOutgoingAction(for: id)
        if submission.startsSelfEdit {
            sessions[index].intent = .selfEdit
            if sessions[index].title == "New chat" { sessions[index].title = Self.selfEditTitle(for: submission.userText) }
        } else if sessions[index].title == "New chat" {
            sessions[index].title = String(submission.userText.prefix(48))
        }
        sessions[index].messages.append(.init(id: sourceOutboxID ?? UUID(), role: .user, text: submission.userText))
        sessions[index].messages.append(.init(role: .assistant, text: ""))
        submittedRequests[id] = submission.runText
        retryableRequests[id] = nil
        guard startRun(for: id, at: index, submittedText: submission.runText) else {
            sessions[index] = beforeSubmission
            submittedRequests[id] = previousSubmittedRequest
            retryableRequests[id] = previousRetryableRequest
            conversationOutgoingActionSequence[id] = previousOutgoingSequence
            return false
        }
        return true
    }

    func sendEditedDraft(_ text: String) {
        guard let edit = editingMessageContext,
              let id = selectedSessionID,
              edit.belongs(to: id),
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              requireLoadedSessionContent(for: id, at: index),
              let messageIndex = sessions[index].messages.firstIndex(where: { $0.id == edit.messageID && $0.role == .user }) else { return }
        guard let submission = prepareSubmission(text) else { return }
        normalizeSessionBackendBeforeRun(at: index)
        guard canRunSession(sessions[index]) else {
            setError("Choose a connected model.", sessionID: id)
            composerState = .expanded
            overlayControlState = .expanded
            return
        }
        guard ensureUnsafeProviderRouteAcknowledged(for: sessions[index]) else { return }
        let previousSession = sessions[index]
        let previousSubmittedRequest = submittedRequests[id]
        let previousRetryableRequest = retryableRequests[id]
        let previousOutgoingSequence = conversationOutgoingActionSequence[id]
        markConversationOutgoingAction(for: id)
        sessions[index].messages[messageIndex].text = submission.userText
        sessions[index].messages.removeSubrange(sessions[index].messages.index(after: messageIndex)..<sessions[index].messages.endIndex)
        let survivingMessageIDs = Set(sessions[index].messages.map(\.id))
        SessionActionTrail.prune(in: &sessions[index].actions, keepingMessageIDs: survivingMessageIDs)
        AssistantArtifactTrail.prune(in: &sessions[index].artifacts, keepingMessageIDs: survivingMessageIDs)
        sessions[index].messages.append(.init(role: .assistant, text: ""))
        sessions[index].harnessThreadID = nil
        sessions[index].lastUpdated = .now
        if submission.startsSelfEdit {
            sessions[index].intent = .selfEdit
        } else if messageIndex == sessions[index].messages.startIndex {
            sessions[index].intent = nil
        }
        if messageIndex == sessions[index].messages.startIndex {
            sessions[index].title = sessions[index].intent == .selfEdit ? Self.selfEditTitle(for: submission.userText) : String(submission.userText.prefix(48))
        }
        submittedRequests[id] = submission.runText
        retryableRequests[id] = nil
        guard startRun(for: id, at: index, submittedText: submission.runText) else {
            sessions[index] = previousSession
            submittedRequests[id] = previousSubmittedRequest
            retryableRequests[id] = previousRetryableRequest
            conversationOutgoingActionSequence[id] = previousOutgoingSequence
            return
        }
        let existing = MessageEditDraftState(context: edit, preservedComposerDraft: preservedComposerDraftBeforeEdit)
        // Clear edit mode only after the edited transcript is durably admitted.
        editingMessageContext = nil
        preservedComposerDraftBeforeEdit = ""
        draft = MessageEditDraftState.complete(existing)
    }

    @discardableResult
    func queueFollowUp(_ text: String) -> Bool {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].isStreaming else { return false }
        let previous = sessions[index]
        SessionInputOutboxPolicy.enqueue(
            text: text,
            context: inputOutboxContext(for: sessions[index]),
            into: &sessions[index].queuedFollowUps
        )
        threadActivityLanes.apply(.queued(sessions[index].queuedFollowUps.count), to: id)
        sessions[index].lastUpdated = .now
        clearError()
        guard persist() == .saved else {
            sessions[index] = previous
            threadActivityLanes.apply(.queued(previous.queuedFollowUps.count), to: id)
            return false
        }
        return true
    }

    func markConversationOutgoingAction(for sessionID: UUID) {
        conversationOutgoingActionSequence[sessionID, default: 0] += 1
    }

    func removeQueuedFollowUp(_ queuedID: UUID) {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              let queuedIndex = sessions[index].queuedFollowUps.firstIndex(where: { $0.id == queuedID }) else { return }
        guard case .dispatching = sessions[index].queuedFollowUps[queuedIndex].lifecycle else {
            let previousSession = sessions[index]
            sessions[index].queuedFollowUps.remove(at: queuedIndex)
            threadActivityLanes.apply(.queued(sessions[index].queuedFollowUps.count), to: id)
            sessions[index].lastUpdated = .now
            guard persist() == .saved else {
                sessions[index] = previousSession
                threadActivityLanes.apply(.queued(previousSession.queuedFollowUps.count), to: id)
                return
            }
            return
        }
    }

    func sendQueuedFollowUp(_ queuedID: UUID) {
        guard let selectedSessionID else { return }
        _ = dispatchQueuedFollowUp(queuedID, sessionID: selectedSessionID, afterExplicitReview: true)
    }

    @discardableResult
    func runNextQueuedFollowUpIfPossible(for id: UUID) -> Bool {
        runOrchestrator.runNextQueuedFollowUpIfPossible(for: id)
    }

    /// Claims the FIFO head durably before it can reach a provider. Local dequeue is committed
    /// only after provider completion; an interrupted claim is review-required on restart.
    @discardableResult
    func dispatchQueuedFollowUp(
        _ queuedID: UUID,
        sessionID id: UUID,
        afterExplicitReview: Bool
    ) -> Bool {
        runOrchestrator.dispatchQueuedFollowUp(queuedID, sessionID: id, afterExplicitReview: afterExplicitReview)
    }

    func restartAcceptedOutboxSubmission(
        _ submission: PreparedSubmission,
        for id: UUID,
        at index: Int
    ) -> Bool {
        runOrchestrator.restartAcceptedOutboxSubmission(submission, for: id, at: index)
    }

    func dispatchingOutboxAttempt(for id: UUID) -> (entryID: UUID, attemptID: UUID)? {
        runOrchestrator.dispatchingOutboxAttempt(for: id)
    }

    @discardableResult
    func completeDispatchingOutbox(for id: UUID) -> Bool {
        runOrchestrator.completeDispatchingOutbox(for: id)
    }

    func failDispatchingOutbox(for id: UUID, reason: QueuedFollowUpFailureReason) {
        runOrchestrator.failDispatchingOutbox(for: id, reason: reason)
    }

    func inputOutboxContext(for session: LatticeSession) -> SessionInputOutboxContext {
        let rawWorkspace = session.workspacePath ?? ""
        let workspacePath = (try? HarnessSandbox.canonicalDirectory(URL(fileURLWithPath: rawWorkspace)).path)
            ?? SessionInputOutboxContext.standardizedPath(rawWorkspace)
        let trusted = !workspacePath.isEmpty
            && workspaceInstructionsAreTrusted(for: URL(fileURLWithPath: workspacePath))
        return SessionInputOutboxContext.capture(
            executionRoute: session.executionRoute,
            workspacePath: workspacePath,
            policy: session.policy,
            privacyMode: session.privacyMode,
            reasoningEffort: session.reasoningEffort,
            workspaceInstructionsTrusted: trusted,
            providerCredentialInjectionEnabled: OpenCodeCredentialPolicy.allowsKeychainCredential(
                for: session.executionRoute,
                enabledModes: openCodeCredentialEnabledModes
            ),
            attachments: session.attachments
        )
    }

    func workspaceInstructionsAreTrusted(for workspace: URL) -> Bool {
        guard let canonical = try? HarnessSandbox.canonicalDirectory(workspace).path else { return false }
        return trustedWorkspacePaths.contains(canonical)
    }

    func appliedInstructionFileNames(for workspace: URL, trusted: Bool) -> [String] {
        guard trusted else { return [] }
        return LatticeInstructionEnvelope.documentedWorkspaceInstructionNames.filter { name in
            let url = workspace.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    func instructionEnvelope(
        for session: LatticeSession,
        workspace: URL,
        allowFileModification: Bool,
        submittedText: String = "",
        isExtensionSelfEdit: Bool = false,
        skillID: String? = nil
    ) throws -> LatticeInstructionEnvelope {
        let trusted = workspaceInstructionsAreTrusted(for: workspace)
        let mode = session.executionRoute.mode
        let includeProduct = LatticeProductInstructions.shouldIncludeProductContext(
            mode: mode,
            submittedText: submittedText,
            isExtensionSelfEdit: isExtensionSelfEdit,
            skillID: skillID
        )
        let effectiveAllowWrites = allowFileModification
            && !(mode == .code && session.codePhase.restrictsMutatingTools)
        return try .default(
            mode: mode,
            workspace: workspace,
            allowFileModification: effectiveAllowWrites,
            workspaceInstructionsTrusted: trusted,
            trustedWorkspaceInstructionNames: appliedInstructionFileNames(for: workspace, trusted: trusted),
            codeUserAddOn: codeInstructionAddOn,
            workUserAddOn: workInstructionAddOn,
            includeProductContext: includeProduct,
            codePhase: session.codePhase
        )
    }

    func trustedWorkspaceInstructionText(for workspace: URL, names: [String]) -> String {
        let maximumBytesPerFile = 32 * 1024
        return names.compactMap { name -> String? in
            let url = workspace.appendingPathComponent(name)
            guard WorkspacePathScope.isScoped(url.path, under: workspace),
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maximumBytesPerFile + 1),
                  data.count <= maximumBytesPerFile,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return "Trusted workspace instruction " + name + ":\n" + text
        }.joined(separator: "\n\n")
    }

    func hermesProvider(for route: ExecutionRoute) -> String? {
        guard route.mode == .work, route.runtimeID == "hermes" else { return nil }
        // Prefer explicit provider:model IDs from Hermes catalogs.
        if let model = route.modelID, let separator = model.firstIndex(of: ":") {
            let provider = String(model[..<separator]).lowercased()
            let allowed: Set<String>
            switch route.providerID {
            case "codex": allowed = [LatticeHermesProvider.openAICodex.rawValue]
            case "grok": allowed = [LatticeHermesProvider.xAIOAuth.rawValue, LatticeHermesProvider.xAI.rawValue]
            case "opencode": allowed = [LatticeHermesProvider.openCodeGo.rawValue, LatticeHermesProvider.openCodeZen.rawValue]
            default: return nil
            }
            if allowed.contains(provider) { return provider }
        }
        // Declared work routes may use plain model IDs; map Lattice providerID → Hermes provider.
        switch route.providerID {
        case "codex": return LatticeHermesProvider.openAICodex.rawValue
        case "grok": return LatticeHermesProvider.xAIOAuth.rawValue
        case "opencode": return LatticeHermesProvider.openCodeGo.rawValue
        default: return nil
        }
    }

    @discardableResult
    func startRun(for id: UUID, at index: Int, submittedText: String) -> Bool {
        runOrchestrator.startRun(for: id, at: index, submittedText: submittedText)
    }

    func launchScheduledRun(for id: UUID) {
        runOrchestrator.launchScheduledRun(for: id)
    }

    func launchScheduledProviderRun(for id: UUID, runID: UUID) {
        runOrchestrator.launchScheduledProviderRun(for: id, runID: runID)
    }

    func finishSchedulerRunAfterCheckpoint(
        sessionID id: UUID,
        runID: UUID,
        completion: @escaping @MainActor () -> Void
    ) {
        runOrchestrator.finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID, completion: completion)
    }

    func handleSchedulerAdmissions(_ admitted: [UUID]) {
        runOrchestrator.handleSchedulerAdmissions(admitted)
    }

    func refreshSchedulerLanes() {
        runOrchestrator.refreshSchedulerLanes()
    }

    func persistSchedulerMetadata() {
        guard let data = try? JSONEncoder().encode(taskScheduler.persistedMetadata) else { return }
        UserDefaults.standard.set(data, forKey: Self.schedulerMetadataKey)
    }

    func recoverSchedulerMetadata() {
        guard let data = UserDefaults.standard.data(forKey: Self.schedulerMetadataKey),
              let metadata = try? JSONDecoder().decode(PersistedAgentTaskQueue.self, from: data) else { return }
        taskScheduler.recover(metadata)
        // Remove metadata for sessions the durable session store no longer owns.
        let knownSessionIDs = Set(sessions.map(\.id))
        for snapshot in taskScheduler.snapshots where !knownSessionIDs.contains(snapshot.request.sessionID) {
            taskScheduler.discardRecovered(snapshot.request.id)
        }
        for snapshot in taskScheduler.snapshots where snapshot.state == .recoveryHeld {
            if let index = sessions.firstIndex(where: { $0.id == snapshot.request.sessionID }) {
                sessions[index].isStreaming = false
                if shouldRemoveEmptyTrailingAssistant(from: sessions[index]) {
                    sessions[index].messages.removeLast()
                }
            }
        }
        // Recovery-held work is intentionally not written back as executable queue metadata.
        persistSchedulerMetadata()
    }

    func shouldRemoveEmptyTrailingAssistant(from session: LatticeSession) -> Bool {
        guard let message = session.messages.last,
              message.role == .assistant,
              message.text.isEmpty,
              session.isArtifactsLoaded else { return false }
        return !session.artifacts.contains { $0.messageID == message.id }
    }

    func normalizeSessionBackendBeforeRun(at index: Int) {
        guard sessions[index].isTranscriptLoaded,
              sessions[index].totalMessageCount == 0 else { return }
        // New mode routes are explicit user choices. Never normalize them back
        // through the legacy backend selector or switch their runtime implicitly.
        if ExecutionRouteResolver.isDeclared(sessions[index].executionRoute) { return }
        let backend = sessions[index].backend
        let valid = validBackend(backend, privacyMode: sessions[index].privacyMode)
        guard valid != backend else { return }
        sessions[index].backend = valid
        let route = RouteRuntimeMap.writeRoute(backend: valid, mode: sessions[index].executionRoute.mode)
        sessions[index].executionRoute = route
        sessions[index].harnessID = route.runtimeID
        sessions[index].reasoningEffort = defaultReasoning(for: valid, harnessID: route.runtimeID)
        sessions[index].harnessThreadID = nil
        defaultBackend = valid
        saveDefaultBackend()
        syncExecutionRoute(from: valid)
    }

    func canRunSession(_ session: LatticeSession) -> Bool {
        // Fail closed: local-only never runs a cloud backend, even if route mode was corrupted.
        guard SessionPrivacyPolicy.allows(session.backend, in: session.privacyMode) else { return false }
        if session.privacyMode == .localOnly {
            // Declared non-local routes and cloud runtimes are never runnable under local-only.
            if session.executionRoute.mode != .local { return false }
            if !session.backend.isLocal { return false }
        }
        if ExecutionRouteResolver.isDeclared(session.executionRoute) {
            return canRunDeclaredRoute(session.executionRoute)
        }
        let harnessID = effectiveHarnessID(for: session)
        let routeLocked = session.totalMessageCount > 0
            || !session.isTranscriptLoaded
            || session.harnessThreadID != nil
        if routeLocked {
            return canContinueLockedRoute(session.backend, harnessID: harnessID)
        }
        return canRunBackend(validBackend(session.backend, privacyMode: session.privacyMode), harnessID: harnessID)
    }

    /// Integrity check before stream launch: privacy + route/backend consistency.
    func sessionMayLaunchProviderRun(_ session: LatticeSession) -> String? {
        guard let rejection = SessionLaunchIntegrity.launchRejection(
            backend: session.backend,
            privacyMode: session.privacyMode,
            route: session.executionRoute
        ) else { return nil }
        return SessionLaunchIntegrity.userMessage(for: rejection)
    }

    func canRunDeclaredRoute(_ route: ExecutionRoute) -> Bool {
        routeReadiness(for: route).isRunnable
    }

    func routeReadiness(for route: ExecutionRoute) -> ExecutionRouteReadiness {
        guard ExecutionRouteResolver.isDeclared(route) else {
            return .failed("This route is available only for a legacy chat.")
        }
        return routeReadinessSnapshot(for: route)?.readiness
            ?? .failed("The selected mode, provider, and runtime are incompatible.")
    }

    func routeReadinessSnapshot(for route: ExecutionRoute) -> RouteReadinessSnapshot? {
        guard ExecutionRouteResolver.isDeclared(route) else {
            return nil
        }

        // A provider fallback is a declared, explicit route, but it must use
        // the provider's own runtime readiness contract. Codex app-server owns
        // its sandbox; OpenCode ACP still requires Lattice's system sandbox.
        if PiFirstCodeRoutingPolicy.isDeclaredProviderFallback(route) {
            let runtimePresent: Bool
            let authenticationValidated: Bool
            let modelValidated: Bool
            let sandboxAvailable: Bool
            switch route.providerID {
            case "codex":
                runtimePresent = codex.isInstalled
                authenticationValidated = codexReady && codexAuthenticated && codexProtocolUnavailableReason == nil
                modelValidated = route.modelID.map { model in
                    visibleCodexModels.contains(where: { $0.id == model })
                } ?? false
                sandboxAvailable = true
            case "opencode":
                runtimePresent = openCodeACP.isInstalled
                authenticationValidated = openCodeReady
                modelValidated = route.modelID.map { model in
                    visibleOpenCodeModels.contains(where: { $0.id == model })
                        && ACPHarness.bestMatch(for: model, in: openCodeACPModels) != nil
                } ?? false
                sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
            default:
                return nil
            }
            return RouteReadinessEvaluator.evaluate(
                route: route,
                requirements: RouteReadinessRequirements(
                    runtimePresent: runtimePresent,
                    authenticationValidated: authenticationValidated,
                    modelValidated: modelValidated,
                    sandboxAvailable: sandboxAvailable
                ),
                validating: cliBusyProviders.contains(route.runtimeID)
                    || cliBusyProviders.contains("\(route.runtimeID)-\(route.providerID)")
            )
        }

        let runtimePresent: Bool
        let authenticationValidated: Bool
        let modelValidated: Bool
        let sandboxAvailable: Bool

        switch (route.mode, route.providerID, route.runtimeID) {
        case (.code, "codex", "pi"), (.code, "opencode", "pi"):
            runtimePresent = piInstalled
            let providerModel = PiRPCHarness.providerModel(for: route)
            modelValidated = providerModel.map { piModelIDs.contains($0.provider + "/" + $0.model) } ?? false
            authenticationValidated = route.providerID == "codex"
                ? route.modelID.map { validatedPiCodexModels.contains($0) } ?? false
                : openCodeAPIKeySaved
                    && openCodeCredentialEnabledModes.contains(.code)
                    && (route.modelID.map { validatedPiOpenCodeModels.contains($0) } ?? false)
            sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
        case (.code, "grok", "grok"):
            runtimePresent = grok.isInstalled
            authenticationValidated = grokAuthenticated
            modelValidated = route.modelID.map { ACPHarness.bestMatch(for: $0, in: grokACPModels) != nil } ?? false
            sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
        case (.code, "antigravity", "antigravity"):
            runtimePresent = antigravityInstalled
            authenticationValidated = antigravityAuthenticated
            modelValidated = route.modelID.map { model in visibleAntigravityModels.contains(where: { $0.id == model }) } ?? false
            sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
        case (.work, _, "hermes"):
            runtimePresent = hermesInstalled
            let provider = hermesProvider(for: route)
            authenticationValidated = route.providerID == "opencode"
                ? openCodeAPIKeySaved
                    && openCodeCredentialEnabledModes.contains(.work)
                    && (route.modelID.map { validatedHermesOpenCodeModels.contains($0) } ?? false)
                : provider.map { validatedHermesProviders.contains($0) } ?? false
            modelValidated = route.modelID.map { HermesACPHarness.exactMatch(for: $0, in: hermesModels) != nil } ?? false
            sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
        case (.local, "apple", "lattice"):
            runtimePresent = appleIntelligenceReady
            authenticationValidated = true
            modelValidated = appleIntelligenceReady
            sandboxAvailable = true
        case (.local, "ollama", "lattice"):
            runtimePresent = ollamaReady
            authenticationValidated = true
            modelValidated = route.modelID.map { model in
                ollamaCatalogStatus == .loaded && ollamaModels.contains(where: { $0.name == model })
            } ?? false
            sandboxAvailable = true
        default:
            return nil
        }

        return RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: RouteReadinessRequirements(
                runtimePresent: runtimePresent,
                authenticationValidated: authenticationValidated,
                modelValidated: modelValidated,
                sandboxAvailable: sandboxAvailable
            ),
            validating: cliBusyProviders.contains(route.runtimeID) || cliBusyProviders.contains("\(route.runtimeID)-\(route.providerID)")
        )
    }

    /// Resolve the Pi-first policy against the live preferred and exact direct
    /// provider readiness. Loading/validating preferred state never falls back.
    func piFirstCodeResolution(
        for route: ExecutionRoute,
        routeLocked: Bool
    ) -> PiFirstCodeRouteResolution? {
        guard let preferred = PiFirstCodeRoutingPolicy.preferredRoute(for: route) else { return nil }
        let preferredReadiness = routeReadinessSnapshot(for: preferred)?.readiness
            ?? .failed("Lattice Agent did not report this exact model.")
        let directReadiness = PiFirstCodeRoutingPolicy.fallbackRoute(for: preferred)
            .flatMap { routeReadinessSnapshot(for: $0)?.readiness }
            ?? .failed("The exact provider route is unavailable.")
        return PiFirstCodeRoutingPolicy.resolve(
            preferredRoute: preferred,
            preferredReadiness: preferredReadiness,
            directReadiness: directReadiness,
            routeLocked: routeLocked
        )
    }

    func modeReadiness(_ mode: ConversationMode, providerID: String) -> ExecutionRouteReadiness {
        let routes = composerModelOptions(for: mode)
            .filter { $0.route.providerID == providerID && $0.route.modelID != nil }
            .map(\.route)
        let states = routes.map(routeReadiness(for:))
        if states.contains(where: { $0.isRunnable }) { return .runnable }
        if let state = states.first { return state }

        switch (mode, providerID) {
        case (.code, "codex"), (.code, "opencode"):
            return piInstalled ? .authenticationRequired : .missingRuntime
        case (.work, _):
            return hermesInstalled ? .authenticationRequired : .missingRuntime
        case (.code, "grok"):
            return grok.isInstalled ? .authenticationRequired : .missingRuntime
        case (.code, "antigravity"):
            return antigravityInstalled ? .authenticationRequired : .missingRuntime
        default:
            return .failed("No compatible model was discovered.")
        }
    }

    func canContinueLockedRoute(_ backend: ChatBackend, harnessID: String?) -> Bool {
        if harnessID == "pi" { return piInstalled && piRoute(for: backend) != nil }
        if harnessID == "hermes" { return hermesInstalled && hermesMatch(for: backend) != nil }
        switch backend {
        case .codex(let model):
            return codexReady && codexModels.contains(where: { $0.id == model })
        case .grok(let model):
            return grokReady && ACPHarness.bestMatch(for: model, in: grokACPModels) != nil
        case .openCode(let model):
            return openCodeReady && ACPHarness.bestMatch(for: model, in: openCodeACPModels) != nil
        case .appleIntelligence:
            return appleIntelligenceReady
        case .ollama(let model):
            return ollamaReady
                && ollamaCatalogStatus == .loaded
                && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ollamaModels.contains(where: { $0.name == model })
        case .antigravity(let model):
            return antigravityAuthenticated && visibleAntigravityModels.contains(where: { $0.id == model })
        }
    }

    func canUseBackendInNewChat(_ backend: ChatBackend) -> Bool {
        if !SessionPrivacyPolicy.allows(backend, in: activePrivacyMode) { return false }
        guard validBackend(backend, privacyMode: activePrivacyMode) == backend else { return false }
        return canRunBackend(backend, harnessID: Self.defaultHarnessID(for: backend))
    }

    var antigravityReadinessDetail: String {
        guard antigravityInstalled else { return "Not installed" }
        switch antigravityCatalogStatus {
        case .unknown: return "Provider health not checked"
        case .loading: return "Checking provider health"
        case .failed: return "Provider model catalog unavailable"
        case .empty: return "No models reported"
        case .loaded: break
        }
        guard antigravityAuthenticated else { return "Sign in required" }
        return antigravityProtocolSupport.isStructured ? "Available · structured events" : "Available · transcript events only"
    }

    func codeRouteReadinessDetail(providerID: String) -> String {
        switch providerID {
        case "codex":
            if !piInstalled { return LatticeAgentExecutable.missingRuntimeMessage }
            return piModelIDs.isEmpty ? "Lattice Agent did not report Codex models" : "No compatible Codex models reported"
        case "opencode":
            if !piInstalled { return LatticeAgentExecutable.missingRuntimeMessage }
            if !openCodeAPIKeySaved { return "Save an OpenCode key in Connections" }
            if !openCodeCredentialEnabledModes.contains(.code) { return "Enable the OpenCode key for Code" }
            return piModelIDs.isEmpty ? "Lattice Agent did not report OpenCode models" : "No compatible OpenCode models reported"
        case "grok": return grokReadinessCopy.detail
        case "antigravity": return antigravityReadinessDetail
        default: return "Route unavailable"
        }
    }

    func workRouteReadinessDetail(providerID: String) -> String {
        guard hermesInstalled else { return "Set up the Hermes Work runtime in Connections" }
        switch hermesCatalogStatus {
        case .unknown: return "Hermes model catalog has not been checked"
        case .loading: return "Loading Hermes models"
        case .failed: return "Hermes model catalog unavailable"
        case .empty: return "Hermes reported no models"
        case .loaded: break
        }
        switch providerID {
        case "codex":
            guard validatedHermesProviders.contains(LatticeHermesProvider.openAICodex.rawValue) else { return "Check Hermes Codex sign-in" }
        case "grok":
            guard validatedHermesProviders.contains(LatticeHermesProvider.xAIOAuth.rawValue) else { return "Check Hermes Grok sign-in" }
        case "opencode":
            guard openCodeAPIKeySaved, openCodeCredentialEnabledModes.contains(.work) else { return "Enable the OpenCode key for Work" }
        default:
            return "Unsupported Work provider"
        }
        return "No compatible models reported for this Work provider"
    }

    var ollamaReadinessDetail: String {
        guard ollamaInstalled else { return "Not installed" }
        guard ollamaReady else { return "Start Ollama" }
        switch ollamaCatalogStatus {
        case .unknown: return "Local model catalog not checked"
        case .loading: return "Loading local model catalog"
        case .failed: return "Local model catalog unavailable"
        case .empty, .loaded: return "No installed local models"
        }
    }

    func backend(for providerID: String, modelID: String) -> ChatBackend? {
        switch providerID {
        case "codex": .codex(model: modelID)
        case "grok": .grok(model: modelID)
        case "opencode": .openCode(model: modelID)
        case "antigravity": .antigravity(model: modelID)
        case "ollama": .ollama(model: modelID)
        default: nil
        }
    }

    func composerUnavailableReason(for backend: ChatBackend, route: ExecutionRoute) -> String? {
        if let blocked = SessionPrivacyPolicy.blockedMessage(for: backend, in: activePrivacyMode) {
            return blocked
        }
        guard validBackend(backend, privacyMode: activePrivacyMode) == backend else {
            return backendUnavailableMessage(for: backend) ?? "Unavailable"
        }
        if route.mode == .code,
           let resolution = piFirstCodeResolution(for: route, routeLocked: false) {
            return resolution.isRunnable ? nil : resolution.blockingReason
        }
        let routeIsRunnable = ExecutionRouteResolver.isDeclared(route)
            ? canRunDeclaredRoute(route)
            : canRunBackend(backend, harnessID: route.runtimeID)
        guard routeIsRunnable else {
            return routeUnavailableMessage(for: LatticeSession(
                title: "New chat",
                backend: backend,
                executionRoute: route,
                harnessID: route.runtimeID,
                privacyMode: activePrivacyMode
            )) ?? "Unavailable"
        }
        return nil
    }

    func backendUnavailableMessage(for backend: ChatBackend) -> String? {
        if let message = SessionPrivacyPolicy.blockedMessage(for: backend, in: activePrivacyMode) {
            return message
        }
        if case .ollama(let model) = backend {
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a local model." }
            if !ollamaInstalled { return "Ollama is not installed." }
            if !ollamaReady { return "Start Ollama before using this local model." }
            if ollamaCatalogStatus == .loading { return "Ollama is refreshing its local model catalog." }
            if ollamaCatalogStatus == .failed { return "Ollama's local model catalog is unavailable. Refresh Connections before continuing." }
        }
        if validBackend(backend, privacyMode: activePrivacyMode) != backend {
            switch backend {
            case .codex(let model):
                return visibleCodexModels.contains(where: { $0.id == model })
                    ? "Codex cannot run \(model) through the current connection."
                    : "Codex no longer exposes \(model), or it is hidden in Connections."
            case .grok(let model):
                return visibleGrokModels.contains(where: { $0.id == model })
                    ? "Grok cannot run \(model) through its current ACP connection."
                    : "Grok no longer exposes \(model), or it is hidden in Connections."
            case .openCode(let model):
                return visibleOpenCodeModels.contains(where: { $0.id == model })
                    ? "OpenCode cannot run \(model) through its current ACP connection."
                    : "OpenCode no longer exposes \(model), or it is hidden in Connections."
            case .ollama(let model):
                return "The local model \(model) is not installed."
            case .appleIntelligence:
                return appleIntelligenceStatus
            case .antigravity:
                return antigravityInstalled ? "Sign in to Antigravity and choose an available model." : "Install the Antigravity CLI first."
            }
        }
        if canRunBackend(backend, harnessID: Self.defaultHarnessID(for: backend)) {
            return nil
        }
        return routeUnavailableMessage(for: LatticeSession(title: "New chat", backend: backend, harnessID: Self.defaultHarnessID(for: backend), privacyMode: activePrivacyMode))
    }

    func canRunBackend(_ backend: ChatBackend, harnessID: String? = nil) -> Bool {
        if harnessID == "pi" { return piInstalled && piRoute(for: backend) != nil }
        if harnessID == "hermes" { return hermesInstalled && hermesMatch(for: backend) != nil }
        switch backend {
        case .codex(let model):
            return codexReady && codexModels.contains(where: { $0.id == model })
        case .grok(let model):
            return grokReady && ACPHarness.bestMatch(for: model, in: grokACPModels) != nil
        case .openCode(let model):
            return openCodeReady && ACPHarness.bestMatch(for: model, in: openCodeACPModels) != nil
        case .appleIntelligence:
            return appleIntelligenceReady
        case .ollama(let model):
            return ollamaReady
                && ollamaCatalogStatus == .loaded
                && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ollamaModels.contains(where: { $0.name == model })
        case .antigravity(let model):
            return antigravityAuthenticated && visibleAntigravityModels.contains(where: { $0.id == model })
        }
    }

    func routeUnavailableMessage(for session: LatticeSession) -> String? {
        let harnessID = effectiveHarnessID(for: session)
        if let message = SessionPrivacyPolicy.blockedMessage(for: session.backend, in: session.privacyMode) {
            return message
        }
        if canRunSession(session) { return nil }
        if PiFirstCodeRoutingPolicy.isDeclaredProviderFallback(session.executionRoute) {
            return "Provider fallback is unavailable. Restore \(session.executionRoute.providerID.capitalized) or start a new chat to retry Lattice Agent."
        }
        if ExecutionRouteResolver.isDeclared(session.executionRoute) {
            switch session.executionRoute.runtimeID {
            case "pi":
                if !piInstalled { return LatticeAgentExecutable.missingRuntimeMessage }
                return "Check Lattice Agent sign-in and exact model availability for this Code route."
            case "hermes":
                if !hermesInstalled { return "Set up the Hermes Work runtime in Connections." }
                return "Check Hermes sign-in and exact model availability for this Work route."
            case "grok": return grokReadinessCopy.detail
            case "antigravity": return antigravityReadinessDetail
            case "lattice": break
            default: return "The selected runtime is unavailable."
            }
        }
        if harnessID == "pi" {
            return piInstalled
                ? "Lattice Agent cannot run this locked provider/model route."
                : LatticeAgentExecutable.notInstalledErrorMessage
        }
        if harnessID == "hermes" {
            return hermesInstalled ? "Hermes does not expose this locked model." : "Hermes is not installed."
        }
        switch session.backend {
        case .codex(let model):
            if !codex.isInstalled { return "Codex is not installed." }
            if !codexAuthenticated { return "Codex sign-in is required before this chat can continue." }
            if let codexProtocolUnavailableReason { return codexProtocolUnavailableReason }
            if !codexReady { return "Codex is not ready. Refresh Connections before continuing." }
            if codexModels.isEmpty { return "Codex has not reported a model catalog. Refresh Connections before continuing." }
            if !codexModels.contains(where: { $0.id == model }) {
                return "Codex no longer exposes \(model). Start a new chat to choose another model."
            }
        case .grok(let model):
            if !grok.isInstalled { return "Grok is not installed." }
            if !grokReady { return "Grok sign-in or ACP setup is required before this chat can continue." }
            if ACPHarness.bestMatch(for: model, in: grokACPModels) == nil {
                return "Grok no longer exposes \(model). Start a new chat to choose another model."
            }
        case .openCode(let model):
            if !openCodeACP.isInstalled { return "OpenCode is not installed." }
            if !openCodeReady { return "OpenCode sign-in or ACP setup is required before this chat can continue." }
            if ACPHarness.bestMatch(for: model, in: openCodeACPModels) == nil {
                return "OpenCode no longer exposes \(model). Start a new chat to choose another model."
            }
        case .appleIntelligence:
            return appleIntelligenceStatus
        case .ollama(let model):
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a local model." }
            if !ollamaInstalled { return "Ollama is not installed." }
            if !ollamaReady { return "Start Ollama before this chat can continue." }
            if ollamaCatalogStatus == .loading { return "Ollama is refreshing its local model catalog." }
            if ollamaCatalogStatus == .failed { return "Ollama's local model catalog is unavailable. Refresh Connections before continuing." }
            if !ollamaModels.contains(where: { $0.name == model }) {
                return "The local model \(model) is not installed."
            }
        case .antigravity(let model):
            if !antigravityInstalled { return "Antigravity CLI is not installed." }
            if !antigravityAuthenticated { return "Sign in to Antigravity before this chat can continue." }
            if visibleAntigravityModels.isEmpty { return "Antigravity has not reported a model catalog. Refresh Connections before continuing." }
            if !visibleAntigravityModels.contains(where: { $0.id == model }) {
                return "Antigravity no longer exposes \(model). Start a new chat to choose another model."
            }
        }
        return "Choose a connected model."
    }

    func ensureUnsafeProviderRouteAcknowledged(for session: LatticeSession) -> Bool {
        let engineID = Self.engineID(for: session.backend)
        let harnessID = effectiveHarnessID(for: session)
        guard ProviderRouteSafetyPolicy.requiresAcknowledgement(engineID: engineID, harnessID: harnessID) else {
            return true
        }
        let routeKey = ProviderRouteSafetyPolicy.routeKey(engineID: engineID, harnessID: harnessID)
        guard !acknowledgedUnsafeProviderRouteKeys.contains(routeKey) else { return true }
        let providerName: String
        switch harnessID {
        case "pi": providerName = LatticeAgentExecutable.productDisplayName
        case "hermes": providerName = "Hermes"
        default: providerName = session.backend.harnessName
        }
        pendingUnsafeProviderRouteAcknowledgement = UnsafeProviderRouteAcknowledgement(
            id: routeKey,
            sessionID: session.id,
            routeKey: routeKey,
            providerName: providerName,
            modelName: session.backend.displayName,
            detail: ProviderRouteSafetyPolicy.acknowledgementDetail(providerName: providerName)
        )
        return false
    }

    func acknowledgeUnsafeProviderRoute() {
        guard let pending = pendingUnsafeProviderRouteAcknowledgement else { return }
        acknowledgedUnsafeProviderRouteKeys.insert(pending.routeKey)
        pendingUnsafeProviderRouteAcknowledgement = nil
    }

    func dismissUnsafeProviderRouteAcknowledgement() {
        pendingUnsafeProviderRouteAcknowledgement = nil
    }

    func stop() {
        guard let id = selectedSessionID else { return }
        stop(sessionID: id)
    }

    /// Cancel a specific session's run/harness by id without requiring it to be selected.
    func stop(sessionID id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        let schedulerState = taskScheduler.snapshot(for: id)?.state
        let terminalRunID = activeRunIDs[id]
        let backend = session.backend
        pendingApprovalResponses[id] = nil
        providerSessionHealth[id] = nil
        // Cancel the harness first so late events cannot race a new run, then unify terminal cleanup
        // (including dispatching-outbox fail) through finalizeRun.
        if schedulerState == .running || schedulerState == .waitingForApproval {
            cancelHarnessProcess(for: session, sessionID: id)
        }
        if let terminalRunID {
            finalizeRun(
                .cancelled,
                sessionID: id,
                runID: terminalRunID,
                sessionIndex: index,
                backend: backend,
                schedulerCompletion: .cancel
            )
        } else {
            // Queued / pre-launch stop: no active runID, but a dispatching outbox claim can still stick.
            if dispatchingOutboxAttempt(for: id) != nil {
                failDispatchingOutbox(
                    for: id,
                    reason: .init(code: .cancelled, detail: "The run was stopped before the provider stream started.")
                )
            }
            if let request = submittedRequests[id] { retryableRequests[id] = request }
            submittedRequests[id] = nil
            inlineImagePayloadSuppression.remove(id)
            finishPendingActions(status: .cancelled, at: index)
            sessions[index].isStreaming = false
            if shouldRemoveEmptyTrailingAssistant(from: sessions[index]) {
                sessions[index].messages.removeLast()
            }
            recordWorkOutcome(.cancelled, title: "Work stopped", detail: "The run was cancelled before every item finished.", at: index)
            reduceRunUI(.cancelled, for: id)
            threadActivityLanes.apply(.cancelled, to: id)
            harnessPermissionNotices[id] = nil
            persist()
            handleSchedulerAdmissions(taskScheduler.cancel(id))
        }
    }

    func cancelHarnessProcess(for session: LatticeSession, sessionID id: UUID) {
        executionCoordinator.cancel(
            sessionID: id,
            route: session.executionRoute,
            legacyHarnessID: effectiveHarnessID(for: session),
            backend: session.backend,
            runtimes: executionRuntimes
        )
    }

    func harnessPermissionNotice(for sessionID: UUID) -> HarnessPermissionNotice? {
        harnessPermissionNotices[sessionID]
    }

    func availableHarnessPermissionOptions(for notice: HarnessPermissionNotice) -> [ApprovalOption] {
        let policy = sessions.first(where: { $0.id == notice.sessionID })?.policy ?? .ask
        return ApprovalOptionPolicy.visibleOptions(notice.request.options, under: policy)
    }

    func respondToHarnessPermission(_ notice: HarnessPermissionNotice, option: ApprovalOption) {
        let policy = sessions.first(where: { $0.id == notice.sessionID })?.policy ?? .ask
        guard ApprovalOptionPolicy.isVisible(option, under: policy) else {
            setError("That permission choice is not available in \(policy.rawValue) mode.", sessionID: notice.sessionID)
            return
        }
        guard sessions.contains(where: { $0.id == notice.sessionID && $0.isStreaming }) else {
            setError("This permission request is no longer active.", sessionID: notice.sessionID)
            harnessPermissionNotices[notice.sessionID] = nil
            if let sessionIndex = sessions.firstIndex(where: { $0.id == notice.sessionID }) {
                updateApprovalProvenance(
                    id: notice.request.id,
                    sessionIndex: sessionIndex,
                    actor: .user,
                    selectedOptionKind: option.kind,
                    outcome: .stale,
                    providerAcknowledgement: .rejectedByHarness
                )
            }
            updateSessionAction(id: notice.request.id, status: .cancelled, sessionID: notice.sessionID)
            return
        }
        pendingApprovalResponses[notice.sessionID] = (notice, option)
        let admitted = taskScheduler.resolveApproval(notice.sessionID)
        handleSchedulerAdmissions(admitted)
        if !admitted.contains(notice.sessionID) {
            threadActivityLanes.apply(.approvalQueued(1), to: notice.sessionID)
            refreshSchedulerLanes()
        }
    }

    func forwardAdmittedHarnessPermission(_ notice: HarnessPermissionNotice, option: ApprovalOption) {
        guard forwardHarnessPermission(notice, optionID: option.id) else {
            setError("This permission request is no longer active.", sessionID: notice.sessionID)
            harnessPermissionNotices[notice.sessionID] = nil
            let terminalRunID = activeRunIDs[notice.sessionID]
            if let sessionIndex = sessions.firstIndex(where: { $0.id == notice.sessionID }) {
                updateApprovalProvenance(
                    id: notice.request.id,
                    sessionIndex: sessionIndex,
                    actor: .user,
                    selectedOptionKind: option.kind,
                    outcome: .stale,
                    providerAcknowledgement: .rejectedByHarness
                )
                updateSessionAction(id: notice.request.id, status: .cancelled, sessionID: notice.sessionID)
                cancelHarnessProcess(for: sessions[sessionIndex], sessionID: notice.sessionID)
                if let terminalRunID {
                    finalizeRun(
                        .permissionDenied("The provider could not resume this approval request."),
                        sessionID: notice.sessionID,
                        runID: terminalRunID,
                        sessionIndex: sessionIndex,
                        backend: sessions[sessionIndex].backend
                    )
                } else {
                    sessions[sessionIndex].isStreaming = false
                    finishPendingActions(status: .cancelled, at: sessionIndex)
                    reduceRunUI(.failed("The provider could not resume this approval request."), for: notice.sessionID)
                    threadActivityLanes.apply(.failed("The provider could not resume this approval request."), to: notice.sessionID)
                    persist()
                    handleSchedulerAdmissions(taskScheduler.finish(notice.sessionID))
                }
            } else {
                updateSessionAction(id: notice.request.id, status: .cancelled, sessionID: notice.sessionID)
                persist()
                handleSchedulerAdmissions(taskScheduler.finish(notice.sessionID))
            }
            return
        }
        harnessPermissionNotices[notice.sessionID] = nil
        if let sessionIndex = sessions.firstIndex(where: { $0.id == notice.sessionID }) {
            updateApprovalProvenance(
                id: notice.request.id,
                sessionIndex: sessionIndex,
                actor: .user,
                selectedOptionKind: option.kind,
                outcome: .forwarded,
                providerAcknowledgement: .acceptedByHarness
            )
        }
        updateSessionAction(id: notice.request.id, status: option.isAllow ? .allowed : .denied, sessionID: notice.sessionID)
        setActivity([
            .init(
                icon: option.isAllow ? "checkmark.shield" : "xmark.shield",
                title: option.name,
                detail: notice.request.title
            )
        ], sessionID: notice.sessionID)
        reduceRunUI(.permissionResolved, for: notice.sessionID)
        threadActivityLanes.apply(.approvalResolved, to: notice.sessionID)
        refreshSchedulerLanes()
        persistSchedulerMetadata()
    }

    func forwardHarnessPermission(_ notice: HarnessPermissionNotice, optionID: String?) -> Bool {
        switch notice.harnessID {
        case "codex": codex.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        case "grok": grokACP.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        case "opencode": openCodeACP.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        case "pi": pi.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        case "hermes": hermes.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        default: false
        }
    }

    func setBackend(
        _ backend: ChatBackend,
        shouldSyncExecutionRoute: Bool = true,
        preferredHarnessID: String? = nil
    ) {
        if !SessionPrivacyPolicy.allows(backend, in: activePrivacyMode) {
            let message = backendUnavailableMessage(for: backend) ?? SessionPrivacyPolicy.cloudBlockedMessage
            setError(message, sessionID: selectedSessionID)
            return
        }
        let requestedHarnessRunnable = preferredHarnessID.map { canRunBackend(backend, harnessID: $0) }
        if shouldSyncExecutionRoute,
           !(requestedHarnessRunnable ?? canUseBackendInNewChat(backend)) {
            let message = backendUnavailableMessage(for: backend) ?? "Choose a connected model."
            setError(message, sessionID: selectedSessionID)
            return
        }
        let previous = activeBackend
        let previousDefaultBackend = defaultBackend
        let selectedIndex = selectedSessionID.flatMap { id in sessions.firstIndex(where: { $0.id == id }) }
        let previousSession = selectedIndex.map { sessions[$0] }
        defaultBackend = backend
        saveDefaultBackend()
        if shouldSyncExecutionRoute { syncExecutionRoute(from: backend) }
        if selectedSessionID != nil,
           let index = selectedIndex,
           !sessions[index].isStreaming,
           sessions[index].isTranscriptLoaded,
           sessions[index].totalMessageCount == 0 {
            sessions[index].backend = backend
            let route = RouteRuntimeMap.writeRoute(
                backend: backend,
                mode: sessions[index].executionRoute.mode == .local && backend.isLocal
                    ? .local
                    : (composerSelectionMode ?? sessions[index].executionRoute.mode),
                preferredRuntimeID: shouldSyncExecutionRoute
                    ? preferredHarnessID
                    : (preferredHarnessID ?? selectedSession.map { effectiveHarnessID(for: $0) })
            )
            sessions[index].executionRoute = route
            sessions[index].harnessID = route.runtimeID
            sessions[index].reasoningEffort = defaultReasoning(for: backend, harnessID: route.runtimeID)
            sessions[index].harnessThreadID = nil
            guard persist() == .saved else {
                if let previousSession, let index = selectedIndex { sessions[index] = previousSession }
                defaultBackend = previousDefaultBackend
                saveDefaultBackend()
                return
            }
        }
        // Provider lifecycle side effects happen only after durable route admission.
        if case .ollama(let model) = previous, previous != backend {
            Task { await unloadLocalModel(model, reason: "Unloaded after model switch") }
        }
        if case .ollama(let model) = backend {
            localModelStatus = "Available: \(model)"
            scheduleLocalModelIdleUnload(model: model)
        }
    }

    func setExecutionRoute(engineID: String, harnessID: String) {
        let route = ExecutionRoutePolicy.normalize(
            EngineHarnessSelection(engineID: engineID, harnessID: harnessID),
            fallbackEngineID: Self.engineID(for: defaultBackend),
            fallbackHarnessID: Self.defaultHarnessID(for: defaultBackend)
        ) ?? EngineHarnessSelection(engineID: engineID, harnessID: harnessID)
        guard isRouteHarnessCompatible(engineID: route.engineID, harnessID: route.harnessID),
              let backend = backendForRouteEngine(route.engineID, harnessID: route.harnessID) else { return }
        if !SessionPrivacyPolicy.allows(backend, in: activePrivacyMode) {
            setError(SessionPrivacyPolicy.cloudBlockedMessage, sessionID: selectedSessionID)
            return
        }
        // Authority is backend + session.executionRoute (via setBackend / RouteRuntimeMap).
        setBackend(backend, shouldSyncExecutionRoute: true, preferredHarnessID: route.harnessID)
    }

    func setLocalModelIdleUnloadMinutes(_ minutes: Int) {
        localModelIdleUnloadMinutes = max(0, min(minutes, 60))
        UserDefaults.standard.set(localModelIdleUnloadMinutes, forKey: Self.idleUnloadKey)
        if case .ollama(let model) = activeBackend { scheduleLocalModelIdleUnload(model: model) }
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              requireLoadedSessionContent(for: id, at: index) else { return }
        guard reasoningOptions(for: sessions[index].backend, harnessID: effectiveHarnessID(for: sessions[index])).contains(where: { $0.effort == effort }) else { return }
        let previousSession = sessions[index]
        sessions[index].reasoningEffort = effort
        if persist() != .saved {
            sessions[index] = previousSession
        }
    }

    func setSessionPolicy(_ value: ExecutionPolicy) {
        // Prefer session authority for the active chat. Do not dual-write the global
        // default when the session cannot be updated (streaming / missing selection).
        if let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) {
            if sessions[index].isStreaming {
                setError("Stop the current response before changing execution policy.", sessionID: id)
                return
            }
            let previousSession = sessions[index]
            let previousPolicy = policy
            sessions[index].policy = value
            policy = value
            if persist() != .saved {
                sessions[index] = previousSession
                policy = previousPolicy
            }
            return
        }
        // No active chat: update the default for the next new chat only.
        policy = value
    }

    // MARK: - Code plan phase (Lattice Agent)

    /// Begin a guided plan phase for Code · Lattice Agent. Mutating tools stay withheld until approve.
    func beginCodePlanPhase(title: String = "Plan", seed: String = "") {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].executionRoute.mode == .code,
              sessions[index].executionRoute.runtimeID == "pi",
              !sessions[index].isStreaming else {
            setError("Plan phase is available for idle Code · Lattice Agent chats only.", sessionID: selectedSessionID)
            return
        }
        guard requireLoadedSessionContent(for: id, at: index) else { return }
        let previousSession = sessions[index]
        sessions[index].codePhase = .planActive
        if sessions[index].codePlan == nil {
            sessions[index].codePlan = CodePlanArtifact(title: title, body: seed)
        }
        SessionActionTrail.upsert(.init(
            messageID: sessions[index].messages.last?.id ?? UUID(),
            kind: .plan,
            title: "Plan phase started",
            detail: "Mutating tools withheld on the next send until you approve the plan. Grok/Antigravity native plan modes are unchanged.",
            status: .running,
            work: .init(kind: .planStep, ownership: .userOwned, stepKey: "plan-active")
        ), in: &sessions[index].actions)
        sessions[index].lastUpdated = .now
        guard persist() == .saved else {
            sessions[index] = previousSession
            return
        }
        setActivity([.init(
            icon: "list.bullet.clipboard",
            title: "Planning",
            detail: "Write/edit/bash tools withheld on the next Lattice Agent send until you approve the plan."
        )], sessionID: id)
    }

    func submitCodePlanForApproval(body: String? = nil) {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].executionRoute.runtimeID == "pi",
              sessions[index].codePhase == .planActive,
              !sessions[index].isStreaming else { return }
        guard requireLoadedSessionContent(for: id, at: index) else { return }
        let previousSession = sessions[index]
        if let body {
            let prior = sessions[index].codePlan
            sessions[index].codePlan = CodePlanArtifact(
                title: prior?.title ?? "Plan",
                body: body,
                revision: (prior?.revision ?? 0) + 1
            )
        }
        sessions[index].codePhase = .planAwaitingApproval
        sessions[index].lastUpdated = .now
        guard persist() == .saved else {
            sessions[index] = previousSession
            return
        }
        setActivity([.init(
            icon: "list.bullet.clipboard",
            title: "Plan awaiting approval",
            detail: "Write/edit/bash tools stay withheld until you approve. Takes effect on the next send."
        )], sessionID: id)
    }

    func approveCodePlan() {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].executionRoute.runtimeID == "pi",
              sessions[index].codePhase == .planAwaitingApproval,
              !sessions[index].isStreaming else { return }
        guard requireLoadedSessionContent(for: id, at: index) else { return }
        let previousSession = sessions[index]
        sessions[index].codePhase = .implement
        SessionActionTrail.upsert(.init(
            messageID: sessions[index].messages.last?.id ?? UUID(),
            kind: .plan,
            title: "Plan approved",
            detail: sessions[index].codePlan.map { "Revision \($0.revision): \($0.title)" } ?? "Implement with normal tool policy.",
            status: .allowed,
            work: .init(kind: .planStep, ownership: .userOwned, stepKey: "plan-approved")
        ), in: &sessions[index].actions)
        sessions[index].lastUpdated = .now
        guard persist() == .saved else {
            sessions[index] = previousSession
            return
        }
        setActivity([.init(
            icon: "checkmark.circle",
            title: "Plan approved",
            detail: "Implementing with normal tool policy on the next send."
        )], sessionID: id)
    }

    func requestCodePlanChanges(note: String = "") {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].executionRoute.runtimeID == "pi",
              sessions[index].codePhase == .planAwaitingApproval,
              !sessions[index].isStreaming else { return }
        guard requireLoadedSessionContent(for: id, at: index) else { return }
        let previousSession = sessions[index]
        sessions[index].codePhase = .planActive
        let detail = note.trimmingCharacters(in: .whitespacesAndNewlines)
        SessionActionTrail.upsert(.init(
            messageID: sessions[index].messages.last?.id ?? UUID(),
            kind: .plan,
            title: "Plan changes requested",
            detail: detail.isEmpty ? "User requested plan revisions." : detail,
            status: .waiting,
            work: .init(kind: .planStep, ownership: .userOwned, stepKey: "plan-changes")
        ), in: &sessions[index].actions)
        sessions[index].lastUpdated = .now
        if persist() != .saved {
            sessions[index] = previousSession
        }
    }

    func exitCodePlanPhase() {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].executionRoute.runtimeID == "pi", !sessions[index].isStreaming else { return }
        guard requireLoadedSessionContent(for: id, at: index) else { return }
        let previousSession = sessions[index]
        sessions[index].codePhase = .normal
        sessions[index].lastUpdated = .now
        guard persist() == .saved else {
            sessions[index] = previousSession
            return
        }
        setActivity([.init(
            icon: "list.bullet.clipboard",
            title: "Plan phase ended",
            detail: "Normal tool policy on the next send."
        )], sessionID: id)
    }

    // MARK: - Mid-chat Lattice Agent model switch

    /// True when the selected Code chat can switch between authenticated Codex↔OpenCode models on Lattice Agent.
    var canSwitchLatticeAgentModelMidChat: Bool {
        guard let session = selectedSession, !session.isStreaming else { return false }
        guard session.executionRoute.mode == .code, session.executionRoute.runtimeID == "pi" else { return false }
        guard session.messages.contains(where: { $0.role == .user }) else { return false }
        return true
    }

    /// Composer model options eligible for mid-chat Lattice Agent switch (Codex + OpenCode on pi).
    var latticeAgentMidChatModelOptions: [ComposerModelOption] {
        guard canSwitchLatticeAgentModelMidChat else { return [] }
        return composerModelOptions(for: .code).filter { option in
            option.isAvailable
                && option.route.runtimeID == "pi"
                && (option.route.providerID == "codex" || option.route.providerID == "opencode")
        }
    }

    /// Switch provider/model on an in-progress Code · Lattice Agent chat.
    /// Process-per-turn launch already applies the new model on the next send (set_model semantics via relaunch).
    func switchLatticeAgentModel(_ option: ComposerModelOption) {
        guard canSwitchLatticeAgentModelMidChat,
              let backend = option.backend,
              option.route.runtimeID == "pi",
              option.route.mode == .code,
              option.route.providerID == "codex" || option.route.providerID == "opencode" else {
            setError("Mid-chat model switch is only available for Code · Lattice Agent (Codex or OpenCode).", sessionID: selectedSessionID)
            return
        }
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        if !SessionPrivacyPolicy.allows(backend, in: sessions[index].privacyMode) {
            setError(SessionPrivacyPolicy.cloudBlockedMessage, sessionID: id)
            return
        }
        guard option.isAvailable, canRunDeclaredRoute(option.route) || canRunBackend(backend, harnessID: "pi") else {
            setError("Selected model is not available. Check Connections auth for Codex or OpenCode.", sessionID: id)
            return
        }
        let previousSession = sessions[index]
        let previousComposerMode = composerSelectionMode
        let previousComposerBackend = composerSelectionBackend
        let previous = sessions[index].executionRoute
        let previousLabel = "\(previous.providerID)/\(previous.modelID ?? "?")"
        let nextLabel = "\(option.route.providerID)/\(option.route.modelID ?? "?")"
        let providerChanged = previous.providerID.lowercased() != option.route.providerID.lowercased()
        // Cross-provider switch requires explicit confirmation: prior transcript may be sent
        // to the new provider and the Lattice Agent session id is not shared across providers.
        if providerChanged {
            let alert = NSAlert()
            alert.messageText = "Switch provider mid-chat?"
            alert.informativeText = """
            Switching from \(previous.providerID) to \(option.route.providerID) starts a fresh Lattice Agent session for the new provider.

            The prior visible transcript may be sent to \(option.route.providerID) on the next turn as a handoff. Provider-private state is not transferred.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Switch provider")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        sessions[index].backend = backend
        sessions[index].executionRoute = option.route
        sessions[index].harnessID = "pi"
        sessions[index].reasoningEffort = defaultReasoning(for: backend, harnessID: "pi")
        if providerChanged {
            // Never silently resume a Pi session created under another provider/auth.
            sessions[index].harnessThreadID = nil
            sessions[index].compactContextOnNextSend = true
        }
        // Same-provider model-id changes keep harnessThreadID when present.
        let continuityDetail = providerChanged
            ? "Provider changed: cleared Lattice Agent session id and queued a visible-transcript handoff. Prior transcript may be sent to \(option.route.providerID) on the next turn."
            : "Same provider model change. Prior visible transcript may still be sent on the next turn."
        upsertSessionAction(.init(
            messageID: sessions[index].messages.last?.id ?? UUID(),
            kind: .harness,
            title: "Model switched",
            detail: "Switched Lattice Agent model \(previousLabel) → \(nextLabel). \(continuityDetail)",
            status: .completed
        ), at: index)
        composerSelectionBackend = backend
        composerSelectionMode = .code
        guard persist() == .saved else {
            sessions[index] = previousSession
            composerSelectionMode = previousComposerMode
            composerSelectionBackend = previousComposerBackend
            return
        }
        setActivity([.init(
            icon: "arrow.left.arrow.right",
            title: "Model switched",
            detail: providerChanged
                ? "Next send uses \(nextLabel) with a fresh session + handoff."
                : "Next send uses \(nextLabel)."
        )], sessionID: id)
    }

    // MARK: - Context compact

    func requestContextCompactForNextSend() {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard !sessions[index].isStreaming else {
            setError("Stop the current response before compacting context.", sessionID: id)
            return
        }
        guard requireLoadedSessionContent(for: id, at: index) else { return }
        let previousSession = sessions[index]
        let previousActivity = activity
        sessions[index].compactContextOnNextSend = true
        setActivity([.init(
            icon: "arrow.triangle.2.circlepath",
            title: "Compact queued",
            detail: "Next send clears provider session continuity and rebuilds a compacted visible-transcript handoff (local estimate; not a provider tokenizer claim)."
        )], sessionID: id)
        guard persist() == .saved else {
            sessions[index] = previousSession
            setActivity(previousActivity, sessionID: id)
            return
        }
    }

    func clearContextCompactForNextSend() {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard !sessions[index].isStreaming,
              requireLoadedSessionContent(for: id, at: index) else { return }
        let previousSession = sessions[index]
        sessions[index].compactContextOnNextSend = false
        guard persist() == .saved else { sessions[index] = previousSession; return }
    }

    func setSessionPrivacyMode(_ value: SessionPrivacyMode) {
        // Mirror setSessionPolicy: do not dual-write the global default when the active
        // session cannot be updated (streaming).
        if let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) {
            if sessions[index].isStreaming {
                setError("Stop the current response before changing model privacy.", sessionID: id)
                return
            }
            guard requireLoadedSessionContent(for: id, at: index) else { return }
            let previousSession = sessions[index]
            let previousPrivacyMode = privacyMode
            let previousActivity = activity
            sessions[index].privacyMode = value
            privacyMode = value
            if value == .localOnly,
               sessions[index].totalMessageCount == 0,
               !sessions[index].backend.isLocal {
                let local = localBackendFallback()
                let route = RouteRuntimeMap.writeRoute(backend: local, mode: .local)
                sessions[index].backend = local
                sessions[index].executionRoute = route
                sessions[index].harnessID = route.runtimeID
                sessions[index].reasoningEffort = defaultReasoning(for: local, harnessID: route.runtimeID)
                sessions[index].harnessThreadID = nil
                syncExecutionRoute(from: local)
            }
            guard persist() == .saved else {
                sessions[index] = previousSession
                privacyMode = previousPrivacyMode
                setActivity(previousActivity, sessionID: id)
                return
            }
            return
        }
        privacyMode = value
    }

    func reasoningOptions(for backend: ChatBackend) -> [ReasoningOption] {
        reasoningOptions(for: backend, harnessID: nil)
    }

    func reasoningOptions(for backend: ChatBackend, harnessID: String?) -> [ReasoningOption] {
        ReasoningCapabilityPolicy.options(
            for: backend,
            harnessID: harnessID,
            codexModels: codexModels,
            grokModels: grokModels,
            openCodeModels: openCodeModels
        )
    }

    func defaultReasoning(for backend: ChatBackend) -> ReasoningEffort? {
        defaultReasoning(for: backend, harnessID: nil)
    }

    func defaultReasoning(for backend: ChatBackend, harnessID: String?) -> ReasoningEffort? {
        ReasoningCapabilityPolicy.defaultEffort(
            for: backend,
            harnessID: harnessID,
            codexModels: codexModels,
            grokModels: grokModels,
            openCodeModels: openCodeModels
        )
    }

    func chooseAttachments() {
        guard ensureAttachmentSession() else {
            setError("Choose a mode and model before adding attachments.", sessionID: nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .plainText, .sourceCode, .json, .folder]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt; return }
        addAttachments(panel.urls, source: .picker)
    }

    func addAttachments(_ urls: [URL]) {
        addAttachments(urls, source: .drop)
    }

    func addAttachments(_ urls: [URL], source: ContextAttachmentSource) {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              requireLoadedSessionContent(for: id, at: index) else {
            composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt
            return
        }
        let previousSession = sessions[index]
        let previousComposerState = composerState
        let previousOverlayState = overlayControlState
        let previousOverlayMode = overlayMode
        let existing = Set(sessions[index].attachments.map(\.path))
        let additions = urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0.path) }
            .map { ContextAttachment.inspecting(url: $0, source: source) }
        sessions[index].attachments.append(contentsOf: additions)
        guard persist() == .saved else {
            sessions[index] = previousSession
            composerState = previousComposerState
            overlayControlState = previousOverlayState
            overlayMode = previousOverlayMode
            setError("Could not save attachments for this chat.", sessionID: id)
            return
        }
        composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt
    }

    func removeAttachment(_ id: UUID) {
        guard let sessionID = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[index].isStreaming,
              requireLoadedSessionContent(for: sessionID, at: index),
              let attachment = sessions[index].attachments.first(where: { $0.id == id }) else { return }
        let previousSession = sessions[index]
        sessions[index].attachments.removeAll { $0.id == id }
        guard persist() == .saved else {
            sessions[index] = previousSession
            setError("Could not save the attachment removal.", sessionID: sessionID)
            return
        }
        guard attachment.isLatticeManagedCapture else { return }
        do {
            try captureStorage.removeCapture(attachment: attachment)
        } catch {
            setError("Attachment removed from the chat, but its managed capture file could not be deleted: \(error.localizedDescription)", sessionID: sessionID)
        }
    }

    func pasteImageFromClipboard() {
        guard ensureAttachmentSession() else {
            setError("Choose a mode and model before pasting an image.", sessionID: nil)
            return
        }
        let pasteboard = NSPasteboard.general
        let data: Data?
        if let png = pasteboard.data(forType: .png) {
            data = png
        } else if let tiff = pasteboard.data(forType: .tiff),
                  let image = NSImage(data: tiff),
                  let representation = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) {
            data = representation.representation(using: .png, properties: [:])
        } else {
            data = nil
        }
        guard let data else {
            setError("The clipboard does not contain a supported image.", sessionID: selectedSessionID)
            return
        }
        addManagedImage(data, source: .clipboard, context: nil)
    }

    func addDroppedImageData(_ data: Data) {
        guard ensureAttachmentSession() else {
            setError("Choose a mode and model before attaching an image.", sessionID: nil)
            return
        }
        addManagedImage(data, source: .clipboard, context: nil)
    }

    func captureScreenRegion() { beginScreenshotCapture(windowOnly: false) }
    func captureAppWindow() { beginScreenshotCapture(windowOnly: true) }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func beginScreenshotCapture(windowOnly: Bool) {
        guard ensureAttachmentSession() else {
            setError("Choose a mode and model before capturing a screenshot.", sessionID: nil)
            return
        }
        let targetSessionID = selectedSessionID
        let captureIncludeContext = includeScreenshotContext
        if case .applied(let next) = CaptureLifecyclePolicy.reduce(
            .userInitiatedCapture(includeAccessibilityText: captureIncludeContext),
            into: captureLifecycle
        ) { captureLifecycle = next } else { return }

        if screenshotCaptureService.screenRecordingStatus != .authorized {
            if case .applied(let requesting) = CaptureLifecyclePolicy.reduce(.permissionRequestStarted, into: captureLifecycle) {
                captureLifecycle = requesting
            }
            let granted = screenshotCaptureService.requestScreenRecordingPermission()
            if !granted {
                if case .applied(let failed) = CaptureLifecyclePolicy.reduce(.failed(ScreenCapturePermissionPolicy.screenRecordingRequiredReason), into: captureLifecycle) {
                    captureLifecycle = failed
                }
                setError("Screen Recording permission is required. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording.", sessionID: selectedSessionID)
                return
            }
        }

        if captureIncludeContext, screenshotCaptureService.accessibilityStatus != .authorized {
            _ = screenshotCaptureService.requestAccessibilityPermission()
        }
        if case .applied(let capturing) = CaptureLifecyclePolicy.reduce(.captureStarted, into: captureLifecycle) {
            captureLifecycle = capturing
        }
        Task {
            do {
                let result = try await (windowOnly
                    ? screenshotCaptureService.captureFrontmostWindow(includeContext: captureIncludeContext)
                    : screenshotCaptureService.captureRegion(includeContext: captureIncludeContext))
                addManagedImage(
                    result.data,
                    source: result.source,
                    context: result.context,
                    sessionID: targetSessionID,
                    includeContext: captureIncludeContext
                )
                let event: CaptureLifecycleEvent = result.context.accessibilityAuthorized && result.context.accessibilityText != nil
                    ? .completedWithAuthorizedContext : .completedImageOnly
                if case .applied(let completed) = CaptureLifecyclePolicy.reduce(event, into: captureLifecycle) { captureLifecycle = completed }
            } catch ScreenshotCaptureServiceError.cancelled {
                if case .applied(let cancelled) = CaptureLifecyclePolicy.reduce(.cancelled, into: captureLifecycle) { captureLifecycle = cancelled }
            } catch {
                if case .applied(let failed) = CaptureLifecyclePolicy.reduce(.failed(error.localizedDescription), into: captureLifecycle) { captureLifecycle = failed }
                setError(error.localizedDescription, sessionID: targetSessionID)
            }
        }
    }

    func addManagedImage(
        _ data: Data,
        source: ContextAttachmentImageSource,
        context: ScreenshotCaptureContext?,
        sessionID: UUID? = nil,
        includeContext: Bool? = nil
    ) {
        let targetID = sessionID ?? selectedSessionID
        guard let id = targetID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              requireLoadedSessionContent(for: id, at: index) else { return }
        let contextAuthorized = (includeContext ?? includeScreenshotContext) && context != nil
        let accessibilityAuthorized = contextAuthorized && context?.accessibilityAuthorized == true
        let fallbackReason: String = {
            if !contextAuthorized { return "App/window context was not included by the user." }
            if !accessibilityAuthorized { return "Accessibility permission is unavailable; image-only context was attached." }
            return "No accessibility text was available for the captured window."
        }()
        do {
            let protectedCaptureIDs = Set(
                sessions
                    .flatMap(\.attachments)
                    .filter(\.isLatticeManagedCapture)
                    .map(\.id)
            )
            let result = try captureStorage.writeCapture(
                imageData: data,
                imageExtension: "png",
                metadata: CaptureSidecarMetadata(
                    source: source,
                    contextMetadataAuthorized: contextAuthorized,
                    frontmostApplicationName: context?.applicationName,
                    frontmostApplicationBundleID: context?.bundleIdentifier,
                    frontmostWindowTitle: context?.windowTitle,
                    accessibilityTextAuthorized: accessibilityAuthorized,
                    accessibilityText: context?.accessibilityText,
                    imageOnlyFallback: .imageOnly(reason: fallbackReason),
                    imageFileName: "capture.png"
                ),
                protectedCaptureIDs: protectedCaptureIDs
            )
            let previousSession = sessions[index]
            sessions[index].attachments.append(result.attachment)
            guard persist() == .saved else {
                sessions[index] = previousSession
                do {
                    try captureStorage.removeCapture(attachment: result.attachment)
                } catch {
                    setError("Could not save the screenshot attachment, and its temporary capture file could not be removed: \(error.localizedDescription)", sessionID: id)
                    return
                }
                setError("Could not save the screenshot attachment.", sessionID: id)
                return
            }
            composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt
        } catch {
            setError("Could not store screenshot: \(error.localizedDescription)", sessionID: id)
        }
    }

    @discardableResult
    func ensureAttachmentSession() -> Bool {
        if selectedSessionID != nil { return true }
        return materializeTransientSession()
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let previousRoot = activeWorkspacePathForTools
        let previousSelectedWorkspacePath = selectedWorkspacePath
        selectedWorkspacePath = url.path
        if let id = selectedSessionID,
           let index = sessions.firstIndex(where: { $0.id == id }),
           sessions[index].totalMessageCount == 0,
           sessions[index].isTranscriptLoaded {
            let previousSession = sessions[index]
            sessions[index].workspacePath = url.path
            guard persist() == .saved else {
                sessions[index] = previousSession
                selectedWorkspacePath = previousSelectedWorkspacePath
                setError("Could not save the workspace change for this chat.", sessionID: id)
                return
            }
        }
        // Tools root can change without a session-ID change (global workspace, empty chat).
        if WorkspaceTerminalPolicy.sessionKey(forWorktreePath: previousRoot)
            != WorkspaceTerminalPolicy.sessionKey(forWorktreePath: activeWorkspacePathForTools) {
            rebindWorkLoopSurfacesAfterSelectionChange()
        } else if showFileBrowser || showWorkspaceTerminal {
            // Same standardized key but empty→non-empty display still needs refresh.
            rebindWorkLoopSurfacesAfterSelectionChange()
        }
    }

    /// Reveals the current workspace folder in Finder. No-ops when the path is empty/whitespace.
    /// If the folder is missing, opens an existing parent when possible; never mutates the filesystem.
    func revealSelectedWorkspaceInFinder() {
        let trimmed = selectedWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            workspaceActionMessage = "Choose a workspace before revealing it in Finder."
            return
        }
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            workspaceActionMessage = "Revealed the workspace in Finder."
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path,
           FileManager.default.fileExists(atPath: parent.path),
           NSWorkspace.shared.open(parent) {
            workspaceActionMessage = "The workspace folder is missing. Opened its nearest existing parent in Finder."
        } else {
            workspaceActionMessage = "The workspace folder and its parent are unavailable."
        }
    }

    /// Copies the current workspace path to the pasteboard. No-ops when empty/whitespace; does not touch the filesystem.
    func copySelectedWorkspacePath() {
        let trimmed = selectedWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            workspaceActionMessage = "Choose a workspace before copying its path."
            return
        }
        NSPasteboard.general.clearContents()
        workspaceActionMessage = NSPasteboard.general.setString(trimmed, forType: .string)
            ? "Copied the workspace path."
            : "The workspace path could not be copied."
    }

    /// Opens an existing chat from the Workspace surface. Does not create sessions.
    func openSessionFromWorkspace(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        selectedSection = .conversations
    }

    func refreshLocalModels(normalizeAfterRefresh: Bool = true) async {
        let generation = localModelRefreshGeneration.begin()
        let previous = providerConnections.snapshot(for: .ollama)
        let previousModels = providerConnections.ollamaModels
        providerConnections.markLoading(.ollama)
        defer {
            if Task.isCancelled,
               localModelRefreshGeneration.isCurrent(generation),
               ollamaCatalogStatus == .loading {
                providerConnections.setSnapshot(previous, for: .ollama)
                providerConnections.ollamaModels = previousModels
            }
        }
        let catalog = await ollama.modelsResult()
        guard !Task.isCancelled, localModelRefreshGeneration.isCurrent(generation) else { return }
        if catalog.status != .failed { ollamaModels = catalog.models }
        setProviderSnapshot(
            ProviderRuntimeSnapshot(
                installed: ollamaInstalled,
                authenticated: ollamaReady || catalog.status == .loaded,
                catalogStatus: catalog.status,
                models: ollamaModels.map { ProviderModel(id: $0.name, name: $0.name) },
                runnableModelCount: ollamaModels.count
            ),
            for: .ollama
        )
        if normalizeAfterRefresh {
            normalizeBackendsAfterCatalogRefresh()
            normalizeExecutionRouteAfterCatalogRefresh()
        }
    }

    var canRequestConnectionRefresh: Bool {
        connectionRefreshDisabledReason == nil
    }

    var connectionRefreshDisabledReason: String? {
        if isRefreshingConnections || connectionRefreshAction.isRunning {
            return "A connection refresh is already running"
        }
        if !cliBusyProviders.isEmpty {
            return "Wait for the current connection setup action to finish"
        }
        return nil
    }

    var canRequestLocalModelRefresh: Bool {
        localModelRefreshDisabledReason == nil
    }

    var localModelRefreshDisabledReason: String? {
        if !ollamaReady { return "Start Ollama before refreshing local models" }
        if ollamaCatalogStatus == .loading || localModelRefreshAction.isRunning {
            return "A local model refresh is already running"
        }
        return nil
    }

    /// Dispatches a visible Connections refresh exactly once and owns its user-facing result.
    /// Background refreshes continue to use `refreshConnections` directly.
    func requestConnectionRefresh(
        refreshProviderCatalogs: Bool = true,
        diagnosticsRuntime: LatticeRuntimeID? = nil
    ) {
        let progress = diagnosticsRuntime.map { "Diagnosing \($0.displayName)…" } ?? "Refreshing connections…"
        guard connectionRefreshAction.begin(
            progressMessage: progress,
            disabledReason: connectionRefreshDisabledReason
        ) else { return }
        Task {
            await refreshConnections(refreshProviderCatalogs: refreshProviderCatalogs)
            guard !Task.isCancelled else {
                connectionRefreshAction.fail("Connection refresh was cancelled.")
                return
            }
            finishConnectionRefreshAction(diagnosticsRuntime: diagnosticsRuntime)
        }
    }

    /// Dispatches local model discovery once, including feedback on surfaces that do not show the catalog.
    func requestLocalModelRefresh() {
        guard localModelRefreshAction.begin(
            progressMessage: "Refreshing local models…",
            disabledReason: localModelRefreshDisabledReason
        ) else { return }
        Task {
            await refreshLocalModels()
            guard !Task.isCancelled else {
                localModelRefreshAction.fail("Local model refresh was cancelled.")
                return
            }
            if ollamaCatalogStatus == .failed {
                localModelRefreshAction.fail("Ollama is running, but its model catalog is unavailable.")
            } else {
                localModelRefreshAction.succeed("Local model refresh completed. \(ollamaModels.count) chat model\(ollamaModels.count == 1 ? "" : "s") found.")
            }
        }
    }

    func finishConnectionRefreshAction(diagnosticsRuntime: LatticeRuntimeID?) {
        if let runtime = diagnosticsRuntime {
            switch runtime {
            case .pi:
                guard piInstalled else {
                    connectionRefreshAction.fail("Lattice Agent is not available. Install it from Connections.")
                    return
                }
                if piModelIDs.isEmpty {
                    connectionRefreshAction.fail("Lattice Agent was detected, but it reported no compatible models.")
                } else {
                    connectionRefreshAction.succeed("Lattice Agent diagnostics completed. \(piModelIDs.count) model route\(piModelIDs.count == 1 ? "" : "s") reported.")
                }
            case .hermes:
                guard hermesInstalled else {
                    connectionRefreshAction.fail("Hermes is no longer available on PATH.")
                    return
                }
                if hermesCatalogStatus == .failed {
                    connectionRefreshAction.fail("Hermes was detected, but its model catalog is unavailable.")
                } else {
                    connectionRefreshAction.succeed("Hermes diagnostics completed. \(hermesModels.count) model route\(hermesModels.count == 1 ? "" : "s") reported.")
                }
            }
            return
        }

        let unavailableCatalogs = [
            ("Codex", codexCatalogStatus),
            ("Grok", grokCatalogStatus),
            ("OpenCode", openCodeCatalogStatus),
            ("Hermes", hermesCatalogStatus),
            ("Ollama", ollamaCatalogStatus)
        ].compactMap { entry -> String? in entry.1 == .failed ? entry.0 : nil }
        if unavailableCatalogs.isEmpty {
            connectionRefreshAction.succeed("Connections refreshed.")
        } else {
            connectionRefreshAction.fail("Refresh completed, but these catalogs remain unavailable: \(unavailableCatalogs.joined(separator: ", ")).")
        }
    }

}
