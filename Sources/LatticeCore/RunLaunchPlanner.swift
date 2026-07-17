import Foundation

/// Pure planning inputs for a scheduled provider run.
public struct RunLaunchPlanRequest: Equatable, Sendable {
    public let session: LatticeSession
    public let submittedText: String
    public let additionalContext: String
    public let tokenLimit: Int
    public let effectiveRuntimeID: String

    public init(
        session: LatticeSession,
        submittedText: String,
        additionalContext: String,
        tokenLimit: Int,
        effectiveRuntimeID: String
    ) {
        self.session = session
        self.submittedText = submittedText
        self.additionalContext = additionalContext
        self.tokenLimit = tokenLimit
        self.effectiveRuntimeID = effectiveRuntimeID
    }
}

public struct RunLaunchPlan: Equatable, Sendable {
    public let prompt: String
    public let routeThreadID: String?
    public let resetsHarnessSession: Bool
    public let statusDetail: String?
    public let didCompact: Bool
    public let deliveryIssue: String?
    public let recoveryPrompt: String?
    public let recoveryUsesVisibleTranscriptHandoff: Bool
    public let recoveryDeliveryIssue: String?
    public let usesPromptDrivenBackend: Bool

    public init(
        prompt: String,
        routeThreadID: String?,
        resetsHarnessSession: Bool,
        statusDetail: String?,
        didCompact: Bool,
        deliveryIssue: String?,
        recoveryPrompt: String?,
        recoveryUsesVisibleTranscriptHandoff: Bool,
        recoveryDeliveryIssue: String?,
        usesPromptDrivenBackend: Bool
    ) {
        self.prompt = prompt
        self.routeThreadID = routeThreadID
        self.resetsHarnessSession = resetsHarnessSession
        self.statusDetail = statusDetail
        self.didCompact = didCompact
        self.deliveryIssue = deliveryIssue
        self.recoveryPrompt = recoveryPrompt
        self.recoveryUsesVisibleTranscriptHandoff = recoveryUsesVisibleTranscriptHandoff
        self.recoveryDeliveryIssue = recoveryDeliveryIssue
        self.usesPromptDrivenBackend = usesPromptDrivenBackend
    }
}

/// One-shot session state that may be consumed only after every launch gate
/// (including credential admission) has succeeded.
public struct RunLaunchOneShotState: Equatable, Sendable {
    public var harnessThreadID: String?
    public var compactContextOnNextSend: Bool

    public init(harnessThreadID: String?, compactContextOnNextSend: Bool) {
        self.harnessThreadID = harnessThreadID
        self.compactContextOnNextSend = compactContextOnNextSend
    }
}

public enum RunLaunchCommitAdmission: Equatable, Sendable {
    case admitted
    case blocked
}

public enum RunLaunchCommitPolicy {
    /// A blocked launch is a no-op. This keeps retries on the existing provider
    /// thread and preserves a requested compact until a provider can start.
    public static func applying(
        _ plan: RunLaunchPlan,
        admission: RunLaunchCommitAdmission,
        to state: RunLaunchOneShotState
    ) -> RunLaunchOneShotState {
        guard admission == .admitted else { return state }
        var committed = state
        if plan.resetsHarnessSession {
            committed.harnessThreadID = nil
        }
        if committed.compactContextOnNextSend {
            committed.compactContextOnNextSend = false
        }
        return committed
    }
}

/// Pure plan → gateway prep. Secrets and process launch stay outside this type.
public enum RunLaunchPlanner {
    public static func usesPromptDrivenBackend(runtimeID: String, backend: ChatBackend) -> Bool {
        if runtimeID == "pi" || runtimeID == "hermes" { return true }
        switch backend {
        case .codex, .grok, .openCode:
            return true
        case .appleIntelligence, .ollama, .antigravity:
            return false
        }
    }

    public static func plan(_ request: RunLaunchPlanRequest) -> RunLaunchPlan {
        let usesPromptDriven = usesPromptDrivenBackend(
            runtimeID: request.effectiveRuntimeID,
            backend: request.session.backend
        )
        let forceCompact = request.session.compactContextOnNextSend
        // Force compact: rebuild a visible handoff and compact aggressively (threshold 0).
        let existingThread: String? = {
            if forceCompact { return nil }
            return usesPromptDriven ? request.session.harnessThreadID : "structured-message-list"
        }()
        let management: LatticeContextManagementMode = forceCompact
            ? .providerManagedSession
            : (usesPromptDriven ? .providerManagedSession : .latticeManagedVisibleTranscript)
        let contextPlan = LatticeContextHandoffPlanner.plan(
            session: request.session,
            submittedText: request.submittedText,
            additionalContext: request.additionalContext,
            tokenLimit: request.tokenLimit,
            existingHarnessThreadID: existingThread,
            managementMode: management,
            compactionThreshold: forceCompact ? 0 : LatticeContextHandoffPlanner.defaultCompactionThreshold
        )
        let supportsACPRecovery = ["grok", "opencode", "hermes"].contains(request.effectiveRuntimeID)
        let hasPersistedACPSession = supportsACPRecovery && request.session.harnessThreadID != nil
        let recoveryPlan = hasPersistedACPSession
            ? LatticeContextHandoffPlanner.plan(
                session: request.session,
                submittedText: request.submittedText,
                additionalContext: request.additionalContext,
                tokenLimit: request.tokenLimit,
                existingHarnessThreadID: nil,
                managementMode: .providerManagedSession
            )
            : contextPlan

        let statusDetail: String? = {
            if forceCompact {
                return contextPlan.statusDetail
                    ?? "Compacted visible transcript for the next send as requested."
            }
            return contextPlan.statusDetail
        }()

        return RunLaunchPlan(
            prompt: contextPlan.prompt,
            routeThreadID: contextPlan.resetsHarnessSession ? nil : request.session.harnessThreadID,
            resetsHarnessSession: contextPlan.resetsHarnessSession || forceCompact,
            statusDetail: statusDetail,
            didCompact: contextPlan.didCompact || forceCompact,
            deliveryIssue: contextPlan.deliveryIssue,
            recoveryPrompt: hasPersistedACPSession ? recoveryPlan.prompt : nil,
            recoveryUsesVisibleTranscriptHandoff: hasPersistedACPSession && recoveryPlan.usesVisibleTranscriptHandoff,
            recoveryDeliveryIssue: hasPersistedACPSession ? recoveryPlan.deliveryIssue : nil,
            usesPromptDrivenBackend: usesPromptDriven
        )
    }
}

/// Provider launch write authority. Pi/OpenCode use the typed
/// `allowFileModification` field; Codex app-server additionally receives a
/// workspace-write bit. Only an explicitly marked Pi fallback may enable that
/// bit for a new route. Legacy direct routes stay read-only here.
public enum CodeWorkspaceWritePolicy {
    public static func codexWorkspaceWrite(
        route: ExecutionRoute,
        allowFileModification: Bool,
        isSelfEdit: Bool,
        selfEditWorkspaceWrite: Bool
    ) -> Bool {
        if isSelfEdit { return selfEditWorkspaceWrite }
        return route.mode == .code
            && route.providerID == "codex"
            && route.runtimeID == "codex"
            && route.fallbackFromRuntimeID == "pi"
            && allowFileModification
    }
}
