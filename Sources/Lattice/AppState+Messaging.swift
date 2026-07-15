import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    func send(_ text: String) {
        if handleSelfEditReviewDecision(text) { return }
        guard let submission = prepareSubmission(text) else { return }
        if selectedSessionID == nil {
            guard materializeTransientSession() else {
                setError("Choose a mode and model before sending.", sessionID: nil)
                return
            }
        }
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        startPreparedSubmission(submission, for: id, at: index)
    }

    @discardableResult
    func materializeTransientSession() -> Bool {
        guard isTransientNewChat,
              let mode = composerSelectionMode,
              let backend = composerSelectionBackend,
              let route = ExecutionRouteResolver.resolve(mode: mode, backend: backend),
              composerUnavailableReason(for: backend, route: route) == nil else { return false }
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
        isTransientNewChat = false
        selectedSessionID = session.id
        selectedSection = .conversations
        clearError()
        persist()
        return true
    }

    @discardableResult
    func handleSelfEditReviewDecision(_ text: String) -> Bool {
        guard let decision = LatticeSelfEditReviewDecision.parse(text),
              let sessionID = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[sessionIndex].isStreaming,
              let preview = visibleSelfEditPreviews(for: sessionID).first else { return false }
        markConversationOutgoingAction(for: sessionID)
        sessions[sessionIndex].messages.append(.init(role: .user, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        sessions[sessionIndex].lastUpdated = .now
        persist()
        switch decision {
        case .accept:
            acceptSelfEditPreview(preview)
        case .discard:
            discardSelfEditPreview(preview)
        }
        return true
    }

    func continueSelectedResponse() {
        guard let session = selectedSession,
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
        normalizeSessionBackendBeforeRun(at: index)
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
            submittedRequests[id] = nil
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
        let existing = MessageEditDraftState(context: edit, preservedComposerDraft: preservedComposerDraftBeforeEdit)
        // Clear edit mode first, then restore the pre-edit ordinary draft (still unsent).
        editingMessageContext = nil
        preservedComposerDraftBeforeEdit = ""
        draft = MessageEditDraftState.complete(existing)
        submittedRequests[id] = submission.runText
        retryableRequests[id] = nil
        startRun(for: id, at: index, submittedText: submission.runText)
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
            sessions[index].queuedFollowUps.remove(at: queuedIndex)
            threadActivityLanes.apply(.queued(sessions[index].queuedFollowUps.count), to: id)
            sessions[index].lastUpdated = .now
            persist()
            return
        }
    }

    func sendQueuedFollowUp(_ queuedID: UUID) {
        guard let selectedSessionID else { return }
        _ = dispatchQueuedFollowUp(queuedID, sessionID: selectedSessionID, afterExplicitReview: true)
    }

    @discardableResult
    func runNextQueuedFollowUpIfPossible(for id: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              let followUp = sessions[index].queuedFollowUps.first else { return false }
        return dispatchQueuedFollowUp(followUp.id, sessionID: id, afterExplicitReview: false)
    }

    /// Claims the FIFO head durably before it can reach a provider. Local dequeue is committed
    /// only after provider completion; an interrupted claim is review-required on restart.
    @discardableResult
    func dispatchQueuedFollowUp(
        _ queuedID: UUID,
        sessionID id: UUID,
        afterExplicitReview: Bool
    ) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              let entryIndex = sessions[index].queuedFollowUps.firstIndex(where: { $0.id == queuedID }),
              entryIndex == sessions[index].queuedFollowUps.startIndex else { return false }

        // Resolve legacy/runtime route normalization before comparing the captured authority.
        // A normalization that changes execution context must block auto-send like any user change.
        normalizeSessionBackendBeforeRun(at: index)
        let context = inputOutboxContext(for: sessions[index])
        if afterExplicitReview {
            switch SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: queuedID,
                currentContext: context,
                in: sessions[index].queuedFollowUps
            ) {
            case .eligible:
                break
            case .ineligible(.contextMismatch):
                sessions[index].queuedFollowUps[entryIndex].lifecycle = .blocked(.contextMismatch)
                fallthrough
            case .ineligible:
                guard SessionInputOutboxPolicy.acceptExplicitReview(
                    entryID: queuedID,
                    currentContext: context,
                    in: &sessions[index].queuedFollowUps
                ) == .applied else { return false }
            }
        } else {
            guard SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: queuedID,
                currentContext: context,
                in: sessions[index].queuedFollowUps
            ) == .eligible else {
                if sessions[index].queuedFollowUps[entryIndex].context != context,
                   sessions[index].queuedFollowUps[entryIndex].context != nil {
                    sessions[index].queuedFollowUps[entryIndex].lifecycle = .blocked(.contextMismatch)
                    sessions[index].lastUpdated = .now
                    persist()
                }
                return false
            }
        }

        let beforeClaim = sessions[index]
        let attemptID = UUID()
        guard SessionInputOutboxPolicy.claimDispatch(
            entryID: queuedID,
            currentContext: context,
            in: &sessions[index].queuedFollowUps,
            attemptID: attemptID
        ) == .claimed(attemptID: attemptID) else { return false }
        sessions[index].lastUpdated = .now
        guard persist() == .saved else {
            sessions[index] = beforeClaim
            return false
        }

        guard let followUp = sessions[index].queuedFollowUps.first(where: { $0.id == queuedID }),
              let submission = prepareSubmission(followUp.text) else {
            _ = SessionInputOutboxPolicy.recordFailure(
                entryID: queuedID,
                attemptID: attemptID,
                reason: .init(code: .localValidationFailed, detail: "The queued input is no longer valid."),
                in: &sessions[index].queuedFollowUps
            )
            sessions[index].lastUpdated = .now
            persist()
            return false
        }

        let accepted: Bool
        if sessions[index].messages.contains(where: { $0.id == queuedID && $0.role == .user }) {
            accepted = restartAcceptedOutboxSubmission(submission, for: id, at: index)
        } else {
            accepted = startPreparedSubmission(submission, for: id, at: index, sourceOutboxID: queuedID)
        }
        guard accepted else {
            if let refreshedIndex = sessions.firstIndex(where: { $0.id == id }) {
                _ = SessionInputOutboxPolicy.recordFailure(
                    entryID: queuedID,
                    attemptID: attemptID,
                    reason: .init(code: .providerUnavailable, detail: "The selected route is unavailable."),
                    in: &sessions[refreshedIndex].queuedFollowUps
                )
                sessions[refreshedIndex].lastUpdated = .now
                persist()
            }
            return false
        }

        // Keep the durable claim until the provider reaches a terminal outcome. The queued
        // input ID is also the local user-message ID, so a reviewed retry never duplicates it.
        return true
    }

    func restartAcceptedOutboxSubmission(
        _ submission: PreparedSubmission,
        for id: UUID,
        at index: Int
    ) -> Bool {
        guard canRunSession(sessions[index]) else {
            setError(routeUnavailableMessage(for: sessions[index]) ?? "Choose a connected model.", sessionID: id)
            return false
        }
        guard ensureUnsafeProviderRouteAcknowledged(for: sessions[index]) else { return false }
        let beforeSubmission = sessions[index]
        markConversationOutgoingAction(for: id)
        sessions[index].messages.append(.init(role: .assistant, text: ""))
        submittedRequests[id] = submission.runText
        retryableRequests[id] = nil
        guard startRun(for: id, at: index, submittedText: submission.runText) else {
            sessions[index] = beforeSubmission
            submittedRequests[id] = nil
            return false
        }
        return true
    }

    func dispatchingOutboxAttempt(for id: UUID) -> (entryID: UUID, attemptID: UUID)? {
        guard let session = sessions.first(where: { $0.id == id }),
              let entry = session.queuedFollowUps.first else { return nil }
        guard case .dispatching(let attemptID) = entry.lifecycle else { return nil }
        return (entry.id, attemptID)
    }

    @discardableResult
    func completeDispatchingOutbox(for id: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              let attempt = dispatchingOutboxAttempt(for: id) else { return true }
        let beforeDequeue = sessions[index]
        var outbox = sessions[index].queuedFollowUps
        var receipts = sessions[index].inputOutboxReceipts
        let result = SessionInputOutboxPolicy.completeLocalDequeue(
            entryID: attempt.entryID,
            attemptID: attempt.attemptID,
            in: &outbox,
            ledger: &receipts
        )
        guard result == .dequeued || result == .alreadyDequeued else { return false }
        sessions[index].queuedFollowUps = outbox
        sessions[index].inputOutboxReceipts = receipts
        sessions[index].lastUpdated = .now
        threadActivityLanes.apply(.queued(sessions[index].queuedFollowUps.count), to: id)
        guard persist() == .saved else {
            sessions[index] = beforeDequeue
            _ = SessionInputOutboxPolicy.recordFailure(
                entryID: attempt.entryID,
                attemptID: attempt.attemptID,
                reason: .init(
                    code: .dispatchRejected,
                    detail: "The provider completed, but local dequeue could not be saved. Remove it after confirming the response, or review before retrying."
                ),
                in: &sessions[index].queuedFollowUps
            )
            threadActivityLanes.apply(.queued(sessions[index].queuedFollowUps.count), to: id)
            return false
        }
        return true
    }

    func failDispatchingOutbox(for id: UUID, reason: QueuedFollowUpFailureReason) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              let attempt = dispatchingOutboxAttempt(for: id) else { return }
        _ = SessionInputOutboxPolicy.recordFailure(
            entryID: attempt.entryID,
            attemptID: attempt.attemptID,
            reason: reason,
            in: &sessions[index].queuedFollowUps
        )
        sessions[index].lastUpdated = .now
        threadActivityLanes.apply(.queued(sessions[index].queuedFollowUps.count), to: id)
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

    func instructionEnvelope(for session: LatticeSession, workspace: URL, allowFileModification: Bool) throws -> LatticeInstructionEnvelope {
        let trusted = workspaceInstructionsAreTrusted(for: workspace)
        return try .default(
            mode: session.executionRoute.mode,
            workspace: workspace,
            allowFileModification: allowFileModification,
            workspaceInstructionsTrusted: trusted,
            trustedWorkspaceInstructionNames: appliedInstructionFileNames(for: workspace, trusted: trusted),
            codeUserAddOn: codeInstructionAddOn,
            workUserAddOn: workInstructionAddOn
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
        // Defense in depth: every provider stream launch stays behind the same
        // acknowledgement check, even if a future caller skips send validation.
        guard ensureUnsafeProviderRouteAcknowledged(for: sessions[index]) else {
            sessions[index].isStreaming = false
            setError("Provider route blocked until its unsafe-route acknowledgement is accepted.", sessionID: id)
            return false
        }
        sessions[index].isStreaming = true
        inlineImagePayloadSuppression.remove(id)
        sessions[index].lastUpdated = .now
        computerFrameAccumulators[id] = ComputerFrameAccumulator(minimumInterval: 0.35, recentCapacity: 4)
        globalErrorMessage = nil
        let session = sessions[index]
        let harnessID = effectiveHarnessID(for: session)
        let providerID = RouteRuntimeMap.providerID(for: session)
        let routeID = "\(harnessID)/\(providerID)"
        let isExtensionSelfEdit = isExtensionSelfEditThread(session, submittedText: submittedText)
        let sensitivity: AgentTaskRecoverySensitivity = isExtensionSelfEdit
            ? .externallyConsequential
            : (session.policy == .yolo ? .ordinary : .approvalSensitive)
        let request = AgentTaskSchedulerRequest(
            id: id,
            sessionID: id,
            resources: .init(
                workspaceID: workspaceURL(for: session, isExtensionSelfEdit: isExtensionSelfEdit).standardizedFileURL.path,
                providerID: providerID,
                routeID: routeID
            ),
            priority: threadActivityLanes.lane(for: id).priority,
            recoverySensitivity: sensitivity
        )
        if taskScheduler.snapshot(for: id)?.state == .recoveryHeld {
            taskScheduler.discardRecovered(id)
        }
        let admitted = taskScheduler.submit(request)
        threadActivityLanes.apply(.queued(1 + session.queuedFollowUps.count), to: id)
        guard persist() == .saved else {
            sessions[index].isStreaming = false
            let newlyAdmitted = taskScheduler.cancel(id)
            persistSchedulerMetadata()
            handleSchedulerAdmissions(newlyAdmitted)
            refreshSchedulerLanes()
            return false
        }
        persistSchedulerMetadata()
        handleSchedulerAdmissions(admitted)
        refreshSchedulerLanes()
        return true
    }

    func launchScheduledRun(for id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              let submittedText = submittedRequests[id],
              taskScheduler.snapshot(for: id)?.state == .running else { return }
        let session = sessions[index]
        let runID = UUID()
        activeRunIDs[id] = runID
        guard session.executionRoute.mode == .code else {
            launchScheduledProviderRun(for: id, runID: runID)
            return
        }

        let isExtensionSelfEdit = isExtensionSelfEditThread(session, submittedText: submittedText)
        let workspace = workspaceURL(for: session, isExtensionSelfEdit: isExtensionSelfEdit)
        checkpointReviewStates[id] = WorkspaceCheckpointReviewState(
            sessionID: id,
            runID: runID,
            worktreePath: workspace.standardizedFileURL.path,
            activity: .capturingBefore
        )
        let client = checkpointClient
        Task { [weak self] in
            do {
                let checkpoint = try await client.capture(
                    worktreeURL: workspace,
                    sessionID: id,
                    runID: runID,
                    boundary: .beforeRun
                )
                guard self?.activeRunIDs[id] == runID,
                      self?.taskScheduler.snapshot(for: id)?.state == .running else { return }
                self?.checkpointReviewStates[id]?.beforeCheckpoint = checkpoint
                self?.checkpointReviewStates[id]?.activity = .running
                self?.checkpointReviewStates[id]?.issue = nil
            } catch {
                guard self?.activeRunIDs[id] == runID,
                      self?.taskScheduler.snapshot(for: id)?.state == .running else { return }
                self?.checkpointReviewStates[id]?.activity = .running
                self?.checkpointReviewStates[id]?.issue = self?.checkpointMessage(for: error)
            }
            self?.launchScheduledProviderRun(for: id, runID: runID)
        }
    }

    func launchScheduledProviderRun(for id: UUID, runID: UUID) {
        guard activeRunIDs[id] == runID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              let submittedText = submittedRequests[id],
              taskScheduler.snapshot(for: id)?.state == .running else { return }
        threadActivityLanes.apply(.started, to: id)
        reduceRunUI(.started, for: id)

        let session = sessions[index]
        if let integrityIssue = sessionMayLaunchProviderRun(session) {
            let failedStream = AsyncStream<AgentEvent> { continuation in
                continuation.yield(.failed(integrityIssue))
                continuation.finish()
            }
            Task { for await event in failedStream { apply(event, to: id, runID: runID) } }
            return
        }
        let isExtensionSelfEdit = isExtensionSelfEditThread(session, submittedText: submittedText)
        if isExtensionSelfEdit { selfEditRunIDs.insert(id) }
        else { selfEditRunIDs.remove(id) }
        let workspace = workspaceURL(for: session, isExtensionSelfEdit: isExtensionSelfEdit)
        let reasoningEffort = validReasoningEffort(for: session)
        let additionalContext = backendAdditionalContext(for: session, submittedText: submittedText)
        let tokenLimit = contextTokenLimit(for: session)
        let stream: AsyncStream<AgentEvent>
        let harnessID = effectiveHarnessID(for: session)
        let launchPlan = RunLaunchPlanner.plan(
            .init(
                session: session,
                submittedText: submittedText,
                additionalContext: additionalContext,
                tokenLimit: tokenLimit,
                effectiveRuntimeID: harnessID
            )
        )
        let recoveryPrompt = launchPlan.recoveryPrompt
        let recoveryUsesVisibleTranscriptHandoff = launchPlan.recoveryUsesVisibleTranscriptHandoff
        let recoveryDeliveryIssue = launchPlan.recoveryDeliveryIssue
        let prompt = launchPlan.prompt
        let routeThreadID = launchPlan.routeThreadID
        if launchPlan.resetsHarnessSession {
            sessions[index].harnessThreadID = nil
            persist()
        }
        if let statusDetail = launchPlan.statusDetail {
            setActivity([.init(icon: launchPlan.didCompact ? "arrow.triangle.2.circlepath" : "doc.text.magnifyingglass", title: launchPlan.didCompact ? "Context compacted" : "Context handoff", detail: statusDetail)], sessionID: id)
        }
        if let deliveryIssue = launchPlan.deliveryIssue {
            let failedStream = AsyncStream<AgentEvent> { continuation in
                continuation.yield(.failed(deliveryIssue))
                continuation.finish()
            }
            Task { for await event in failedStream { apply(event, to: id, runID: runID) } }
            return
        }
        let envelope: LatticeInstructionEnvelope?
        let envelopeError: String?
        do {
            envelope = try instructionEnvelope(for: session, workspace: workspace, allowFileModification: !isExtensionSelfEdit)
            envelopeError = nil
        } catch {
            envelope = nil
            envelopeError = error.localizedDescription
        }
        // Declared Pi routes require a real envelope; surface construction errors honestly.
        if harnessID == "pi" || (ExecutionRouteResolver.isDeclared(session.executionRoute) && session.executionRoute.runtimeID == "pi") {
            if envelope == nil {
                let detail = envelopeError.map { "Could not build Pi instruction envelope: \($0)" }
                    ?? "Could not build Pi instruction envelope for this route."
                let failedStream = AsyncStream<AgentEvent> { continuation in
                    continuation.yield(.failed(detail))
                    continuation.finish()
                }
                Task { for await event in failedStream { apply(event, to: id, runID: runID) } }
                return
            }
        }
        let trustedInstructions = envelope.map {
            trustedWorkspaceInstructionText(for: workspace, names: $0.trustedWorkspaceInstructionNames)
        } ?? ""
        let developerInstructions = envelope.map {
            [$0.renderedSystemInstructions, trustedInstructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let openCodeAPIKey = OpenCodeCredentialPolicy.allowsKeychainCredential(
            for: session.executionRoute,
            enabledModes: openCodeCredentialEnabledModes
        )
            ? KeychainStore.read(account: OpenCodeCredentialPolicy.keychainAccount)
            : nil
        let localContextPlan: LatticeContextHandoffPlan? = {
            switch session.backend {
            case .appleIntelligence, .ollama:
                return LatticeContextHandoffPlanner.plan(
                    session: session,
                    submittedText: submittedText,
                    additionalContext: additionalContext,
                    tokenLimit: tokenLimit,
                    existingHarnessThreadID: "structured-message-list",
                    managementMode: .latticeManagedVisibleTranscript
                )
            default:
                return nil
            }
        }()
        let appleTranscript: String? = session.backend == .appleIntelligence
            ? LatticeBackendMessageBuilder.transcript(session: session, submittedText: submittedText, additionalContext: additionalContext, contextPlan: localContextPlan)
            : nil
        let ollamaMessages: [ChatMessage]? = {
            guard case .ollama(let model) = session.backend else { return nil }
            cancelLocalModelIdleUnload()
            localModelStatus = "Loaded \(model)"
            return LatticeBackendMessageBuilder.structuredMessages(session: session, submittedText: submittedText, additionalContext: additionalContext, contextPlan: localContextPlan)
        }()
        stream = executionCoordinator.stream(
            LatticeExecutionLaunch(
                sessionID: id,
                route: session.executionRoute,
                legacyHarnessID: harnessID,
                backend: session.backend,
                prompt: prompt,
                attachments: session.attachments,
                imageInputCapability: imageInputCapability(for: session),
                threadID: routeThreadID,
                workspace: workspace,
                reasoningEffort: reasoningEffort,
                policy: isExtensionSelfEdit ? .ask : session.policy,
                allowFileModification: !isExtensionSelfEdit,
                workspaceWrite: isExtensionSelfEdit ? SelfEditProviderLaunchPolicy.codexWorkspaceWrite : false,
                recoveryPrompt: recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: recoveryDeliveryIssue,
                instructionEnvelope: envelope,
                developerInstructions: developerInstructions,
                hermesProvider: hermesProvider(for: session.executionRoute),
                hermesSystemIdentity: developerInstructions,
                openCodeAPIKey: openCodeAPIKey,
                appleTranscript: appleTranscript,
                ollamaMessages: ollamaMessages,
                localModelKeepAliveSeconds: localModelIdleUnloadMinutes * 60
            ),
            runtimes: executionRuntimes
        )
        Task { for await event in stream { apply(event, to: id, runID: runID) } }
    }

    func finishSchedulerRunAfterCheckpoint(
        sessionID id: UUID,
        runID: UUID,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let review = checkpointReviewStates[id],
              review.runID == runID,
              sessions.first(where: { $0.id == id })?.executionRoute.mode == .code else {
            completion()
            return
        }
        checkpointReviewStates[id]?.activity = .capturingAfter
        let workspace = URL(fileURLWithPath: review.worktreePath, isDirectory: true)
        let client = checkpointClient
        Task { [weak self] in
            defer { completion() }
            do {
                let after = try await client.capture(
                    worktreeURL: workspace,
                    sessionID: id,
                    runID: runID,
                    boundary: .afterRun
                )
                guard self?.checkpointReviewStates[id]?.runID == runID else { return }
                self?.checkpointReviewStates[id]?.afterCheckpoint = after
                // A stop can clear the active run while the before capture is still
                // finishing. Recover the durable before record instead of reporting a
                // false incomplete pair when the actor already persisted it.
                var before = self?.checkpointReviewStates[id]?.beforeCheckpoint
                if before == nil {
                    if let checkpoints = try? await client.checkpoints(sessionID: id) {
                        before = checkpoints.first(where: { $0.ownership.runID == runID && $0.boundary == .beforeRun })
                    }
                    self?.checkpointReviewStates[id]?.beforeCheckpoint = before
                }
                if let before, before.status == .captured, after.status == .captured {
                    do {
                        let changes = try await client.changes(
                            beforeCheckpointID: before.id,
                            afterCheckpointID: after.id
                        )
                        self?.checkpointReviewStates[id]?.changes = changes
                        self?.checkpointReviewStates[id]?.notes = (try? await client.reviewNotes(checkpointID: after.id)) ?? []
                        self?.checkpointReviewStates[id]?.activity = .ready
                        self?.checkpointReviewStates[id]?.issue = nil
                    } catch {
                        self?.checkpointReviewStates[id]?.activity = .failed
                        self?.checkpointReviewStates[id]?.issue = self?.checkpointMessage(for: error)
                    }
                } else {
                    self?.checkpointReviewStates[id]?.activity = .failed
                    if self?.checkpointReviewStates[id]?.issue == nil {
                        self?.checkpointReviewStates[id]?.issue = "The before-run checkpoint was not captured, so this run cannot be reviewed or reverted."
                    }
                }
            } catch {
                guard self?.checkpointReviewStates[id]?.runID == runID else { return }
                self?.checkpointReviewStates[id]?.activity = .failed
                self?.checkpointReviewStates[id]?.issue = self?.checkpointMessage(for: error)
            }
        }
    }

    func handleSchedulerAdmissions(_ admitted: [UUID]) {
        for id in admitted {
            if taskScheduler.snapshot(for: id)?.isApprovalResume == true,
               let pending = pendingApprovalResponses.removeValue(forKey: id) {
                forwardAdmittedHarnessPermission(pending.notice, option: pending.option)
            } else {
                launchScheduledRun(for: id)
            }
        }
        refreshSchedulerLanes()
        persistSchedulerMetadata()
    }

    func refreshSchedulerLanes() {
        for snapshot in taskScheduler.snapshots {
            let id = snapshot.request.sessionID
            threadActivityLanes.apply(.priorityChanged(snapshot.request.priority), to: id)
            threadActivityLanes.apply(.queuePositionChanged(snapshot.queuePosition), to: id)
            switch snapshot.state {
            case .queued:
                let followUps = sessions.first(where: { $0.id == id })?.queuedFollowUps.count ?? 0
                if snapshot.isApprovalResume {
                    threadActivityLanes.apply(.approvalQueued(1 + followUps), to: id)
                } else {
                    threadActivityLanes.apply(.queued(1 + followUps), to: id)
                }
            case .running:
                let followUps = sessions.first(where: { $0.id == id })?.queuedFollowUps.count ?? 0
                threadActivityLanes.apply(.queued(followUps), to: id)
                threadActivityLanes.apply(.started, to: id)
            case .waitingForApproval:
                let followUps = sessions.first(where: { $0.id == id })?.queuedFollowUps.count ?? 0
                threadActivityLanes.apply(.queued(followUps), to: id)
                threadActivityLanes.apply(.approvalRequested, to: id)
            case .recoveryHeld:
                threadActivityLanes.apply(.failed("Interrupted work was not replayed. Review the chat and submit it again."), to: id)
            }
        }
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
        guard !sessions[index].messages.contains(where: { $0.role == .user }) else { return }
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
        let routeLocked = session.messages.contains(where: { $0.role == .user }) || session.harnessThreadID != nil
        if routeLocked {
            return canContinueLockedRoute(session.backend, harnessID: harnessID)
        }
        return canRunBackend(validBackend(session.backend, privacyMode: session.privacyMode), harnessID: harnessID)
    }

    /// Integrity check before stream launch: privacy + route/backend consistency.
    func sessionMayLaunchProviderRun(_ session: LatticeSession) -> String? {
        guard SessionPrivacyPolicy.allows(session.backend, in: session.privacyMode) else {
            return SessionPrivacyPolicy.blockedMessage(for: session.backend, in: session.privacyMode)
                ?? SessionPrivacyPolicy.cloudBlockedMessage
        }
        if session.privacyMode == .localOnly {
            if session.executionRoute.mode != .local || !session.backend.isLocal {
                return SessionPrivacyPolicy.cloudBlockedMessage
            }
        }
        if let projected = RouteRuntimeMap.backendProjection(for: session.executionRoute),
           projected.id != session.backend.id,
           ExecutionRouteResolver.isDeclared(session.executionRoute) {
            // Declared route and durable backend disagree — refuse rather than launch the wrong provider.
            return "This chat's route and backend disagree. Start a new chat or pick a model again."
        }
        return nil
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
            if !piInstalled { return "Set up the Pi Code runtime in Connections" }
            return piModelIDs.isEmpty ? "Pi did not report Codex models" : "No compatible Codex models reported"
        case "opencode":
            if !piInstalled { return "Set up the Pi Code runtime in Connections" }
            if !openCodeAPIKeySaved { return "Save an OpenCode key in Connections" }
            if !openCodeCredentialEnabledModes.contains(.code) { return "Enable the OpenCode key for Code" }
            return piModelIDs.isEmpty ? "Pi did not report OpenCode models" : "No compatible OpenCode models reported"
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
        if ExecutionRouteResolver.isDeclared(session.executionRoute) {
            switch session.executionRoute.runtimeID {
            case "pi":
                if !piInstalled { return "Set up the Pi Code runtime in Connections." }
                return "Check Pi sign-in and exact model availability for this Code route."
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
            return piInstalled ? "Pi cannot run this locked provider/model route." : "Pi is not installed."
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
        case "pi": providerName = "Pi"
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
            // No active run ID — still clear streaming UI and scheduler claim.
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

    func setBackend(_ backend: ChatBackend, shouldSyncExecutionRoute: Bool = true) {
        if !SessionPrivacyPolicy.allows(backend, in: activePrivacyMode) {
            let message = backendUnavailableMessage(for: backend) ?? SessionPrivacyPolicy.cloudBlockedMessage
            setError(message, sessionID: selectedSessionID)
            return
        }
        if shouldSyncExecutionRoute, !canUseBackendInNewChat(backend) {
            let message = backendUnavailableMessage(for: backend) ?? "Choose a connected model."
            setError(message, sessionID: selectedSessionID)
            return
        }
        let previous = activeBackend
        defaultBackend = backend
        saveDefaultBackend()
        if shouldSyncExecutionRoute { syncExecutionRoute(from: backend) }
        if let id = selectedSessionID,
           let index = sessions.firstIndex(where: { $0.id == id }),
           !sessions[index].isStreaming,
           !sessions[index].messages.contains(where: { $0.role == .user }) {
            sessions[index].backend = backend
            let route = RouteRuntimeMap.writeRoute(
                backend: backend,
                mode: sessions[index].executionRoute.mode == .local && backend.isLocal
                    ? .local
                    : (composerSelectionMode ?? sessions[index].executionRoute.mode),
                preferredRuntimeID: shouldSyncExecutionRoute ? nil : selectedRouteHarnessID
            )
            sessions[index].executionRoute = route
            sessions[index].harnessID = route.runtimeID
            sessions[index].reasoningEffort = defaultReasoning(for: backend, harnessID: route.runtimeID)
            sessions[index].harnessThreadID = nil
            persist()
        }
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
        selectedRouteEngineID = route.engineID
        selectedRouteHarnessID = route.harnessID
        setBackend(backend, shouldSyncExecutionRoute: false)
    }

    func setLocalModelIdleUnloadMinutes(_ minutes: Int) {
        localModelIdleUnloadMinutes = max(0, min(minutes, 60))
        UserDefaults.standard.set(localModelIdleUnloadMinutes, forKey: Self.idleUnloadKey)
        if case .ollama(let model) = activeBackend { scheduleLocalModelIdleUnload(model: model) }
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        guard reasoningOptions(for: sessions[index].backend, harnessID: effectiveHarnessID(for: sessions[index])).contains(where: { $0.effort == effort }) else { return }
        sessions[index].reasoningEffort = effort; persist()
    }

    func setSessionPolicy(_ value: ExecutionPolicy) {
        policy = value
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        sessions[index].policy = value
        persist()
    }

    func setSessionPrivacyMode(_ value: SessionPrivacyMode) {
        privacyMode = value
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        sessions[index].privacyMode = value
        if value == .localOnly,
           !sessions[index].messages.contains(where: { $0.role == .user }),
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
        persist()
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
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else {
            composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt
            return
        }
        let existing = Set(sessions[index].attachments.map(\.path))
        let additions = urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0.path) }
            .map { ContextAttachment.inspecting(url: $0, source: source) }
        sessions[index].attachments.append(contentsOf: additions)
        composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt
        persist()
    }

    func removeAttachment(_ id: UUID) {
        guard let sessionID = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let attachment = sessions[index].attachments.first(where: { $0.id == id }), attachment.isLatticeManagedCapture {
            try? captureStorage.removeCapture(attachment: attachment)
        }
        sessions[index].attachments.removeAll { $0.id == id }; persist()
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
        guard let id = targetID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
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
            sessions[index].attachments.append(result.attachment)
            composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt
            persist()
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
        selectedWorkspacePath = url.path
        if let id = selectedSessionID,
           let index = sessions.firstIndex(where: { $0.id == id }),
           sessions[index].totalMessageCount == 0,
           sessions[index].isTranscriptLoaded {
            sessions[index].workspacePath = url.path; persist()
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
        let previousCatalogStatus = ollamaCatalogStatus
        ollamaCatalogStatus = .loading
        defer {
            if Task.isCancelled,
               localModelRefreshGeneration.isCurrent(generation),
               ollamaCatalogStatus == .loading {
                ollamaCatalogStatus = previousCatalogStatus
            }
        }
        let catalog = await ollama.modelsResult()
        guard !Task.isCancelled, localModelRefreshGeneration.isCurrent(generation) else { return }
        ollamaCatalogStatus = catalog.status
        if catalog.status != .failed { ollamaModels = catalog.models }
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
                    connectionRefreshAction.fail("Pi is no longer available on PATH.")
                    return
                }
                if piModelIDs.isEmpty {
                    connectionRefreshAction.fail("Pi was detected, but it reported no compatible models.")
                } else {
                    connectionRefreshAction.succeed("Pi diagnostics completed. \(piModelIDs.count) model route\(piModelIDs.count == 1 ? "" : "s") reported.")
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
