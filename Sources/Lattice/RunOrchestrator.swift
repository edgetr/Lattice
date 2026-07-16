import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

/// Owns run lifecycle: start/launch/apply/finalize, scheduler admissions, and outbox dispatch.
/// Session catalog, persistence, and connection probes remain on AppState; this type is the
/// sole owner of active run IDs, scheduler state, and run UI maps.
@MainActor
final class RunOrchestrator: ObservableObject {
    weak var app: AppState?

    @Published var runUIStates: [UUID: RunUIState] = [:]
    var activeRunIDs: [UUID: UUID] = [:]
    var submittedRequests: [UUID: String] = [:]
    var retryableRequests: [UUID: String] = [:]
    var selfEditRunIDs: Set<UUID> = []
    var inlineImagePayloadSuppression: Set<UUID> = []
    var computerFrameAccumulators: [UUID: ComputerFrameAccumulator] = [:]
    var taskScheduler = AgentTaskScheduler(limits: .init(
        global: 4,
        perWorkspace: 2,
        providerCaps: ["codex": 2, "grok": 2, "opencode": 2, "antigravity": 1, "apple": 1, "ollama": 1],
        routeCaps: ["lattice/ollama": 1, "lattice/apple": 1]
    ))

    private var host: AppState {
        guard let app else {
            preconditionFailure("RunOrchestrator.app must be wired before run lifecycle use")
        }
        return app
    }

    enum FinalizeSchedulerCompletion {
        case finish
        case cancel
    }

    func apply(_ event: AgentEvent, to id: UUID, runID: UUID) {
        guard activeRunIDs[id] == runID else { return }
        guard let index = host.sessions.firstIndex(where: { $0.id == id }) else { return }
        let backend = host.sessions[index].backend
        switch event {
        case .sessionStarted: break
        case .harnessSessionStarted(let threadID):
            host.sessions[index].harnessThreadID = threadID
            host.persist()
        case .harnessSessionRecovery(let detail):
            host.sessions[index].harnessThreadID = nil
            host.setActivity([.init(icon: "arrow.triangle.2.circlepath", title: "Provider session recovery", detail: detail)], sessionID: id)
            host.persist()
        case .assistantDelta(let delta):
            guard let messageIndex = host.sessions[index].messages.indices.last,
                  host.sessions[index].messages[messageIndex].role == .assistant else { return }
            let reduceState = SessionRunState(
                isStreaming: host.sessions[index].isStreaming,
                lastAssistantText: host.sessions[index].messages[messageIndex].text,
                hasAssistantMessage: true,
                isSuppressingInlineImagePayload: inlineImagePayloadSuppression.contains(id)
            )
            let reduced = SessionRunReducer.reduce(state: reduceState, event: .assistantDelta(delta))
            guard let assistantText = reduced.assistantText else { return }
            host.sessions[index].messages[messageIndex].text = assistantText
            if reduced.isSuppressingInlineImagePayload == true {
                inlineImagePayloadSuppression.insert(id)
            } else if reduced.isSuppressingInlineImagePayload == false {
                inlineImagePayloadSuppression.remove(id)
            }
            host.sessions[index].lastUpdated = .now
            host.scheduleStreamingPersist()
        case .plan(let actionID, let title, let explanation, let steps):
            guard let messageID = host.sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            host.upsertSessionAction(.init(
                id: actionID,
                messageID: messageID,
                kind: .plan,
                title: title,
                detail: explanation ?? "",
                status: .running
            ), at: index)
            // Durable plan artifact only for user-started Code · Lattice Agent guided plan.
            // Never promote .normal → restricted tools from opportunistic provider plan events.
            if host.sessions[index].executionRoute.mode == .code,
               host.sessions[index].executionRoute.runtimeID == "pi",
               host.sessions[index].codePhase == .planActive {
                let body = ([explanation].compactMap { $0 } + steps.map(\.title))
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                let prior = host.sessions[index].codePlan
                host.sessions[index].codePlan = CodePlanArtifact(
                    title: title,
                    body: body.isEmpty ? (prior?.body ?? "") : body,
                    revision: (prior?.revision ?? 0) + 1
                )
                host.sessions[index].codePhase = .planAwaitingApproval
            }
            for step in steps {
                let status: SessionAction.Status = switch step.status {
                case .pending: .waiting
                case .inProgress: .running
                case .completed: .completed
                }
                host.upsertSessionAction(.init(
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
            guard let messageID = host.sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            if SessionActionTrail.appendDetail(id: actionID, delta: delta, in: &host.sessions[index].actions) {
                host.sessions[index].lastUpdated = .now
                host.scheduleStreamingPersist()
            } else {
                host.upsertSessionAction(.init(
                    id: actionID,
                    messageID: messageID,
                    kind: .reasoning,
                    title: "Reasoning summary",
                    detail: delta,
                    status: .running
                ), at: index)
            }
        case .toolRequested(let request):
            guard let messageID = host.sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            host.upsertSessionAction(.init(
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
            host.updateSessionAction(id: toolID, status: detail == "Failed" ? .failed : (detail == "Cancelled" ? .cancelled : (detail == "Completed" ? .completed : .running)), at: index)
        case .permissionRequested(let request):
            let harnessID = host.effectiveHarnessID(for: host.sessions[index])
            let notice = HarnessPermissionNotice(
                sessionID: id,
                harnessID: harnessID,
                providerName: harnessID == "codex" ? "Codex" : (harnessID == "grok" ? "Grok" : (harnessID == "opencode" ? "OpenCode" : (harnessID == "pi" ? LatticeAgentExecutable.productDisplayName : "Hermes"))),
                request: request
            )
            let automaticDecision = request.toolRequest.map { host.policyEngine.evaluate($0, under: host.sessions[index].policy) }
            let policyReason: String = {
                switch automaticDecision {
                case .allow(let reason), .requireApproval(let reason), .deny(let reason): return reason
                case nil: return "The provider requested an explicit permission decision."
                }
            }()
            if let messageID = host.sessions[index].messages.last(where: { $0.role == .assistant })?.id {
                host.upsertSessionAction(.init(
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
                        policy: host.sessions[index].policy,
                        policyReason: policyReason,
                        actor: .user
                    ),
                    work: .init(kind: .approval, ownership: .providerBound)
                ), at: index)
            }
            let automaticResolution = AutomaticPermissionResolutionPolicy.resolve(
                decision: automaticDecision,
                policy: host.sessions[index].policy,
                options: request.options
            )
            switch automaticResolution {
            case .forward(let optionID, let allowed):
                guard host.forwardHarnessPermission(notice, optionID: optionID) else {
                    host.harnessPermissionNotices[id] = nil
                    updateApprovalProvenance(
                        id: request.id,
                        sessionIndex: index,
                        actor: .automatic,
                        selectedOptionKind: request.options.first(where: { $0.id == optionID })?.kind,
                        outcome: .failed,
                        providerAcknowledgement: .rejectedByHarness
                    )
                    host.updateSessionAction(id: request.id, status: allowed ? .cancelled : .denied, at: index)
                    host.cancelHarnessProcess(for: host.sessions[index], sessionID: id)
                    finalizeRun(
                        .permissionDenied("The provider rejected Lattice's automatic permission decision."),
                        sessionID: id,
                        runID: runID,
                        sessionIndex: index,
                        backend: backend
                    )
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
                host.updateSessionAction(id: request.id, status: allowed ? .allowed : .denied, at: index)
                host.setActivity([.init(icon: allowed ? "checkmark.shield" : "xmark.shield", title: allowed ? "Allowed by \(host.sessions[index].policy.rawValue.capitalized) mode" : "Blocked by policy", detail: request.title)], sessionID: id)
                host.reduceRunUI(.permissionResolved, for: id)
                host.threadActivityLanes.apply(.approvalResolved, to: id)
            case .denyFailClosed(let reason):
                let cancellationForwarded = host.forwardHarnessPermission(notice, optionID: nil)
                host.harnessPermissionNotices[id] = nil
                updateApprovalProvenance(
                    id: request.id,
                    sessionIndex: index,
                    actor: .automatic,
                    outcome: cancellationForwarded ? .forwarded : .failed,
                    providerAcknowledgement: cancellationForwarded ? .acceptedByHarness : .unavailable
                )
                host.updateSessionAction(id: request.id, status: .denied, at: index)
                host.cancelHarnessProcess(for: host.sessions[index], sessionID: id)
                finalizeRun(
                    .permissionDenied("Blocked by Lattice policy: \(reason)"),
                    sessionID: id,
                    runID: runID,
                    sessionIndex: index,
                    backend: backend
                )
            case .requestUser:
                host.harnessPermissionNotices[id] = notice
                host.setActivity([.init(icon: "hand.raised.fill", title: request.title, detail: "Waiting for your decision")], sessionID: id)
                host.reduceRunUI(.permissionRequested, for: id)
                host.threadActivityLanes.apply(.approvalRequested, to: id)
                // Structured harnesses are suspended at this boundary with no tool executing,
                // so capacity can be released and must be reacquired before forwarding a choice.
                handleSchedulerAdmissions(taskScheduler.waitForApproval(id, releasesExecutionSlot: true))
            }
        case .permissionDecided(let decision):
            if host.harnessPermissionNotices[id]?.request.id == decision.requestID {
                host.harnessPermissionNotices[id] = nil
            }
            switch decision.outcome {
            case .selected(_, let kind):
                host.updateSessionAction(
                    id: decision.requestID,
                    status: kind.hasPrefix("allow_") ? .allowed : .denied,
                    at: index
                )
            case .cancelled:
                host.updateSessionAction(id: decision.requestID, status: .denied, at: index)
            }
        case .providerSessionLifecycle(let lifecycle):
            host.providerSessionHealth[id] = lifecycle
            switch lifecycle.health {
            case .connecting, .healthy:
                break
            case .unhealthy(let issue):
                host.upsertActivity(.init(
                    icon: "exclamationmark.triangle",
                    title: "\(lifecycle.provider) session unhealthy",
                    detail: AppState.providerSessionIssueDetail(issue)
                ), sessionID: id)
            case .reconnecting(let reconnect):
                host.upsertActivity(.init(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Reconnecting \(lifecycle.provider)",
                    detail: "Attempt \(reconnect.attempt) of \(reconnect.maximumAttempts)"
                ), sessionID: id)
            case .recovered:
                host.upsertActivity(.init(
                    icon: "checkmark.circle",
                    title: "\(lifecycle.provider) session recovered",
                    detail: "Structured provider session is healthy again."
                ), sessionID: id)
            }
        case .runCancelled(let cancellation):
            host.upsertActivity(.init(
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
            host.upsertActivity(.init(icon: icon, title: activity.title, detail: activity.detail), sessionID: id)
            if let messageID = host.sessions[index].messages.last(where: { $0.role == .assistant })?.id {
                let status: SessionAction.Status = switch activity.status {
                case .running: .running
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                case .degraded, .unsupported: .completed
                }
                host.upsertSessionAction(.init(
                    id: activity.id,
                    messageID: messageID,
                    kind: .harness,
                    title: activity.title,
                    detail: activity.detail,
                    status: status
                ), at: index)
                host.persist()
            }
        case .providerDiagnostic(let diagnostic):
            host.upsertActivity(.init(icon: "exclamationmark.triangle", title: diagnostic.title, detail: diagnostic.detail), sessionID: id)
            if let action = ProviderDiagnosticRetentionPolicy.action(
                for: diagnostic,
                assistantMessageID: host.sessions[index].messages.last(where: { $0.role == .assistant })?.id
            ) {
                host.upsertSessionAction(action, at: index)
                host.persist()
            }
        case .artifact(let observation):
            // Core binding only — UI presentation is owned by a separate integration pass.
            guard host.sessions[index].isStreaming || host.sessions[index].isTranscriptLoaded,
                  let messageID = host.sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            if !host.sessions[index].isArtifactsLoaded {
                do {
                    try host.persistence.materializeArtifacts(in: &host.sessions[index])
                } catch {
                    host.setError("Could not load stored artifact metadata for this chat.", sessionID: id)
                    return
                }
            }
            AssistantArtifactTrail.upsert(observation.bound(to: messageID), in: &host.sessions[index].artifacts)
            host.sessions[index].lastUpdated = .now
            host.scheduleStreamingPersist()
        case .computerFrame(let frame):
            var accumulator = computerFrameAccumulators[id] ?? ComputerFrameAccumulator(minimumInterval: 0.35, recentCapacity: 4)
            _ = accumulator.offer(frame)
            computerFrameAccumulators[id] = accumulator
            host.updateSessionAction(id: frame.id, status: .completed, at: index)
        case .completed, .cancelled, .failed:
            // Terminal classification is pure; side-effect ladder is finalizeRun only.
            guard let terminal = SessionRunReducer.terminal(for: event) else { return }
            finalizeRun(terminal, sessionID: id, runID: runID, sessionIndex: index, backend: backend)
        }
    }


    /// Single terminal ladder for completed / cancelled / failed / permission-denied runs.
    func finalizeRun(
        _ terminal: SessionRunTerminal,
        sessionID id: UUID,
        runID: UUID,
        sessionIndex index: Int,
        backend: ChatBackend,
        schedulerCompletion: FinalizeSchedulerCompletion = .finish
    ) {
        // Only the currently active run may finalize once. Nil or mismatched runIDs are stale.
        guard activeRunIDs[id] == runID else { return }

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
        host.harnessPermissionNotices[id] = nil

        let admit: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            switch schedulerCompletion {
            case .finish:
                self.handleSchedulerAdmissions(self.taskScheduler.finish(id))
            case .cancel:
                self.handleSchedulerAdmissions(self.taskScheduler.cancel(id))
            }
        }

        switch terminal {
        case .completed:
            host.finishCompletedTurnActions(at: index)
            recordWorkOutcome(.succeeded, title: "Work completed", detail: "", at: index)
            host.sessions[index].isStreaming = false
            host.reduceRunUI(.completed, for: id)
            host.threadActivityLanes.apply(.completed, to: id)
            let request = submittedRequests[id]
            if selfEditRunIDs.remove(id) != nil {
                _ = host.prepareGeneratedExtensionPreview(at: index, request: request)
            }
            submittedRequests[id] = nil
            retryableRequests[id] = nil
            if hadOutbox, !completeDispatchingOutbox(for: id) {
                host.persist()
                finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                    guard let self else { return }
                    admit()
                    self.app?.persist()
                    self.app?.scheduleIdleUnloadIfNeeded(for: backend)
                }
                return
            }
            host.persist()
            finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                guard let self else { return }
                admit()
                if self.runNextQueuedFollowUpIfPossible(for: id) { return }
                self.app?.persist()
                self.app?.scheduleIdleUnloadIfNeeded(for: backend)
            }

        case .cancelled:
            selfEditRunIDs.remove(id)
            host.finishPendingActions(status: .cancelled, at: index)
            recordWorkOutcome(.cancelled, title: "Work stopped", detail: "The run was cancelled before every item finished.", at: index)
            host.sessions[index].isStreaming = false
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
            host.reduceRunUI(.cancelled, for: id)
            host.threadActivityLanes.apply(.cancelled, to: id)
            if host.shouldRemoveEmptyTrailingAssistant(from: host.sessions[index]) {
                host.sessions[index].messages.removeLast()
            }
            host.persist()
            finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                guard let self else { return }
                admit()
                self.app?.persist()
                self.app?.scheduleIdleUnloadIfNeeded(for: backend)
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
            let isPermissionDenied: Bool = {
                if case .permissionDenied = terminal { return true }
                return false
            }()
            host.finishPendingActions(
                status: .failed,
                at: index,
                approvalOutcome: timedOut ? .timedOut : .failed,
                providerAcknowledgement: timedOut ? .timedOut : (isPermissionDenied ? .rejectedByHarness : .unavailable)
            )
            host.sessions[index].isStreaming = false
            host.reduceRunUI(.failed(message), for: id)
            host.threadActivityLanes.apply(.failed(message), to: id)
            if host.shouldRemoveEmptyTrailingAssistant(from: host.sessions[index]) {
                host.sessions[index].messages.removeLast()
            }
            recordWorkOutcome(.failed, title: "Work failed", detail: message, at: index)
            host.persist()
            finishSchedulerRunAfterCheckpoint(sessionID: id, runID: runID) { [weak self] in
                guard let self else { return }
                admit()
                self.app?.persist()
                self.app?.scheduleIdleUnloadIfNeeded(for: backend)
            }
        }
    }

    func recordWorkOutcome(
        _ outcome: SessionWorkSemantics.OutcomeKind,
        title: String,
        detail: String,
        at sessionIndex: Int
    ) {
        guard host.sessions[sessionIndex].executionRoute.mode == .work,
              let messageID = host.sessions[sessionIndex].messages.last(where: { $0.role == .assistant })?.id
                ?? host.sessions[sessionIndex].messages.last?.id else { return }
        host.upsertSessionAction(.init(
            messageID: messageID,
            kind: .harness,
            title: title,
            detail: detail,
            status: outcome == .failed ? .failed : (outcome == .cancelled ? .cancelled : .completed),
            work: .init(kind: .outcome, ownership: .providerBound, outcomeKind: outcome)
        ), at: sessionIndex)
    }

    func updateApprovalProvenance(
        id: UUID,
        sessionIndex: Int,
        actor: ApprovalProvenance.Actor? = nil,
        selectedOptionKind: String? = nil,
        outcome: ApprovalProvenance.Outcome? = nil,
        providerAcknowledgement: ApprovalProvenance.ProviderAcknowledgement? = nil
    ) {
        guard let actionIndex = host.sessions[sessionIndex].actions.firstIndex(where: { $0.id == id }),
              var provenance = host.sessions[sessionIndex].actions[actionIndex].approvalProvenance else { return }
        if let actor { provenance.actor = actor }
        if let selectedOptionKind { provenance.selectedOptionKind = selectedOptionKind }
        if let outcome { provenance.outcome = outcome }
        if let providerAcknowledgement { provenance.providerAcknowledgement = providerAcknowledgement }
        provenance.updatedAt = .now
        host.sessions[sessionIndex].actions[actionIndex].approvalProvenance = provenance
        host.sessions[sessionIndex].lastUpdated = .now
    }


    @discardableResult
    func runNextQueuedFollowUpIfPossible(for id: UUID) -> Bool {
        guard let index = host.sessions.firstIndex(where: { $0.id == id }),
              !host.sessions[index].isStreaming,
              let followUp = host.sessions[index].queuedFollowUps.first else { return false }
        return dispatchQueuedFollowUp(followUp.id, sessionID: id, afterExplicitReview: false)
    }

    @discardableResult
    func dispatchQueuedFollowUp(
        _ queuedID: UUID,
        sessionID id: UUID,
        afterExplicitReview: Bool
    ) -> Bool {
        guard let index = host.sessions.firstIndex(where: { $0.id == id }),
              !host.sessions[index].isStreaming,
              let entryIndex = host.sessions[index].queuedFollowUps.firstIndex(where: { $0.id == queuedID }),
              entryIndex == host.sessions[index].queuedFollowUps.startIndex else { return false }

        // Resolve legacy/runtime route normalization before comparing the captured authority.
        // A normalization that changes execution context must block auto-send like any user change.
        host.normalizeSessionBackendBeforeRun(at: index)
        let context = host.inputOutboxContext(for: host.sessions[index])
        if afterExplicitReview {
            switch SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: queuedID,
                currentContext: context,
                in: host.sessions[index].queuedFollowUps
            ) {
            case .eligible:
                break
            case .ineligible(.contextMismatch):
                host.sessions[index].queuedFollowUps[entryIndex].lifecycle = .blocked(.contextMismatch)
                fallthrough
            case .ineligible:
                guard SessionInputOutboxPolicy.acceptExplicitReview(
                    entryID: queuedID,
                    currentContext: context,
                    in: &host.sessions[index].queuedFollowUps
                ) == .applied else { return false }
            }
        } else {
            guard SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: queuedID,
                currentContext: context,
                in: host.sessions[index].queuedFollowUps
            ) == .eligible else {
                if host.sessions[index].queuedFollowUps[entryIndex].context != context,
                   host.sessions[index].queuedFollowUps[entryIndex].context != nil {
                    host.sessions[index].queuedFollowUps[entryIndex].lifecycle = .blocked(.contextMismatch)
                    host.sessions[index].lastUpdated = .now
                    host.persist()
                }
                return false
            }
        }

        let beforeClaim = host.sessions[index]
        let attemptID = UUID()
        guard SessionInputOutboxPolicy.claimDispatch(
            entryID: queuedID,
            currentContext: context,
            in: &host.sessions[index].queuedFollowUps,
            attemptID: attemptID
        ) == .claimed(attemptID: attemptID) else { return false }
        host.sessions[index].lastUpdated = .now
        guard host.persist() == .saved else {
            host.sessions[index] = beforeClaim
            return false
        }

        guard let followUp = host.sessions[index].queuedFollowUps.first(where: { $0.id == queuedID }),
              let submission = host.prepareSubmission(followUp.text) else {
            _ = SessionInputOutboxPolicy.recordFailure(
                entryID: queuedID,
                attemptID: attemptID,
                reason: .init(code: .localValidationFailed, detail: "The queued input is no longer valid."),
                in: &host.sessions[index].queuedFollowUps
            )
            host.sessions[index].lastUpdated = .now
            host.persist()
            return false
        }

        let accepted: Bool
        if host.sessions[index].messages.contains(where: { $0.id == queuedID && $0.role == .user }) {
            accepted = restartAcceptedOutboxSubmission(submission, for: id, at: index)
        } else {
            accepted = host.startPreparedSubmission(submission, for: id, at: index, sourceOutboxID: queuedID)
        }
        guard accepted else {
            if let refreshedIndex = host.sessions.firstIndex(where: { $0.id == id }) {
                _ = SessionInputOutboxPolicy.recordFailure(
                    entryID: queuedID,
                    attemptID: attemptID,
                    reason: .init(code: .providerUnavailable, detail: "The selected route is unavailable."),
                    in: &host.sessions[refreshedIndex].queuedFollowUps
                )
                host.sessions[refreshedIndex].lastUpdated = .now
                host.persist()
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
        guard host.canRunSession(host.sessions[index]) else {
            host.setError(host.routeUnavailableMessage(for: host.sessions[index]) ?? "Choose a connected model.", sessionID: id)
            return false
        }
        guard host.ensureUnsafeProviderRouteAcknowledged(for: host.sessions[index]) else { return false }
        let beforeSubmission = host.sessions[index]
        host.markConversationOutgoingAction(for: id)
        host.sessions[index].messages.append(.init(role: .assistant, text: ""))
        submittedRequests[id] = submission.runText
        retryableRequests[id] = nil
        guard startRun(for: id, at: index, submittedText: submission.runText) else {
            host.sessions[index] = beforeSubmission
            submittedRequests[id] = nil
            return false
        }
        return true
    }

    func dispatchingOutboxAttempt(for id: UUID) -> (entryID: UUID, attemptID: UUID)? {
        guard let session = host.sessions.first(where: { $0.id == id }),
              let entry = session.queuedFollowUps.first else { return nil }
        guard case .dispatching(let attemptID) = entry.lifecycle else { return nil }
        return (entry.id, attemptID)
    }

    @discardableResult
    func completeDispatchingOutbox(for id: UUID) -> Bool {
        guard let index = host.sessions.firstIndex(where: { $0.id == id }),
              let attempt = dispatchingOutboxAttempt(for: id) else { return true }
        let beforeDequeue = host.sessions[index]
        var outbox = host.sessions[index].queuedFollowUps
        var receipts = host.sessions[index].inputOutboxReceipts
        let result = SessionInputOutboxPolicy.completeLocalDequeue(
            entryID: attempt.entryID,
            attemptID: attempt.attemptID,
            in: &outbox,
            ledger: &receipts
        )
        switch result {
        case .dequeued, .alreadyDequeued:
            break
        case .rejected(let rejection):
            // Provider finished but local dequeue was rejected — leave a durable failure, not a stuck claim.
            _ = SessionInputOutboxPolicy.recordFailure(
                entryID: attempt.entryID,
                attemptID: attempt.attemptID,
                reason: .init(
                    code: .dispatchRejected,
                    detail: "Local dequeue was rejected (\(String(describing: rejection))). Review the queued input before retrying."
                ),
                in: &host.sessions[index].queuedFollowUps
            )
            host.sessions[index].lastUpdated = .now
            host.threadActivityLanes.apply(.queued(host.sessions[index].queuedFollowUps.count), to: id)
            return false
        }
        host.sessions[index].queuedFollowUps = outbox
        host.sessions[index].inputOutboxReceipts = receipts
        host.sessions[index].lastUpdated = .now
        host.threadActivityLanes.apply(.queued(host.sessions[index].queuedFollowUps.count), to: id)
        guard host.persist() == .saved else {
            host.sessions[index] = beforeDequeue
            _ = SessionInputOutboxPolicy.recordFailure(
                entryID: attempt.entryID,
                attemptID: attempt.attemptID,
                reason: .init(
                    code: .dispatchRejected,
                    detail: "The provider completed, but local dequeue could not be saved. Remove it after confirming the response, or review before retrying."
                ),
                in: &host.sessions[index].queuedFollowUps
            )
            host.threadActivityLanes.apply(.queued(host.sessions[index].queuedFollowUps.count), to: id)
            return false
        }
        return true
    }

    func failDispatchingOutbox(for id: UUID, reason: QueuedFollowUpFailureReason) {
        guard let index = host.sessions.firstIndex(where: { $0.id == id }),
              let attempt = dispatchingOutboxAttempt(for: id) else { return }
        _ = SessionInputOutboxPolicy.recordFailure(
            entryID: attempt.entryID,
            attemptID: attempt.attemptID,
            reason: reason,
            in: &host.sessions[index].queuedFollowUps
        )
        host.sessions[index].lastUpdated = .now
        host.threadActivityLanes.apply(.queued(host.sessions[index].queuedFollowUps.count), to: id)
    }

    @discardableResult
    func startRun(for id: UUID, at index: Int, submittedText: String) -> Bool {
        // Defense in depth: every provider stream launch stays behind the same
        // acknowledgement check, even if a future caller skips send validation.
        guard host.ensureUnsafeProviderRouteAcknowledged(for: host.sessions[index]) else {
            host.sessions[index].isStreaming = false
            host.setError("Provider route blocked until its unsafe-route acknowledgement is accepted.", sessionID: id)
            return false
        }
        host.sessions[index].isStreaming = true
        inlineImagePayloadSuppression.remove(id)
        host.sessions[index].lastUpdated = .now
        computerFrameAccumulators[id] = ComputerFrameAccumulator(minimumInterval: 0.35, recentCapacity: 4)
        host.globalErrorMessage = nil
        let session = host.sessions[index]
        let harnessID = host.effectiveHarnessID(for: session)
        let providerID = RouteRuntimeMap.providerID(for: session)
        let routeID = "\(harnessID)/\(providerID)"
        let isExtensionSelfEdit = host.isExtensionSelfEditThread(session, submittedText: submittedText)
        let sensitivity: AgentTaskRecoverySensitivity = isExtensionSelfEdit
            ? .externallyConsequential
            : (session.policy == .yolo ? .ordinary : .approvalSensitive)
        let request = AgentTaskSchedulerRequest(
            id: id,
            sessionID: id,
            resources: .init(
                workspaceID: host.workspaceURL(for: session, isExtensionSelfEdit: isExtensionSelfEdit).standardizedFileURL.path,
                providerID: providerID,
                routeID: routeID
            ),
            priority: host.threadActivityLanes.lane(for: id).priority,
            recoverySensitivity: sensitivity
        )
        if taskScheduler.snapshot(for: id)?.state == .recoveryHeld {
            taskScheduler.discardRecovered(id)
        }
        let admitted = taskScheduler.submit(request)
        host.threadActivityLanes.apply(.queued(1 + session.queuedFollowUps.count), to: id)
        guard host.persist() == .saved else {
            host.sessions[index].isStreaming = false
            let newlyAdmitted = taskScheduler.cancel(id)
            host.persistSchedulerMetadata()
            handleSchedulerAdmissions(newlyAdmitted)
            refreshSchedulerLanes()
            return false
        }
        host.persistSchedulerMetadata()
        handleSchedulerAdmissions(admitted)
        refreshSchedulerLanes()
        return true
    }

    func launchScheduledRun(for id: UUID) {
        guard let index = host.sessions.firstIndex(where: { $0.id == id }),
              let submittedText = submittedRequests[id],
              taskScheduler.snapshot(for: id)?.state == .running else { return }
        let session = host.sessions[index]
        let runID = UUID()
        activeRunIDs[id] = runID
        guard session.executionRoute.mode == .code else {
            launchScheduledProviderRun(for: id, runID: runID)
            return
        }

        let isExtensionSelfEdit = host.isExtensionSelfEditThread(session, submittedText: submittedText)
        let workspace = host.workspaceURL(for: session, isExtensionSelfEdit: isExtensionSelfEdit)
        host.checkpointReviewStates[id] = WorkspaceCheckpointReviewState(
            sessionID: id,
            runID: runID,
            worktreePath: workspace.standardizedFileURL.path,
            activity: .capturingBefore
        )
        let client = host.checkpointClient
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
                self?.app?.checkpointReviewStates[id]?.beforeCheckpoint = checkpoint
                self?.app?.checkpointReviewStates[id]?.activity = .running
                self?.app?.checkpointReviewStates[id]?.issue = nil
            } catch {
                guard self?.activeRunIDs[id] == runID,
                      self?.taskScheduler.snapshot(for: id)?.state == .running else { return }
                self?.app?.checkpointReviewStates[id]?.activity = .running
                self?.app?.checkpointReviewStates[id]?.issue = self?.app?.checkpointMessage(for: error)
            }
            self?.launchScheduledProviderRun(for: id, runID: runID)
        }
    }

    func launchScheduledProviderRun(for id: UUID, runID: UUID) {
        guard activeRunIDs[id] == runID,
              let index = host.sessions.firstIndex(where: { $0.id == id }),
              let submittedText = submittedRequests[id],
              taskScheduler.snapshot(for: id)?.state == .running else { return }
        host.threadActivityLanes.apply(.started, to: id)
        host.reduceRunUI(.started, for: id)

        let session = host.sessions[index]
        if let integrityIssue = host.sessionMayLaunchProviderRun(session) {
            let failedStream = AsyncStream<AgentEvent> { continuation in
                continuation.yield(.failed(integrityIssue))
                continuation.finish()
            }
            Task { for await event in failedStream { apply(event, to: id, runID: runID) } }
            return
        }
        // Full readiness recheck immediately before Keychain read / stream (not only at send).
        guard host.canRunSession(session) else {
            let detail = host.routeUnavailableMessage(for: session) ?? "Choose a connected model."
            let failedStream = AsyncStream<AgentEvent> { continuation in
                continuation.yield(.failed(detail))
                continuation.finish()
            }
            Task { for await event in failedStream { apply(event, to: id, runID: runID) } }
            return
        }
        let isExtensionSelfEdit = host.isExtensionSelfEditThread(session, submittedText: submittedText)
        if isExtensionSelfEdit { selfEditRunIDs.insert(id) }
        else { selfEditRunIDs.remove(id) }
        let workspace = host.workspaceURL(for: session, isExtensionSelfEdit: isExtensionSelfEdit)
        let reasoningEffort = host.validReasoningEffort(for: session)
        let additionalContext = host.backendAdditionalContext(for: session, submittedText: submittedText)
        let tokenLimit = host.contextTokenLimit(for: session)
        let stream: AsyncStream<AgentEvent>
        let harnessID = host.effectiveHarnessID(for: session)
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
        // Do not mutate harnessThreadID / compactContextOnNextSend until the run can actually
        // start (after deliveryIssue + envelope success). On early failure keep both so the
        // user can retry or cancel compact without losing provider continuity.
        let routeThreadID = launchPlan.routeThreadID
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
        let skillID: String? = {
            if let invocation = LatticeSkillPromptBuilder.invocation(
                in: submittedText,
                records: host.skills,
                disabledSkillIDs: host.effectiveDisabledSkillIDs
            ) {
                return invocation.skillID
            }
            return nil
        }()
        let planRestrictsWrites = session.executionRoute.mode == .code
            && session.executionRoute.runtimeID == "pi"
            && session.codePhase.restrictsMutatingTools
        let allowFileModification = !isExtensionSelfEdit && !planRestrictsWrites
        do {
            envelope = try host.instructionEnvelope(
                for: session,
                workspace: workspace,
                allowFileModification: allowFileModification,
                submittedText: submittedText,
                isExtensionSelfEdit: isExtensionSelfEdit,
                skillID: skillID
            )
            envelopeError = nil
        } catch {
            envelope = nil
            envelopeError = error.localizedDescription
        }
        // Declared Lattice Agent routes require a real envelope; surface construction errors honestly.
        if harnessID == "pi" || (ExecutionRouteResolver.isDeclared(session.executionRoute) && session.executionRoute.runtimeID == "pi") {
            if envelope == nil {
                let detail = envelopeError.map { "Could not build Lattice Agent instruction envelope: \($0)" }
                    ?? "Could not build Lattice Agent instruction envelope for this route."
                let failedStream = AsyncStream<AgentEvent> { continuation in
                    continuation.yield(.failed(detail))
                    continuation.finish()
                }
                Task { for await event in failedStream { apply(event, to: id, runID: runID) } }
                return
            }
        }
        // Handoff accepted and envelope ready: apply one-shot compact / session reset side effects.
        if launchPlan.resetsHarnessSession {
            host.sessions[index].harnessThreadID = nil
        }
        if host.sessions[index].compactContextOnNextSend {
            host.sessions[index].compactContextOnNextSend = false
        }
        if launchPlan.resetsHarnessSession || launchPlan.didCompact {
            host.persist()
        }
        if let statusDetail = launchPlan.statusDetail {
            host.setActivity([.init(icon: launchPlan.didCompact ? "arrow.triangle.2.circlepath" : "doc.text.magnifyingglass", title: launchPlan.didCompact ? "Context compacted" : "Context handoff", detail: statusDetail)], sessionID: id)
        }
        let trustedInstructions = envelope.map {
            host.trustedWorkspaceInstructionText(for: workspace, names: $0.trustedWorkspaceInstructionNames)
        } ?? ""
        let developerInstructions = envelope.map {
            [$0.renderedSystemInstructions, trustedInstructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let openCodeAPIKey = OpenCodeCredentialPolicy.allowsKeychainCredential(
            for: session.executionRoute,
            enabledModes: host.openCodeCredentialEnabledModes
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
            host.cancelLocalModelIdleUnload()
            host.localModelStatus = "Loaded \(model)"
            return LatticeBackendMessageBuilder.structuredMessages(session: session, submittedText: submittedText, additionalContext: additionalContext, contextPlan: localContextPlan)
        }()
        stream = host.executionCoordinator.stream(
            LatticeExecutionLaunch(
                sessionID: id,
                route: session.executionRoute,
                legacyHarnessID: harnessID,
                backend: session.backend,
                prompt: prompt,
                attachments: session.attachments,
                imageInputCapability: host.imageInputCapability(for: session),
                threadID: routeThreadID,
                workspace: workspace,
                reasoningEffort: reasoningEffort,
                policy: isExtensionSelfEdit ? .ask : session.policy,
                allowFileModification: allowFileModification,
                workspaceWrite: isExtensionSelfEdit ? SelfEditProviderLaunchPolicy.codexWorkspaceWrite : false,
                recoveryPrompt: recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: recoveryDeliveryIssue,
                instructionEnvelope: envelope,
                developerInstructions: developerInstructions,
                hermesProvider: host.hermesProvider(for: session.executionRoute),
                hermesSystemIdentity: developerInstructions,
                openCodeAPIKey: openCodeAPIKey,
                appleTranscript: appleTranscript,
                ollamaMessages: ollamaMessages,
                localModelKeepAliveSeconds: host.localModelIdleUnloadMinutes * 60
            ),
            runtimes: host.executionRuntimes
        )
        Task { for await event in stream { apply(event, to: id, runID: runID) } }
    }

    func finishSchedulerRunAfterCheckpoint(
        sessionID id: UUID,
        runID: UUID,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let review = host.checkpointReviewStates[id],
              review.runID == runID,
              host.sessions.first(where: { $0.id == id })?.executionRoute.mode == .code else {
            completion()
            return
        }
        host.checkpointReviewStates[id]?.activity = .capturingAfter
        let workspace = URL(fileURLWithPath: review.worktreePath, isDirectory: true)
        let client = host.checkpointClient
        Task { [weak self] in
            defer { completion() }
            do {
                let after = try await client.capture(
                    worktreeURL: workspace,
                    sessionID: id,
                    runID: runID,
                    boundary: .afterRun
                )
                guard self?.app?.checkpointReviewStates[id]?.runID == runID else { return }
                self?.app?.checkpointReviewStates[id]?.afterCheckpoint = after
                // A stop can clear the active run while the before capture is still
                // finishing. Recover the durable before record instead of reporting a
                // false incomplete pair when the actor already persisted it.
                var before = self?.app?.checkpointReviewStates[id]?.beforeCheckpoint
                if before == nil {
                    if let checkpoints = try? await client.checkpoints(sessionID: id) {
                        before = checkpoints.first(where: { $0.ownership.runID == runID && $0.boundary == .beforeRun })
                    }
                    self?.app?.checkpointReviewStates[id]?.beforeCheckpoint = before
                }
                if let before, before.status == .captured, after.status == .captured {
                    do {
                        let changes = try await client.changes(
                            beforeCheckpointID: before.id,
                            afterCheckpointID: after.id
                        )
                        self?.app?.checkpointReviewStates[id]?.changes = changes
                        self?.app?.checkpointReviewStates[id]?.notes = (try? await client.reviewNotes(checkpointID: after.id)) ?? []
                        self?.app?.checkpointReviewStates[id]?.activity = .ready
                        self?.app?.checkpointReviewStates[id]?.issue = nil
                    } catch {
                        self?.app?.checkpointReviewStates[id]?.activity = .failed
                        self?.app?.checkpointReviewStates[id]?.issue = self?.app?.checkpointMessage(for: error)
                    }
                } else {
                    self?.app?.checkpointReviewStates[id]?.activity = .failed
                    if self?.app?.checkpointReviewStates[id]?.issue == nil {
                        self?.app?.checkpointReviewStates[id]?.issue = "The before-run checkpoint was not captured, so this run cannot be reviewed or reverted."
                    }
                }
            } catch {
                guard self?.app?.checkpointReviewStates[id]?.runID == runID else { return }
                self?.app?.checkpointReviewStates[id]?.activity = .failed
                self?.app?.checkpointReviewStates[id]?.issue = self?.app?.checkpointMessage(for: error)
            }
        }
    }

    func handleSchedulerAdmissions(_ admitted: [UUID]) {
        for id in admitted {
            if taskScheduler.snapshot(for: id)?.isApprovalResume == true,
               let pending = host.pendingApprovalResponses.removeValue(forKey: id) {
                host.forwardAdmittedHarnessPermission(pending.notice, option: pending.option)
            } else {
                launchScheduledRun(for: id)
            }
        }
        refreshSchedulerLanes()
        host.persistSchedulerMetadata()
    }

    func refreshSchedulerLanes() {
        for snapshot in taskScheduler.snapshots {
            let id = snapshot.request.sessionID
            host.threadActivityLanes.apply(.priorityChanged(snapshot.request.priority), to: id)
            host.threadActivityLanes.apply(.queuePositionChanged(snapshot.queuePosition), to: id)
            switch snapshot.state {
            case .queued:
                let followUps = host.sessions.first(where: { $0.id == id })?.queuedFollowUps.count ?? 0
                if snapshot.isApprovalResume {
                    host.threadActivityLanes.apply(.approvalQueued(1 + followUps), to: id)
                } else {
                    host.threadActivityLanes.apply(.queued(1 + followUps), to: id)
                }
            case .running:
                let followUps = host.sessions.first(where: { $0.id == id })?.queuedFollowUps.count ?? 0
                host.threadActivityLanes.apply(.queued(followUps), to: id)
                host.threadActivityLanes.apply(.started, to: id)
            case .waitingForApproval:
                let followUps = host.sessions.first(where: { $0.id == id })?.queuedFollowUps.count ?? 0
                host.threadActivityLanes.apply(.queued(followUps), to: id)
                host.threadActivityLanes.apply(.approvalRequested, to: id)
            case .recoveryHeld:
                host.threadActivityLanes.apply(.failed("Interrupted work was not replayed. Review the chat and submit it again."), to: id)
            }
        }
    }

}
