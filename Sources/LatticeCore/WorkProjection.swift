import Foundation

/// Pure Work-mode projection over the durable `SessionAction` timeline.
/// Does not parse assistant prose or arbitrary tool detail into structure.
public enum WorkProjection {
    public enum Depth: String, Hashable, Sendable {
        /// Work mode: one actionable request plus a compact chronological log.
        case rich
        /// Code mode: intentionally concise; no Work expansion.
        case concise
        /// Local mode: not expanded.
        case collapsed
    }

    public enum ActionableKind: String, Hashable, Codable, Sendable, Comparable {
        case liveApproval
        case liveQuestion
        case userTaskConfirmation
        case retryableFailure
        case artifactOperation

        public static func < (lhs: ActionableKind, rhs: ActionableKind) -> Bool {
            lhs.rank < rhs.rank
        }

        var rank: Int {
            switch self {
            case .liveApproval: 0
            case .liveQuestion: 1
            case .userTaskConfirmation: 2
            case .retryableFailure: 3
            case .artifactOperation: 4
            }
        }
    }

    public struct ActionableRequest: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let kind: ActionableKind
        public let originMessageID: UUID
        public let originActionID: UUID
        /// True only for user-owned task steps (mark/confirm mutation surface).
        public let allowsMarkConfirm: Bool
        /// Present only for explicit artifact rows; never inferred from `action.detail`.
        public let artifactLocator: String?

        public init(
            id: UUID,
            kind: ActionableKind,
            originMessageID: UUID,
            originActionID: UUID,
            allowsMarkConfirm: Bool,
            artifactLocator: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.originMessageID = originMessageID
            self.originActionID = originActionID
            self.allowsMarkConfirm = allowsMarkConfirm
            self.artifactLocator = artifactLocator
        }
    }

    public struct LogEntry: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let actionID: UUID
        public let originMessageID: UUID
        public let originActionID: UUID
        public let workKind: SessionWorkSemantics.Kind?
        public let status: SessionAction.Status
        public let createdAt: Date
        public let updatedAt: Date
        /// Present only when the durable row carried an explicit artifact locator.
        public let artifactLocator: String?

        public init(
            id: UUID,
            actionID: UUID,
            originMessageID: UUID,
            originActionID: UUID,
            workKind: SessionWorkSemantics.Kind?,
            status: SessionAction.Status,
            createdAt: Date,
            updatedAt: Date,
            artifactLocator: String? = nil
        ) {
            self.id = id
            self.actionID = actionID
            self.originMessageID = originMessageID
            self.originActionID = originActionID
            self.workKind = workKind
            self.status = status
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.artifactLocator = artifactLocator
        }
    }

    public struct Snapshot: Hashable, Sendable {
        public let mode: ConversationMode
        public let depth: Depth
        /// At most one currently actionable request.
        public let actionable: ActionableRequest?
        public let log: [LogEntry]

        public var isRich: Bool { depth == .rich }

        public init(
            mode: ConversationMode,
            depth: Depth,
            actionable: ActionableRequest?,
            log: [LogEntry]
        ) {
            self.mode = mode
            self.depth = depth
            self.actionable = actionable
            self.log = log
        }
    }

    public static func depth(for mode: ConversationMode) -> Depth {
        switch mode {
        case .work: .rich
        case .code: .concise
        case .local: .collapsed
        }
    }

    /// Projects Work UI state from durable actions plus live provider-bound IDs.
    /// Restored sessions must pass empty live ID sets so approvals/questions stay non-actionable.
    public static func project(
        mode: ConversationMode,
        actions: [SessionAction],
        liveApprovalIDs: Set<UUID> = [],
        liveQuestionIDs: Set<UUID> = [],
        retryableActionIDs: Set<UUID> = [],
        logLimit: Int = 24
    ) -> Snapshot {
        let depth = depth(for: mode)
        guard depth == .rich else {
            return Snapshot(mode: mode, depth: depth, actionable: nil, log: [])
        }

        let boundedLimit = max(0, min(logLimit, 200))
        let ordered = actions.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let log: [LogEntry] = ordered.compactMap { action in
            guard isWorkLogCandidate(action) else { return nil }
            let origins = originIDs(for: action)
            return LogEntry(
                id: action.id,
                actionID: action.id,
                originMessageID: origins.messageID,
                originActionID: origins.actionID,
                workKind: workKind(for: action),
                status: action.status,
                createdAt: action.createdAt,
                updatedAt: action.updatedAt,
                artifactLocator: explicitArtifactLocator(for: action)
            )
        }
        let compactLog = Array(log.suffix(boundedLimit))

        let candidates = ordered.compactMap { action -> ActionableRequest? in
            candidate(
                for: action,
                liveApprovalIDs: liveApprovalIDs,
                liveQuestionIDs: liveQuestionIDs,
                retryableActionIDs: retryableActionIDs
            )
        }
        let actionable = candidates.min { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            // Stable tie-break: oldest first within the same rank bucket.
            guard let left = ordered.first(where: { $0.id == lhs.id }),
                  let right = ordered.first(where: { $0.id == rhs.id }) else {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return left.id.uuidString < right.id.uuidString
        }

        return Snapshot(
            mode: mode,
            depth: depth,
            actionable: actionable,
            log: compactLog.filter { $0.id != actionable?.id }
        )
    }

    /// Mark/confirm is allowed only for user-owned task steps.
    public static func canMarkOrConfirm(_ action: SessionAction) -> Bool {
        guard let work = action.work else { return false }
        return work.kind == .taskStep && work.ownership == .userOwned
    }

    /// Returns an updated action when mark/confirm is legal; otherwise `nil`.
    public static func applyingTaskMark(
        _ mark: SessionWorkSemantics.TaskMark,
        to action: SessionAction,
        at date: Date = .now
    ) -> SessionAction? {
        guard canMarkOrConfirm(action), var work = action.work else { return nil }
        work.taskMark = mark
        var updated = action
        updated.work = work
        updated.updatedAt = date
        switch mark {
        case .checked, .confirmed:
            if updated.status == .waiting || updated.status == .running {
                updated.status = .completed
            }
        case .unchecked:
            break
        }
        return updated
    }

    public static func canAnswer(_ action: SessionAction) -> Bool {
        action.work?.kind == .question
            && action.work?.ownership == .userOwned
            && action.work?.resolutionMessageID == nil
            && action.status == .waiting
    }

    /// Links a durable user answer exactly once. Provider-bound questions require their
    /// live protocol callback and are intentionally not resolved by this local transition.
    public static func applyingAnswer(
        messageID: UUID,
        to action: SessionAction,
        at date: Date = .now
    ) -> SessionAction? {
        guard canAnswer(action), var work = action.work else { return nil }
        work.resolutionMessageID = messageID
        var updated = action
        updated.work = work
        updated.status = .completed
        updated.updatedAt = date
        return updated
    }

    // MARK: - Private ranking

    private static func candidate(
        for action: SessionAction,
        liveApprovalIDs: Set<UUID>,
        liveQuestionIDs: Set<UUID>,
        retryableActionIDs: Set<UUID>
    ) -> ActionableRequest? {
        let origins = originIDs(for: action)
        let work = action.work

        // 1. Live approval — provider-bound and only with an explicit live runtime ID.
        if isApprovalRow(action),
           action.status == .waiting,
           liveApprovalIDs.contains(action.id) {
            return ActionableRequest(
                id: action.id,
                kind: .liveApproval,
                originMessageID: origins.messageID,
                originActionID: origins.actionID,
                allowsMarkConfirm: false
            )
        }

        // 2. Live unanswered question — requires typed work semantics + live ID.
        if work?.kind == .question,
           action.status == .waiting,
           (liveQuestionIDs.contains(action.id) || work?.ownership == .userOwned) {
            return ActionableRequest(
                id: action.id,
                kind: .liveQuestion,
                originMessageID: origins.messageID,
                originActionID: origins.actionID,
                allowsMarkConfirm: false
            )
        }

        // 3. User-owned task confirmation.
        if work?.kind == .taskStep,
           work?.ownership == .userOwned,
           needsUserTaskConfirmation(action) {
            return ActionableRequest(
                id: action.id,
                kind: .userTaskConfirmation,
                originMessageID: origins.messageID,
                originActionID: origins.actionID,
                allowsMarkConfirm: true
            )
        }

        // 4. Retryable failure (typed work rows only — never invent from free-form detail).
        if action.status == .failed, work != nil, retryableActionIDs.contains(action.id) {
            return ActionableRequest(
                id: action.id,
                kind: .retryableFailure,
                originMessageID: origins.messageID,
                originActionID: origins.actionID,
                allowsMarkConfirm: canMarkOrConfirm(action)
            )
        }

        // 5. Explicit artifact open/reveal candidates.
        if work?.kind == .artifact,
           let locator = work?.artifactLocator,
           !locator.isEmpty,
           action.status == .completed || action.status == .failed {
            return ActionableRequest(
                id: action.id,
                kind: .artifactOperation,
                originMessageID: origins.messageID,
                originActionID: origins.actionID,
                allowsMarkConfirm: false,
                artifactLocator: locator
            )
        }

        return nil
    }

    private static func needsUserTaskConfirmation(_ action: SessionAction) -> Bool {
        guard let work = action.work, work.kind == .taskStep, work.ownership == .userOwned else {
            return false
        }
        switch work.taskMark {
        case .some(.checked), .some(.confirmed):
            return false
        case .none, .some(.unchecked):
            break
        }
        return action.status == .waiting
    }

    private static func isApprovalRow(_ action: SessionAction) -> Bool {
        if action.work?.kind == .approval { return true }
        return action.kind == .approval
    }

    private static func isWorkLogCandidate(_ action: SessionAction) -> Bool {
        if action.work != nil { return true }
        // Durable approvals remain visible in the Work log even without a payload so restore
        // evidence is not dropped; they still require live IDs to become actionable.
        return action.kind == .approval || action.kind == .plan
    }

    private static func workKind(for action: SessionAction) -> SessionWorkSemantics.Kind? {
        if let kind = action.work?.kind { return kind }
        switch action.kind {
        case .approval: return .approval
        case .plan: return .planStep
        default: return nil
        }
    }

    private static func explicitArtifactLocator(for action: SessionAction) -> String? {
        guard action.work?.kind == .artifact else { return nil }
        return action.work?.artifactLocator
    }

    private static func originIDs(for action: SessionAction) -> (messageID: UUID, actionID: UUID) {
        let messageID = action.work?.originMessageID ?? action.messageID
        let actionID = action.work?.originActionID ?? action.id
        return (messageID, actionID)
    }
}

// MARK: - Restore reconciliation

/// Reconciles provider-dependent live action state after durable restore.
/// Never reconstructs a stale provider permission callback from persisted data.
public enum WorkRuntimeReconciliation {
    /// Maps provider-dependent running/waiting rows to `.interrupted` while preserving
    /// pending user-owned tasks and terminal artifacts/outcomes.
    public static func reconcile(
        _ actions: [SessionAction],
        at date: Date = .now
    ) -> [SessionAction] {
        actions.map { action in
            var restored = action
            guard [.running, .waiting].contains(restored.status) else { return restored }

            if let work = restored.work {
                if work.isPendingUserOwnedTask {
                    // Keep durable user-owned pending tasks awaiting mark/confirm.
                    return restored
                }
                if work.kind == .artifact || work.kind == .outcome {
                    // Terminal deliverables/outcomes are not live provider waits.
                    // If a non-terminal status slipped through, still fail closed.
                    restored.status = .interrupted
                    restored.updatedAt = date
                    return restored
                }
                if work.isProviderDependentLiveState {
                    restored.status = .interrupted
                    restored.updatedAt = date
                    return restored
                }
            }

            // Legacy / untyped running or waiting state is always provider-dependent.
            restored.status = .interrupted
            restored.updatedAt = date
            return restored
        }
    }

    public static func reconcileSession(
        _ session: LatticeSession,
        at date: Date = .now
    ) -> LatticeSession {
        var restored = session
        restored.isStreaming = false
        restored.actions = reconcile(session.actions, at: date)
        return restored
    }
}

public struct WorkItemPresentation: Equatable, Sendable {
    public let heading: String
    public let status: String
    public let primaryAction: String
    public let secondaryAction: String?
    public let accessibilityLabel: String
    public let accessibilityHint: String
}

/// Text-first Work UI copy. Status is always announced in words; color and icons are supplemental.
public enum WorkItemPresentationPolicy {
    public static func presentation(
        for request: WorkProjection.ActionableRequest,
        action: SessionAction
    ) -> WorkItemPresentation {
        let heading: String
        let status: String
        let primary: String
        let secondary: String?
        let hint: String
        switch request.kind {
        case .liveApproval:
            heading = "Approval required"
            status = "Waiting for your decision"
            primary = "Review approval"
            secondary = "Jump to originating message"
            hint = "Choose a visible approval option to resume the provider."
        case .liveQuestion:
            heading = "Answer needed"
            status = "Waiting for your answer"
            primary = "Send answer"
            secondary = "Jump to originating message"
            hint = "Enter an answer, then send it to continue the work."
        case .userTaskConfirmation:
            heading = "Confirmation needed"
            status = "Waiting for your confirmation"
            primary = "Confirm task"
            secondary = "Jump to originating message"
            hint = "Confirm only this user-owned task step."
        case .retryableFailure:
            heading = "Task failed"
            status = "Needs attention"
            primary = "Retry turn"
            secondary = "Jump to originating message"
            hint = "Start a fresh turn from the originating user request."
        case .artifactOperation:
            heading = "Artifact ready"
            status = "Available"
            primary = "Open artifact"
            secondary = "Reveal in Finder"
            hint = "Open a safe workspace document or reveal the artifact in Finder."
        }
        return WorkItemPresentation(
            heading: heading,
            status: status,
            primaryAction: primary,
            secondaryAction: secondary,
            accessibilityLabel: "\(heading), \(action.title), \(status)",
            accessibilityHint: hint
        )
    }

    public static func statusLabel(for status: SessionAction.Status) -> String {
        switch status {
        case .running: "In progress"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .allowed: "Approved"
        case .denied: "Denied"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }
}

public enum WorkDockLayoutPolicy {
    public enum ActionLayout: Equatable, Sendable { case horizontal, stacked }

    public static func actionLayout(forAvailableWidth width: Double) -> ActionLayout {
        width > 0 && width < 520 ? .stacked : .horizontal
    }
}

/// Pure path policy for explicit artifacts. It never interprets free-form action details.
public enum WorkArtifactAccessPolicy {
    private static let safeDocumentExtensions: Set<String> = [
        "txt", "md", "markdown", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic",
        "json", "csv", "tsv", "xml", "yaml", "yml", "html", "htm", "rtf", "doc", "docx",
        "xls", "xlsx", "ppt", "pptx", "swift", "kt", "java", "js", "ts", "css"
    ]

    public static func resolvedFileURL(locator: String, workspace: URL) -> URL? {
        let trimmed = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            guard parsed.isFileURL else { return nil }
            return parsed.standardizedFileURL
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return workspace.appendingPathComponent(trimmed).standardizedFileURL
    }

    public static func canOpen(locator: String, workspace: URL) -> Bool {
        guard let url = resolvedFileURL(locator: locator, workspace: workspace),
              WorkspacePathScope.isWorkspaceScoped(url.path, workspace: workspace) else { return false }
        return safeDocumentExtensions.contains(url.pathExtension.lowercased())
    }
}
