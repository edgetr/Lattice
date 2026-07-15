import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    // MARK: - Run lifecycle state (owned by RunOrchestrator)

    var submittedRequests: [UUID: String] {
        get { runOrchestrator.submittedRequests }
        set { runOrchestrator.submittedRequests = newValue }
    }
    var retryableRequests: [UUID: String] {
        get { runOrchestrator.retryableRequests }
        set { runOrchestrator.retryableRequests = newValue }
    }
    var selfEditRunIDs: Set<UUID> {
        get { runOrchestrator.selfEditRunIDs }
        set { runOrchestrator.selfEditRunIDs = newValue }
    }
    var activeRunIDs: [UUID: UUID] {
        get { runOrchestrator.activeRunIDs }
        set { runOrchestrator.activeRunIDs = newValue }
    }
    var inlineImagePayloadSuppression: Set<UUID> {
        get { runOrchestrator.inlineImagePayloadSuppression }
        set { runOrchestrator.inlineImagePayloadSuppression = newValue }
    }
    var taskScheduler: AgentTaskScheduler {
        get { runOrchestrator.taskScheduler }
        set { runOrchestrator.taskScheduler = newValue }
    }
    var runUIStates: [UUID: RunUIState] {
        get { runOrchestrator.runUIStates }
        set { runOrchestrator.runUIStates = newValue }
    }
    var computerFrameAccumulators: [UUID: ComputerFrameAccumulator] {
        get { runOrchestrator.computerFrameAccumulators }
        set { runOrchestrator.computerFrameAccumulators = newValue }
    }

    // MARK: - Run lifecycle façade (owned by RunOrchestrator)

    typealias FinalizeSchedulerCompletion = RunOrchestrator.FinalizeSchedulerCompletion

    func apply(_ event: AgentEvent, to id: UUID, runID: UUID) {
        runOrchestrator.apply(event, to: id, runID: runID)
    }

    func finalizeRun(
        _ terminal: SessionRunTerminal,
        sessionID id: UUID,
        runID: UUID,
        sessionIndex index: Int,
        backend: ChatBackend,
        schedulerCompletion: FinalizeSchedulerCompletion = .finish
    ) {
        runOrchestrator.finalizeRun(
            terminal,
            sessionID: id,
            runID: runID,
            sessionIndex: index,
            backend: backend,
            schedulerCompletion: schedulerCompletion
        )
    }

    func recordWorkOutcome(
        _ outcome: SessionWorkSemantics.OutcomeKind,
        title: String,
        detail: String,
        at sessionIndex: Int
    ) {
        runOrchestrator.recordWorkOutcome(outcome, title: title, detail: detail, at: sessionIndex)
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
        runOrchestrator.updateApprovalProvenance(
            id: id,
            sessionIndex: sessionIndex,
            actor: actor,
            selectedOptionKind: selectedOptionKind,
            outcome: outcome,
            providerAcknowledgement: providerAcknowledgement
        )
    }
}
