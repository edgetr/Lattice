import Foundation

// MARK: - Captured dispatch context

/// Secret-free snapshot of the session input environment at enqueue time.
///
/// Compared field-for-field for automatic dispatch eligibility. Never stores credentials,
/// provider session IDs, unsafe-route acknowledgement choices, or transcript content.
public struct SessionInputOutboxContext: Hashable, Codable, Sendable {
    public let executionRoute: ExecutionRoute
    /// Standardized workspace path string (empty when none).
    public let workspacePath: String
    public let policy: ExecutionPolicy
    public let privacyMode: SessionPrivacyMode
    public let reasoningEffort: ReasoningEffort?
    /// Whether this workspace's instruction files were trusted when the input was queued.
    public let workspaceInstructionsTrusted: Bool
    /// Whether this route may inject its narrowly scoped provider credential at launch.
    /// This is an authority bit only; no credential value or presence detail is stored.
    public let providerCredentialInjectionEnabled: Bool
    /// Stable attachment path identities at capture time (order-independent equality).
    public let attachmentPathIdentities: [String]

    public init(
        executionRoute: ExecutionRoute,
        workspacePath: String,
        policy: ExecutionPolicy,
        privacyMode: SessionPrivacyMode,
        reasoningEffort: ReasoningEffort? = nil,
        workspaceInstructionsTrusted: Bool = false,
        providerCredentialInjectionEnabled: Bool = false,
        attachmentPathIdentities: [String] = []
    ) {
        self.executionRoute = executionRoute
        self.workspacePath = Self.standardizedPath(workspacePath)
        self.policy = policy
        self.privacyMode = privacyMode
        self.reasoningEffort = reasoningEffort
        self.workspaceInstructionsTrusted = workspaceInstructionsTrusted
        self.providerCredentialInjectionEnabled = providerCredentialInjectionEnabled
        self.attachmentPathIdentities = Self.normalizedAttachmentIdentities(attachmentPathIdentities)
    }

    private enum CodingKeys: String, CodingKey {
        case executionRoute, workspacePath, policy, privacyMode, reasoningEffort
        case workspaceInstructionsTrusted, providerCredentialInjectionEnabled, attachmentPathIdentities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            executionRoute: try container.decode(ExecutionRoute.self, forKey: .executionRoute),
            workspacePath: try container.decodeIfPresent(String.self, forKey: .workspacePath) ?? "",
            policy: try container.decode(ExecutionPolicy.self, forKey: .policy),
            privacyMode: try container.decode(SessionPrivacyMode.self, forKey: .privacyMode),
            reasoningEffort: try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort),
            workspaceInstructionsTrusted: try container.decodeIfPresent(Bool.self, forKey: .workspaceInstructionsTrusted) ?? false,
            providerCredentialInjectionEnabled: try container.decodeIfPresent(Bool.self, forKey: .providerCredentialInjectionEnabled) ?? false,
            attachmentPathIdentities: try container.decodeIfPresent([String].self, forKey: .attachmentPathIdentities) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executionRoute, forKey: .executionRoute)
        try container.encode(workspacePath, forKey: .workspacePath)
        try container.encode(policy, forKey: .policy)
        try container.encode(privacyMode, forKey: .privacyMode)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(workspaceInstructionsTrusted, forKey: .workspaceInstructionsTrusted)
        try container.encode(providerCredentialInjectionEnabled, forKey: .providerCredentialInjectionEnabled)
        try container.encode(attachmentPathIdentities, forKey: .attachmentPathIdentities)
    }

    /// Capture a context from live session fields without reading credentials or transcripts.
    public static func capture(
        executionRoute: ExecutionRoute,
        workspacePath: String?,
        policy: ExecutionPolicy,
        privacyMode: SessionPrivacyMode,
        reasoningEffort: ReasoningEffort?,
        workspaceInstructionsTrusted: Bool = false,
        providerCredentialInjectionEnabled: Bool = false,
        attachments: [ContextAttachment]
    ) -> SessionInputOutboxContext {
        SessionInputOutboxContext(
            executionRoute: executionRoute,
            workspacePath: workspacePath ?? "",
            policy: policy,
            privacyMode: privacyMode,
            reasoningEffort: reasoningEffort,
            workspaceInstructionsTrusted: workspaceInstructionsTrusted,
            providerCredentialInjectionEnabled: providerCredentialInjectionEnabled,
            attachmentPathIdentities: attachments.map(\.path)
        )
    }

    public static func standardizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Pure path normalization only — no filesystem resolution or symlink walking.
        return (trimmed as NSString).standardizingPath
    }

    private static func normalizedAttachmentIdentities(_ paths: [String]) -> [String] {
        let normalized = paths
            .map { standardizedPath($0) }
            .filter { !$0.isEmpty }
        // Stable identity set: sort so equality is order-independent.
        return Array(Set(normalized)).sorted()
    }
}

// MARK: - Lifecycle

public enum QueuedFollowUpBlockReason: String, Hashable, Codable, Sendable {
    /// Legacy entry decoded without a captured context; never auto-dispatched.
    case missingCapturedContext
    /// Captured context no longer matches the live session environment.
    case contextMismatch
    /// Process restart left pending/dispatching work that requires human review.
    case restartRecovery
    /// User or policy placed the entry under explicit review.
    case awaitingExplicitReview
}

public struct QueuedFollowUpFailureReason: Hashable, Codable, Sendable {
    public enum Code: String, Hashable, Codable, Sendable {
        case providerUnavailable
        case dispatchRejected
        case localValidationFailed
        case cancelled
        case unknown
    }

    public static let maxDetailLength = 160

    public let code: Code
    /// Optional user-facing detail. Bounded and sanitized; never store raw provider payloads.
    public let detail: String?

    public init(code: Code, detail: String? = nil) {
        self.code = code
        self.detail = detail.flatMap(Self.sanitizeDetail)
    }

    private enum CodingKeys: String, CodingKey { case code, detail }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Code.self, forKey: .code)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
            .flatMap(Self.sanitizeDetail)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    public static func sanitizeDetail(_ raw: String) -> String? {
        let strippedScalars = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(strippedScalars)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxDetailLength))
    }
}

public enum QueuedFollowUpLifecycle: Hashable, Codable, Sendable {
    case pending
    case dispatching(attemptID: UUID)
    case blocked(QueuedFollowUpBlockReason)
    case failed(QueuedFollowUpFailureReason)
}

// MARK: - Receipt ledger (local dequeue exactly-once)

/// Bounded ledger of accepted local dequeues for duplicate terminal-callback idempotence.
///
/// Models exactly-once *local dequeue* only — not provider delivery exactly-once.
public struct SessionInputOutboxReceiptLedger: Hashable, Codable, Sendable {
    public static let maxReceipts = 64

    public struct Receipt: Hashable, Codable, Sendable {
        public let entryID: UUID
        public let attemptID: UUID

        public init(entryID: UUID, attemptID: UUID) {
            self.entryID = entryID
            self.attemptID = attemptID
        }
    }

    public private(set) var receipts: [Receipt]

    public init(receipts: [Receipt] = []) {
        self.receipts = Array(receipts.suffix(Self.maxReceipts))
    }

    private enum CodingKeys: String, CodingKey { case receipts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(receipts: try container.decodeIfPresent([Receipt].self, forKey: .receipts) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(receipts, forKey: .receipts)
    }

    public func contains(entryID: UUID, attemptID: UUID) -> Bool {
        receipts.contains { $0.entryID == entryID && $0.attemptID == attemptID }
    }

    public func contains(entryID: UUID) -> Bool {
        receipts.contains { $0.entryID == entryID }
    }

    /// Record a successful local dequeue. Returns `false` when this receipt was already present.
    @discardableResult
    public mutating func record(entryID: UUID, attemptID: UUID) -> Bool {
        if contains(entryID: entryID, attemptID: attemptID) {
            return false
        }
        receipts.append(Receipt(entryID: entryID, attemptID: attemptID))
        if receipts.count > Self.maxReceipts {
            receipts.removeFirst(receipts.count - Self.maxReceipts)
        }
        return true
    }
}

// MARK: - Transition results

public enum SessionInputOutboxRejection: String, Hashable, Codable, Sendable {
    case notFound
    case notHead
    case notPending
    case missingContext
    case contextMismatch
    case notDispatching
    case attemptMismatch
    case alreadyDequeued
    case notReviewable
}

public enum SessionInputOutboxEligibility: Equatable, Sendable {
    case eligible
    case ineligible(SessionInputOutboxRejection)
}

public enum SessionInputOutboxClaimResult: Equatable, Sendable {
    case claimed(attemptID: UUID)
    /// Head is already dispatching; returns the durable attempt id (duplicate-safe).
    case alreadyClaimed(attemptID: UUID)
    case rejected(SessionInputOutboxRejection)
}

public enum SessionInputOutboxDequeueResult: Equatable, Sendable {
    case dequeued
    case alreadyDequeued
    case rejected(SessionInputOutboxRejection)
}

public enum SessionInputOutboxMutationResult: Equatable, Sendable {
    case applied
    case rejected(SessionInputOutboxRejection)
}

// MARK: - Pure transition policy

/// Pure FIFO outbox policy for queued session inputs.
///
/// Guarantees exactly-once *local dequeue* via attempt ids + a bounded receipt ledger.
/// Does **not** claim provider-delivery exactly-once.
public enum SessionInputOutboxPolicy: Sendable {
    /// Append a pending entry that captured the current dispatch context.
    @discardableResult
    public static func enqueue(
        text: String,
        context: SessionInputOutboxContext,
        into entries: inout [QueuedFollowUp],
        id: UUID = UUID(),
        date: Date = .now
    ) -> QueuedFollowUp {
        let entry = QueuedFollowUp(
            id: id,
            text: text,
            date: date,
            context: context,
            lifecycle: .pending
        )
        entries.append(entry)
        return entry
    }

    /// Automatic dispatch eligibility. Only the FIFO head may advance, and only when pending
    /// with a context that exactly matches the live environment. A failed/blocked head blocks
    /// all automatic advancement.
    public static func automaticDispatchEligibility(
        of entryID: UUID,
        currentContext: SessionInputOutboxContext,
        in entries: [QueuedFollowUp]
    ) -> SessionInputOutboxEligibility {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return .ineligible(.notFound)
        }
        guard index == 0 else {
            return .ineligible(.notHead)
        }
        return headEligibility(entries[0], currentContext: currentContext)
    }

    /// Eligibility of the current FIFO head for automatic dispatch.
    public static func headAutomaticDispatchEligibility(
        in entries: [QueuedFollowUp],
        currentContext: SessionInputOutboxContext
    ) -> SessionInputOutboxEligibility {
        guard let head = entries.first else {
            return .ineligible(.notFound)
        }
        return headEligibility(head, currentContext: currentContext)
    }

    /// Durable claim of the FIFO head for dispatch. Assigns an attempt UUID while leaving the
    /// entry in the queue until local dequeue completion.
    public static func claimDispatch(
        entryID: UUID,
        currentContext: SessionInputOutboxContext,
        in entries: inout [QueuedFollowUp],
        attemptID: UUID = UUID()
    ) -> SessionInputOutboxClaimResult {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return .rejected(.notFound)
        }
        guard index == 0 else {
            return .rejected(.notHead)
        }

        // Context absence is checked before lifecycle so legacy entries surface a precise reason.
        guard let captured = entries[index].context else {
            return .rejected(.missingContext)
        }

        switch entries[index].lifecycle {
        case .dispatching(let existing):
            return .alreadyClaimed(attemptID: existing)
        case .pending:
            break
        case .blocked, .failed:
            return .rejected(.notPending)
        }

        guard captured == currentContext else {
            return .rejected(.contextMismatch)
        }

        entries[index].lifecycle = .dispatching(attemptID: attemptID)
        return .claimed(attemptID: attemptID)
    }

    /// Complete local dequeue exactly once. Duplicate terminal callbacks with the same
    /// entry/attempt receipt are idempotent successes.
    public static func completeLocalDequeue(
        entryID: UUID,
        attemptID: UUID,
        in entries: inout [QueuedFollowUp],
        ledger: inout SessionInputOutboxReceiptLedger
    ) -> SessionInputOutboxDequeueResult {
        if ledger.contains(entryID: entryID, attemptID: attemptID) {
            // Ensure the entry is not still present after a prior successful dequeue.
            if let index = entries.firstIndex(where: { $0.id == entryID }) {
                entries.remove(at: index)
            }
            return .alreadyDequeued
        }

        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return .rejected(.notFound)
        }

        switch entries[index].lifecycle {
        case .dispatching(let claimed):
            guard claimed == attemptID else {
                return .rejected(.attemptMismatch)
            }
        default:
            return .rejected(.notDispatching)
        }

        entries.remove(at: index)
        ledger.record(entryID: entryID, attemptID: attemptID)
        return .dequeued
    }

    /// Record a typed failure for a claimed dispatch attempt. Keeps the entry as FIFO head so
    /// automatic advancement remains blocked until explicit review.
    public static func recordFailure(
        entryID: UUID,
        attemptID: UUID,
        reason: QueuedFollowUpFailureReason,
        in entries: inout [QueuedFollowUp]
    ) -> SessionInputOutboxMutationResult {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return .rejected(.notFound)
        }

        switch entries[index].lifecycle {
        case .dispatching(let claimed):
            guard claimed == attemptID else {
                return .rejected(.attemptMismatch)
            }
            entries[index].lifecycle = .failed(reason)
            return .applied
        case .failed(let existing) where existing == reason:
            return .applied
        case .failed:
            return .rejected(.notDispatching)
        default:
            return .rejected(.notDispatching)
        }
    }

    /// Explicit user review/retry: re-arm a blocked or failed entry with the live context.
    public static func acceptExplicitReview(
        entryID: UUID,
        currentContext: SessionInputOutboxContext,
        in entries: inout [QueuedFollowUp]
    ) -> SessionInputOutboxMutationResult {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return .rejected(.notFound)
        }

        switch entries[index].lifecycle {
        case .blocked, .failed:
            break
        case .pending, .dispatching:
            return .rejected(.notReviewable)
        }

        entries[index].context = currentContext
        entries[index].lifecycle = .pending
        return .applied
    }

    /// Restart recovery: pending and dispatching entries require explicit review before any
    /// automatic dispatch. Failed/blocked entries are left unchanged (still non-auto).
    public static func recoverAfterRestart(_ entries: inout [QueuedFollowUp]) {
        for index in entries.indices {
            if entries[index].context == nil {
                entries[index].lifecycle = .blocked(.missingCapturedContext)
                continue
            }
            switch entries[index].lifecycle {
            case .pending, .dispatching:
                entries[index].lifecycle = .blocked(.restartRecovery)
            case .blocked, .failed:
                continue
            }
        }
    }

    // MARK: Private

    private static func headEligibility(
        _ entry: QueuedFollowUp,
        currentContext: SessionInputOutboxContext
    ) -> SessionInputOutboxEligibility {
        guard let captured = entry.context else {
            return .ineligible(.missingContext)
        }

        switch entry.lifecycle {
        case .pending:
            break
        case .dispatching:
            return .ineligible(.notPending)
        case .blocked, .failed:
            // FIFO head failure/block prevents automatic advancement of later entries.
            return .ineligible(.notPending)
        }

        guard captured == currentContext else {
            return .ineligible(.contextMismatch)
        }
        return .eligible
    }
}
