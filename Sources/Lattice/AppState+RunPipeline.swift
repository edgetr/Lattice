import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    func apply(_ event: AgentEvent, to id: UUID, runID: UUID) {
        guard activeRunIDs[id] == runID else { return }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let backend = sessions[index].backend
        switch event {
        case .sessionStarted: break
        case .harnessSessionStarted(let threadID):
            sessions[index].harnessThreadID = threadID
            persist()
        case .harnessSessionRecovery(let detail):
            sessions[index].harnessThreadID = nil
            setActivity([.init(icon: "arrow.triangle.2.circlepath", title: "Provider session recovery", detail: detail)], sessionID: id)
            persist()
        case .assistantDelta(let delta):
            let reduceState = SessionRunState(
                isStreaming: sessions[index].isStreaming,
                lastAssistantText: sessions[index].messages.last?.role == .assistant
                    ? sessions[index].messages.last!.text
                    : "",
                hasAssistantMessage: sessions[index].messages.last?.role == .assistant,
                isSuppressingInlineImagePayload: inlineImagePayloadSuppression.contains(id)
            )
            let reduced = SessionRunReducer.reduce(state: reduceState, event: .assistantDelta(delta))
            guard let assistantText = reduced.assistantText,
                  sessions[index].messages.last?.role == .assistant else { return }
            let messageIndex = sessions[index].messages.count - 1
            sessions[index].messages[messageIndex].text = assistantText
            if reduced.isSuppressingInlineImagePayload == true {
                inlineImagePayloadSuppression.insert(id)
            } else if reduced.isSuppressingInlineImagePayload == false {
                inlineImagePayloadSuppression.remove(id)
            }
            sessions[index].lastUpdated = .now
            scheduleStreamingPersist()
        case .plan(let actionID, let title, let explanation, let steps):
            guard let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            upsertSessionAction(.init(
                id: actionID,
                messageID: messageID,
                kind: .plan,
                title: title,
                detail: explanation ?? "",
                status: .running
            ), at: index)
            for step in steps {
                let status: SessionAction.Status = switch step.status {
                case .pending: .waiting
                case .inProgress: .running
                case .completed: .completed
                }
                upsertSessionAction(.init(
                    id: step.id,
                    messageID: messageID,
                    kind: .plan,
                    title: step.title,
                    detail: "",
                    status: status,
                    work: .init(
                        kind: .planStep,
                        ownership: .providerBound,
                        stepKey: step.id.uuidString,
                        originActionID: actionID
                    )
                ), at: index)
            }
        case .reasoningSummary(let actionID, let delta):
            guard let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            if SessionActionTrail.appendDetail(id: actionID, delta: delta, in: &sessions[index].actions) {
                sessions[index].lastUpdated = .now
                scheduleStreamingPersist()
            } else {
                upsertSessionAction(.init(
                    id: actionID,
                    messageID: messageID,
                    kind: .reasoning,
                    title: "Reasoning summary",
                    detail: delta,
                    status: .running
                ), at: index)
            }
        case .toolRequested(let request):
            guard let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            upsertSessionAction(.init(
                id: request.id,
                messageID: messageID,
                kind: .tool,
                toolKind: request.kind,
                title: request.title,
                detail: request.detail,
                status: .running,
                workspaceScoped: request.workspaceScoped
            ), at: index)
        case .toolProgress(let toolID, _, let detail):
            updateSessionAction(id: toolID, status: detail == "Failed" ? .failed : (detail == "Cancelled" ? .cancelled : (detail == "Completed" ? .completed : .running)), at: index)
        case .permissionRequested(let request):
            let harnessID = effectiveHarnessID(for: sessions[index])
            let notice = HarnessPermissionNotice(
                sessionID: id,
                harnessID: harnessID,
                providerName: harnessID == "codex" ? "Codex" : (harnessID == "grok" ? "Grok" : (harnessID == "opencode" ? "OpenCode" : (harnessID == "pi" ? "Pi" : "Hermes"))),
                request: request
            )
            let automaticDecision = request.toolRequest.map { policyEngine.evaluate($0, under: sessions[index].policy) }
            let policyReason: String = {
                switch automaticDecision {
                case .allow(let reason), .requireApproval(let reason), .deny(let reason): return reason
                case nil: return "The provider requested an explicit permission decision."
                }
            }()
            if let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id {
                upsertSessionAction(.init(
                    id: request.id,
                    messageID: messageID,
                    kind: .approval,
                    toolKind: request.toolRequest?.kind,
                    title: request.title,
                    detail: request.detail,
                    status: .waiting,
                    workspaceScoped: request.toolRequest?.workspaceScoped ?? false,
                    approvalProvenance: .init(
                        harnessID: harnessID,
                        providerName: notice.providerName,
                        requestID: request.id,
                        requestedOptionKinds: request.options.map(\.kind),
                        toolKind: request.toolRequest?.kind,
                        workspaceScoped: request.toolRequest?.workspaceScoped ?? false,
                        policy: sessions[index].policy,
                        policyReason: policyReason,
                        actor: .user
                    ),
                    work: .init(kind: .approval, ownership: .providerBound)
                ), at: index)
            }
            let automaticResolution = AutomaticPermissionResolutionPolicy.resolve(
                decision: automaticDecision,
                policy: sessions[index].policy,
                options: request.options
            )
            switch automaticResolution {
            case .forward(let optionID, let allowed):
                guard forwardHarnessPermission(notice, optionID: optionID) else {
                    harnessPermissionNotices[id] = nil
                    updateApprovalProvenance(
                        id: request.id,
                        sessionIndex: index,
                        actor: .automatic,
                        selectedOptionKind: request.options.first(where: { $0.id == optionID })?.kind,
                        outcome: .failed,
                        providerAcknowledgement: .rejectedByHarness
                    )
                    updateSessionAction(id: request.id, status: allowed ? .cancelled : .denied, at: index)
                    sessions[index].isStreaming = false
                    activeRunIDs[id] = nil
                    reduceRunUI(.failed("The provider rejected Lattice's automatic permission decision."), for: id)
                    threadActivityLanes.apply(.failed("The provider rejected Lattice's automatic permission decision."), to: id)
                    cancelHarnessProcess(for: sessions[index], sessionID: id)
                    persist()
                    finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                        guard let self else { return }
                        self.handleSchedulerAdmissions(self.taskScheduler.finish(id))
                        self.persist()
                    }
                    return
                }
                updateApprovalProvenance(
                    id: request.id,
                    sessionIndex: index,
                    actor: .automatic,
                    selectedOptionKind: request.options.first(where: { $0.id == optionID })?.kind,
                    outcome: .forwarded,
                    providerAcknowledgement: .acceptedByHarness
                )
                updateSessionAction(id: request.id, status: allowed ? .allowed : .denied, at: index)
                setActivity([.init(icon: allowed ? "checkmark.shield" : "xmark.shield", title: allowed ? "Allowed by \(sessions[index].policy.rawValue.capitalized) mode" : "Blocked by policy", detail: request.title)], sessionID: id)
                reduceRunUI(.permissionResolved, for: id)
                threadActivityLanes.apply(.approvalResolved, to: id)
            case .denyFailClosed(let reason):
                let cancellationForwarded = forwardHarnessPermission(notice, optionID: nil)
                harnessPermissionNotices[id] = nil
                updateApprovalProvenance(
                    id: request.id,
                    sessionIndex: index,
                    actor: .automatic,
                    outcome: cancellationForwarded ? .forwarded : .failed,
                    providerAcknowledgement: cancellationForwarded ? .acceptedByHarness : .unavailable
                )
                updateSessionAction(id: request.id, status: .denied, at: index)
                sessions[index].isStreaming = false
                activeRunIDs[id] = nil
                reduceRunUI(.failed("Blocked by Lattice policy: \(reason)"), for: id)
                threadActivityLanes.apply(.failed("Blocked by Lattice policy: \(reason)"), to: id)
                cancelHarnessProcess(for: sessions[index], sessionID: id)
                persist()
                finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                    guard let self else { return }
                    self.handleSchedulerAdmissions(self.taskScheduler.finish(id))
                    self.persist()
                }
            case .requestUser:
                harnessPermissionNotices[id] = notice
                setActivity([.init(icon: "hand.raised.fill", title: request.title, detail: "Waiting for your decision")], sessionID: id)
                reduceRunUI(.permissionRequested, for: id)
                threadActivityLanes.apply(.approvalRequested, to: id)
                // Structured harnesses are suspended at this boundary with no tool executing,
                // so capacity can be released and must be reacquired before forwarding a choice.
                handleSchedulerAdmissions(taskScheduler.waitForApproval(id, releasesExecutionSlot: true))
            }
        case .permissionDecided(let decision):
            if harnessPermissionNotices[id]?.request.id == decision.requestID {
                harnessPermissionNotices[id] = nil
            }
            switch decision.outcome {
            case .selected(_, let kind):
                updateSessionAction(
                    id: decision.requestID,
                    status: kind.hasPrefix("allow_") ? .allowed : .denied,
                    at: index
                )
            case .cancelled:
                updateSessionAction(id: decision.requestID, status: .denied, at: index)
            }
        case .providerSessionLifecycle(let lifecycle):
            providerSessionHealth[id] = lifecycle
            switch lifecycle.health {
            case .connecting, .healthy:
                break
            case .unhealthy(let issue):
                upsertActivity(.init(
                    icon: "exclamationmark.triangle",
                    title: "\(lifecycle.provider) session unhealthy",
                    detail: Self.providerSessionIssueDetail(issue)
                ), sessionID: id)
            case .reconnecting(let reconnect):
                upsertActivity(.init(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Reconnecting \(lifecycle.provider)",
                    detail: "Attempt \(reconnect.attempt) of \(reconnect.maximumAttempts)"
                ), sessionID: id)
            case .recovered:
                upsertActivity(.init(
                    icon: "checkmark.circle",
                    title: "\(lifecycle.provider) session recovered",
                    detail: "Structured provider session is healthy again."
                ), sessionID: id)
            }
        case .runCancelled(let cancellation):
            upsertActivity(.init(
                icon: "stop.circle",
                title: "Run cancelled",
                detail: cancellation.detail ?? cancellation.reason.rawValue
            ), sessionID: id)
        case .metric: break
        case .harnessActivity(let activity):
            let icon: String = switch activity.status {
            case .running: "terminal"
            case .completed: "checkmark.circle"
            case .failed: "xmark.octagon"
            case .cancelled: "stop.circle"
            case .degraded, .unsupported: "exclamationmark.triangle"
            }
            upsertActivity(.init(icon: icon, title: activity.title, detail: activity.detail), sessionID: id)
            if let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id {
                let status: SessionAction.Status = switch activity.status {
                case .running: .running
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                case .degraded, .unsupported: .completed
                }
                upsertSessionAction(.init(
                    id: activity.id,
                    messageID: messageID,
                    kind: .harness,
                    title: activity.title,
                    detail: activity.detail,
                    status: status
                ), at: index)
                persist()
            }
        case .providerDiagnostic(let diagnostic):
            upsertActivity(.init(icon: "exclamationmark.triangle", title: diagnostic.title, detail: diagnostic.detail), sessionID: id)
            if let action = ProviderDiagnosticRetentionPolicy.action(
                for: diagnostic,
                assistantMessageID: sessions[index].messages.last(where: { $0.role == .assistant })?.id
            ) {
                upsertSessionAction(action, at: index)
                persist()
            }
        case .artifact(let observation):
            // Core binding only — UI presentation is owned by a separate integration pass.
            guard sessions[index].isStreaming || sessions[index].isTranscriptLoaded,
                  let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            if !sessions[index].isArtifactsLoaded {
                do {
                    try persistence.materializeArtifacts(in: &sessions[index])
                } catch {
                    setError("Could not load stored artifact metadata for this chat.", sessionID: id)
                    return
                }
            }
            AssistantArtifactTrail.upsert(observation.bound(to: messageID), in: &sessions[index].artifacts)
            sessions[index].lastUpdated = .now
            scheduleStreamingPersist()
        case .computerFrame(let frame):
            var accumulator = computerFrameAccumulators[id] ?? ComputerFrameAccumulator(minimumInterval: 0.35, recentCapacity: 4)
            _ = accumulator.offer(frame)
            computerFrameAccumulators[id] = accumulator
            updateSessionAction(id: frame.id, status: .completed, at: index)
        case .completed:
            finalizeRun(.completed, sessionID: id, runID: runID, sessionIndex: index, backend: backend)
        case .cancelled:
            finalizeRun(.cancelled, sessionID: id, runID: runID, sessionIndex: index, backend: backend)
        case .failed(let message):
            finalizeRun(.failed(message), sessionID: id, runID: runID, sessionIndex: index, backend: backend)
        }
    }

    /// Single terminal ladder for completed / cancelled / failed / permission-denied runs.
    func finalizeRun(
        _ terminal: SessionRunTerminal,
        sessionID id: UUID,
        runID: UUID,
        sessionIndex index: Int,
        backend: ChatBackend
    ) {
        switch terminal {
        case .completed:
            computerFrameAccumulators[id]?.stop()
        case .cancelled, .permissionDenied:
            computerFrameAccumulators[id]?.cancel()
        case .failed:
            computerFrameAccumulators[id]?.stop()
        }

        let hadOutbox = dispatchingOutboxAttempt(for: id) != nil
        activeRunIDs[id] = nil
        inlineImagePayloadSuppression.remove(id)
        harnessPermissionNotices[id] = nil

        switch terminal {
        case .completed:
            finishCompletedTurnActions(at: index)
            recordWorkOutcome(.succeeded, title: "Work completed", detail: "", at: index)
            sessions[index].isStreaming = false
            reduceRunUI(.completed, for: id)
            threadActivityLanes.apply(.completed, to: id)
            let request = submittedRequests[id]
            if selfEditRunIDs.remove(id) != nil {
                _ = prepareGeneratedExtensionPreview(at: index, request: request)
            }
            submittedRequests[id] = nil
            retryableRequests[id] = nil
            if hadOutbox, !completeDispatchingOutbox(for: id) {
                persist()
                finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                    guard let self else { return }
                    self.handleSchedulerAdmissions(self.taskScheduler.finish(id))
                    self.persist()
                    self.scheduleIdleUnloadIfNeeded(for: backend)
                }
                return
            }
            persist()
            finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                guard let self else { return }
                self.handleSchedulerAdmissions(self.taskScheduler.finish(id))
                if self.runNextQueuedFollowUpIfPossible(for: id) { return }
                self.persist()
                self.scheduleIdleUnloadIfNeeded(for: backend)
            }

        case .cancelled:
            selfEditRunIDs.remove(id)
            finishPendingActions(status: .cancelled, at: index)
            recordWorkOutcome(.cancelled, title: "Work stopped", detail: "The run was cancelled before every item finished.", at: index)
            sessions[index].isStreaming = false
            if hadOutbox {
                failDispatchingOutbox(
                    for: id,
                    reason: .init(code: .cancelled, detail: "The provider run was cancelled before completion.")
                )
                retryableRequests[id] = nil
            } else if let request = submittedRequests[id] {
                retryableRequests[id] = request
            }
            submittedRequests[id] = nil
            reduceRunUI(.cancelled, for: id)
            threadActivityLanes.apply(.cancelled, to: id)
            if shouldRemoveEmptyTrailingAssistant(from: sessions[index]) {
                sessions[index].messages.removeLast()
            }
            persist()
            finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                guard let self else { return }
                self.handleSchedulerAdmissions(self.taskScheduler.finish(id))
                self.persist()
                self.scheduleIdleUnloadIfNeeded(for: backend)
            }

        case .failed(let message), .permissionDenied(let message):
            selfEditRunIDs.remove(id)
            if hadOutbox {
                failDispatchingOutbox(
                    for: id,
                    reason: .init(code: .providerUnavailable, detail: message)
                )
                retryableRequests[id] = nil
            } else if let request = submittedRequests[id] {
                retryableRequests[id] = request
            }
            submittedRequests[id] = nil
            let timedOut = message == "Permission request timed out."
            finishPendingActions(
                status: .failed,
                at: index,
                approvalOutcome: timedOut ? .timedOut : .failed,
                providerAcknowledgement: timedOut ? .timedOut : .unavailable
            )
            sessions[index].isStreaming = false
            reduceRunUI(.failed(message), for: id)
            threadActivityLanes.apply(.failed(message), to: id)
            if shouldRemoveEmptyTrailingAssistant(from: sessions[index]) {
                sessions[index].messages.removeLast()
            }
            recordWorkOutcome(.failed, title: "Work failed", detail: message, at: index)
            persist()
            finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                guard let self else { return }
                self.handleSchedulerAdmissions(self.taskScheduler.finish(id))
                self.persist()
                self.scheduleIdleUnloadIfNeeded(for: backend)
            }
        }
    }

    func recordWorkOutcome(
        _ outcome: SessionWorkSemantics.OutcomeKind,
        title: String,
        detail: String,
        at sessionIndex: Int
    ) {
        guard sessions[sessionIndex].executionRoute.mode == .work,
              let messageID = sessions[sessionIndex].messages.last(where: { $0.role == .assistant })?.id
                ?? sessions[sessionIndex].messages.last?.id else { return }
        upsertSessionAction(.init(
            messageID: messageID,
            kind: .harness,
            title: title,
            detail: detail,
            status: outcome == .failed ? .failed : (outcome == .cancelled ? .cancelled : .completed),
            work: .init(kind: .outcome, ownership: .providerBound, outcomeKind: outcome)
        ), at: sessionIndex)
    }

    static func providerSessionIssueDetail(_ issue: ProviderSessionIssue) -> String {
        switch issue {
        case .disconnected(let detail): detail
        case .sessionRejected(let detail): detail
        case .protocolViolation(let detail): detail
        case .unsupportedProvider(let provider): "The provider does not expose \(provider)."
        case .authenticationRequired: "The provider requires authentication."
        }
    }

    func updateApprovalProvenance(
        id: UUID,
        sessionIndex: Int,
        actor: ApprovalProvenance.Actor? = nil,
        selectedOptionKind: String? = nil,
        outcome: ApprovalProvenance.Outcome? = nil,
        providerAcknowledgement: ApprovalProvenance.ProviderAcknowledgement? = nil
    ) {
        guard let actionIndex = sessions[sessionIndex].actions.firstIndex(where: { $0.id == id }),
              var provenance = sessions[sessionIndex].actions[actionIndex].approvalProvenance else { return }
        if let actor { provenance.actor = actor }
        if let selectedOptionKind { provenance.selectedOptionKind = selectedOptionKind }
        if let outcome { provenance.outcome = outcome }
        if let providerAcknowledgement { provenance.providerAcknowledgement = providerAcknowledgement }
        provenance.updatedAt = .now
        sessions[sessionIndex].actions[actionIndex].approvalProvenance = provenance
        sessions[sessionIndex].lastUpdated = .now
    }

}
