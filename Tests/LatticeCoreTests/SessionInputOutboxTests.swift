import Foundation
import Testing
@testable import LatticeCore

@Suite("Session input outbox")
struct SessionInputOutboxTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let secretSentinel = "sk-outbox-secret-sentinel-do-not-persist"

    private func route(
        mode: ConversationMode = .code,
        providerID: String = "codex",
        modelID: String? = "gpt-5.4",
        runtimeID: String = "codex"
    ) -> ExecutionRoute {
        ExecutionRoute(mode: mode, providerID: providerID, modelID: modelID, runtimeID: runtimeID)
    }

    private func context(
        route: ExecutionRoute? = nil,
        workspacePath: String = "/Users/dev/project",
        policy: ExecutionPolicy = .ask,
        privacyMode: SessionPrivacyMode = .cloudAllowed,
        reasoningEffort: ReasoningEffort? = .medium,
        workspaceInstructionsTrusted: Bool = false,
        providerCredentialInjectionEnabled: Bool = false,
        attachmentPaths: [String] = ["/Users/dev/project/a.swift"]
    ) -> SessionInputOutboxContext {
        SessionInputOutboxContext(
            executionRoute: route ?? self.route(),
            workspacePath: workspacePath,
            policy: policy,
            privacyMode: privacyMode,
            reasoningEffort: reasoningEffort,
            workspaceInstructionsTrusted: workspaceInstructionsTrusted,
            providerCredentialInjectionEnabled: providerCredentialInjectionEnabled,
            attachmentPathIdentities: attachmentPaths
        )
    }

    // MARK: - Legacy migration

    @Test func legacyIDTextDateJSONDecodesAndRequiresExplicitReview() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let legacyJSON = """
        {"id":"\(id.uuidString)","text":"Follow up later","date":\(jsonDate(fixedDate))}
        """
        let decoded = try JSONDecoder().decode(QueuedFollowUp.self, from: Data(legacyJSON.utf8))
        #expect(decoded.id == id)
        #expect(decoded.text == "Follow up later")
        #expect(decoded.context == nil)
        #expect(decoded.lifecycle == .blocked(.missingCapturedContext))

        var entries = [decoded]
        let live = context()
        #expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: decoded.id,
                currentContext: live,
                in: entries
            ) == .ineligible(.missingContext)
        )
        #expect(
            SessionInputOutboxPolicy.claimDispatch(
                entryID: decoded.id,
                currentContext: live,
                in: &entries
            ) == .rejected(.missingContext)
        )
    }

    @Test func legacyInitWithoutContextNeverAutoDispatches() {
        let entry = QueuedFollowUp(text: "old style queue item", date: fixedDate)
        #expect(entry.context == nil)
        #expect(entry.lifecycle == .blocked(.missingCapturedContext))
        #expect(
            SessionInputOutboxPolicy.headAutomaticDispatchEligibility(
                in: [entry],
                currentContext: context()
            ) == .ineligible(.missingContext)
        )
    }

    @Test func decodedLifecycleWithoutContextIsForcedToMissingContextBlock() throws {
        let id = UUID()
        // Explicit lifecycle override can construct a non-review state in memory, but decoding
        // must still force review whenever captured context is absent.
        let encoded = try JSONEncoder().encode(
            QueuedFollowUp(id: id, text: "x", date: fixedDate, context: nil, lifecycle: .pending)
        )
        let forced = try JSONDecoder().decode(QueuedFollowUp.self, from: encoded)
        #expect(forced.context == nil)
        #expect(forced.lifecycle == .blocked(.missingCapturedContext))
    }

    // MARK: - Context equality / mismatch per field

    @Test func contextEqualityRequiresEveryCapturedField() {
        let base = context()
        #expect(base == context())

        #expect(base != context(route: route(providerID: "grok", modelID: "grok-4", runtimeID: "grok")))
        #expect(base != context(workspacePath: "/Users/dev/other"))
        #expect(base != context(policy: .yolo))
        #expect(base != context(privacyMode: .localOnly))
        #expect(base != context(reasoningEffort: .high))
        #expect(base != context(reasoningEffort: nil))
        #expect(base != context(workspaceInstructionsTrusted: true))
        #expect(base != context(providerCredentialInjectionEnabled: true))
        #expect(base != context(attachmentPaths: ["/Users/dev/project/b.swift"]))
        #expect(base != context(attachmentPaths: []))
        #expect(base != context(attachmentPaths: [
            "/Users/dev/project/a.swift",
            "/Users/dev/project/b.swift"
        ]))
    }

    @Test func contextAttachmentIdentitiesAreOrderIndependentAndPathStandardized() {
        let left = context(attachmentPaths: [
            "/Users/dev/project/./a.swift",
            "/Users/dev/project/b.swift"
        ])
        let right = context(attachmentPaths: [
            "/Users/dev/project/b.swift",
            "/Users/dev/project/a.swift"
        ])
        #expect(left == right)
        #expect(left.attachmentPathIdentities == [
            SessionInputOutboxContext.standardizedPath("/Users/dev/project/a.swift"),
            SessionInputOutboxContext.standardizedPath("/Users/dev/project/b.swift")
        ])
    }

    @Test func eligibilityRejectsMismatchForEveryCapturedField() {
        var entries: [QueuedFollowUp] = []
        let captured = context()
        let entry = SessionInputOutboxPolicy.enqueue(
            text: "next",
            context: captured,
            into: &entries,
            id: UUID(),
            date: fixedDate
        )

        let mismatches: [SessionInputOutboxContext] = [
            context(route: route(modelID: "other-model")),
            context(workspacePath: "/tmp/elsewhere"),
            context(policy: .smart),
            context(privacyMode: .localOnly),
            context(reasoningEffort: .low),
            context(workspaceInstructionsTrusted: true),
            context(providerCredentialInjectionEnabled: true),
            context(attachmentPaths: ["/tmp/only.swift"])
        ]

        for live in mismatches {
            #expect(
                SessionInputOutboxPolicy.automaticDispatchEligibility(
                    of: entry.id,
                    currentContext: live,
                    in: entries
                ) == .ineligible(.contextMismatch)
            )
            var claimEntries = entries
            #expect(
                SessionInputOutboxPolicy.claimDispatch(
                    entryID: entry.id,
                    currentContext: live,
                    in: &claimEntries
                ) == .rejected(.contextMismatch)
            )
        }

        #expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: entry.id,
                currentContext: captured,
                in: entries
            ) == .eligible
        )
    }

    @Test func decodedFailureDetailIsSanitizedAndBounded() throws {
        let hostileDetail = "provider\u{0000}\n\t" + String(repeating: "x", count: 300)
        let encoded = try JSONEncoder().encode(
            QueuedFollowUpFailureReason(code: .providerUnavailable, detail: hostileDetail)
        )
        let decoded = try JSONDecoder().decode(QueuedFollowUpFailureReason.self, from: encoded)
        #expect(decoded.detail?.contains("\n") == false)
        #expect(decoded.detail?.contains("\t") == false)
        #expect((decoded.detail?.count ?? 0) <= QueuedFollowUpFailureReason.maxDetailLength)
    }

    @Test func contextDecodeMigratesOlderAuthorityShape() throws {
        let encoded = try JSONEncoder().encode(context())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["providerCredentialInjectionEnabled"] = nil
        let migrated = try JSONDecoder().decode(
            SessionInputOutboxContext.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(migrated.providerCredentialInjectionEnabled == false)
    }

    // MARK: - Enqueue / claim / dequeue / failure / review

    @Test func enqueueCaptureClaimAndLocalDequeueAreFIFOAndIdempotent() {
        var entries: [QueuedFollowUp] = []
        var ledger = SessionInputOutboxReceiptLedger()
        let live = context()
        let firstID = UUID()
        let secondID = UUID()
        let attempt = UUID()

        SessionInputOutboxPolicy.enqueue(
            text: "first",
            context: live,
            into: &entries,
            id: firstID,
            date: fixedDate
        )
        SessionInputOutboxPolicy.enqueue(
            text: "second",
            context: live,
            into: &entries,
            id: secondID,
            date: fixedDate.addingTimeInterval(1)
        )

        #expect(entries.map(\.id) == [firstID, secondID])
        #expect(entries[0].lifecycle == .pending)
        #expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: secondID,
                currentContext: live,
                in: entries
            ) == .ineligible(.notHead)
        )

        let claim = SessionInputOutboxPolicy.claimDispatch(
            entryID: firstID,
            currentContext: live,
            in: &entries,
            attemptID: attempt
        )
        #expect(claim == .claimed(attemptID: attempt))
        #expect(entries[0].lifecycle == .dispatching(attemptID: attempt))

        let duplicateClaim = SessionInputOutboxPolicy.claimDispatch(
            entryID: firstID,
            currentContext: live,
            in: &entries,
            attemptID: UUID()
        )
        #expect(duplicateClaim == .alreadyClaimed(attemptID: attempt))

        #expect(
            SessionInputOutboxPolicy.completeLocalDequeue(
                entryID: firstID,
                attemptID: UUID(),
                in: &entries,
                ledger: &ledger
            ) == .rejected(.attemptMismatch)
        )

        #expect(
            SessionInputOutboxPolicy.completeLocalDequeue(
                entryID: firstID,
                attemptID: attempt,
                in: &entries,
                ledger: &ledger
            ) == .dequeued
        )
        #expect(entries.map(\.id) == [secondID])
        #expect(ledger.contains(entryID: firstID, attemptID: attempt))

        #expect(
            SessionInputOutboxPolicy.completeLocalDequeue(
                entryID: firstID,
                attemptID: attempt,
                in: &entries,
                ledger: &ledger
            ) == .alreadyDequeued
        )
        #expect(entries.map(\.id) == [secondID])
        #expect(ledger.receipts.count == 1)
    }

    @Test func headFailureBlocksAutomaticAdvancementUntilReview() {
        var entries: [QueuedFollowUp] = []
        let live = context()
        let headID = UUID()
        let tailID = UUID()
        let attempt = UUID()

        SessionInputOutboxPolicy.enqueue(text: "head", context: live, into: &entries, id: headID, date: fixedDate)
        SessionInputOutboxPolicy.enqueue(text: "tail", context: live, into: &entries, id: tailID, date: fixedDate)

        #expect(
            SessionInputOutboxPolicy.claimDispatch(
                entryID: headID,
                currentContext: live,
                in: &entries,
                attemptID: attempt
            ) == .claimed(attemptID: attempt)
        )

        let reason = QueuedFollowUpFailureReason(code: .providerUnavailable, detail: "route offline")
        #expect(
            SessionInputOutboxPolicy.recordFailure(
                entryID: headID,
                attemptID: attempt,
                reason: reason,
                in: &entries
            ) == .applied
        )
        #expect(entries[0].lifecycle == .failed(reason))

        #expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: headID,
                currentContext: live,
                in: entries
            ) == .ineligible(.notPending)
        )
        #expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: tailID,
                currentContext: live,
                in: entries
            ) == .ineligible(.notHead)
        )
        #expect(
            SessionInputOutboxPolicy.claimDispatch(
                entryID: tailID,
                currentContext: live,
                in: &entries
            ) == .rejected(.notHead)
        )

        #expect(
            SessionInputOutboxPolicy.acceptExplicitReview(
                entryID: headID,
                currentContext: live,
                in: &entries
            ) == .applied
        )
        #expect(entries[0].lifecycle == .pending)
        #expect(entries[0].context == live)
        #expect(
            SessionInputOutboxPolicy.headAutomaticDispatchEligibility(
                in: entries,
                currentContext: live
            ) == .eligible
        )
    }

    @Test func headBlockAlsoPreventsAutomaticAdvancement() {
        var entries: [QueuedFollowUp] = []
        let live = context()
        let headID = UUID()
        let tailID = UUID()
        SessionInputOutboxPolicy.enqueue(text: "head", context: live, into: &entries, id: headID, date: fixedDate)
        SessionInputOutboxPolicy.enqueue(text: "tail", context: live, into: &entries, id: tailID, date: fixedDate)
        entries[0].lifecycle = .blocked(.contextMismatch)

        #expect(
            SessionInputOutboxPolicy.headAutomaticDispatchEligibility(
                in: entries,
                currentContext: live
            ) == .ineligible(.notPending)
        )
        #expect(
            SessionInputOutboxPolicy.claimDispatch(
                entryID: tailID,
                currentContext: live,
                in: &entries
            ) == .rejected(.notHead)
        )
    }

    @Test func explicitReviewRefusesPendingAndDispatchingEntries() {
        var entries: [QueuedFollowUp] = []
        let live = context()
        let pendingID = UUID()
        let dispatchingID = UUID()
        SessionInputOutboxPolicy.enqueue(text: "p", context: live, into: &entries, id: pendingID, date: fixedDate)
        SessionInputOutboxPolicy.enqueue(text: "d", context: live, into: &entries, id: dispatchingID, date: fixedDate)
        entries[1].lifecycle = .dispatching(attemptID: UUID())

        #expect(
            SessionInputOutboxPolicy.acceptExplicitReview(
                entryID: pendingID,
                currentContext: live,
                in: &entries
            ) == .rejected(.notReviewable)
        )
        #expect(
            SessionInputOutboxPolicy.acceptExplicitReview(
                entryID: dispatchingID,
                currentContext: live,
                in: &entries
            ) == .rejected(.notReviewable)
        )
    }

    @Test func explicitReviewCanUpdateContextForBlockedLegacyEntry() {
        var entries = [QueuedFollowUp(text: "legacy", date: fixedDate)]
        let live = context()
        let id = entries[0].id
        #expect(
            SessionInputOutboxPolicy.acceptExplicitReview(
                entryID: id,
                currentContext: live,
                in: &entries
            ) == .applied
        )
        #expect(entries[0].context == live)
        #expect(entries[0].lifecycle == .pending)
        #expect(
            SessionInputOutboxPolicy.automaticDispatchEligibility(
                of: id,
                currentContext: live,
                in: entries
            ) == .eligible
        )
    }

    // MARK: - Restart recovery

    @Test func restartRecoveryForcesPendingAndDispatchingIntoExplicitReview() {
        var entries: [QueuedFollowUp] = []
        let live = context()
        let pendingID = UUID()
        let dispatchingID = UUID()
        let failedID = UUID()
        let blockedID = UUID()
        let legacyID = UUID()
        let attempt = UUID()

        SessionInputOutboxPolicy.enqueue(text: "pending", context: live, into: &entries, id: pendingID, date: fixedDate)
        SessionInputOutboxPolicy.enqueue(text: "dispatching", context: live, into: &entries, id: dispatchingID, date: fixedDate)
        SessionInputOutboxPolicy.enqueue(text: "failed", context: live, into: &entries, id: failedID, date: fixedDate)
        SessionInputOutboxPolicy.enqueue(text: "blocked", context: live, into: &entries, id: blockedID, date: fixedDate)
        entries.append(QueuedFollowUp(id: legacyID, text: "legacy", date: fixedDate))

        entries[1].lifecycle = .dispatching(attemptID: attempt)
        entries[2].lifecycle = .failed(.init(code: .cancelled))
        entries[3].lifecycle = .blocked(.awaitingExplicitReview)

        SessionInputOutboxPolicy.recoverAfterRestart(&entries)

        #expect(entries[0].lifecycle == .blocked(.restartRecovery))
        #expect(entries[1].lifecycle == .blocked(.restartRecovery))
        #expect(entries[2].lifecycle == .failed(.init(code: .cancelled)))
        #expect(entries[3].lifecycle == .blocked(.awaitingExplicitReview))
        #expect(entries[4].lifecycle == .blocked(.missingCapturedContext))

        for entry in entries {
            #expect(
                SessionInputOutboxPolicy.automaticDispatchEligibility(
                    of: entry.id,
                    currentContext: live,
                    in: entries
                ) != .eligible
            )
        }
    }

    // MARK: - Failure detail sanitization

    @Test func failureReasonSanitizesAndBoundsDetailWithoutKeepingRawControlNoise() {
        let noisy = "line1\nline2\u{0007}" + String(repeating: "x", count: 400)
        let reason = QueuedFollowUpFailureReason(code: .unknown, detail: noisy)
        #expect(reason.detail != nil)
        #expect((reason.detail?.count ?? 0) <= QueuedFollowUpFailureReason.maxDetailLength)
        #expect(reason.detail?.contains("\n") == false)
        #expect(reason.detail?.contains("\u{0007}") == false)
        #expect(QueuedFollowUpFailureReason(code: .unknown, detail: "   ").detail == nil)
    }

    // MARK: - Codable roundtrip + secret-free proof

    @Test func queuedFollowUpAndLedgerCodableRoundTrip() throws {
        let live = context()
        var entries: [QueuedFollowUp] = []
        var ledger = SessionInputOutboxReceiptLedger()
        let entryID = UUID()
        let attempt = UUID()

        SessionInputOutboxPolicy.enqueue(
            text: "round trip body",
            context: live,
            into: &entries,
            id: entryID,
            date: fixedDate
        )
        #expect(
            SessionInputOutboxPolicy.claimDispatch(
                entryID: entryID,
                currentContext: live,
                in: &entries,
                attemptID: attempt
            ) == .claimed(attemptID: attempt)
        )
        #expect(
            SessionInputOutboxPolicy.completeLocalDequeue(
                entryID: entryID,
                attemptID: attempt,
                in: &entries,
                ledger: &ledger
            ) == .dequeued
        )

        let blocked = QueuedFollowUp(
            id: UUID(),
            text: "needs review",
            date: fixedDate,
            context: live,
            lifecycle: .blocked(.restartRecovery)
        )
        let failed = QueuedFollowUp(
            id: UUID(),
            text: "failed send",
            date: fixedDate,
            context: live,
            lifecycle: .failed(.init(code: .dispatchRejected, detail: "bounded detail"))
        )
        let pending = QueuedFollowUp(
            id: UUID(),
            text: "ready",
            date: fixedDate,
            context: live,
            lifecycle: .pending
        )
        let queue = [blocked, failed, pending]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let queueData = try encoder.encode(queue)
        let ledgerData = try encoder.encode(ledger)
        let decodedQueue = try decoder.decode([QueuedFollowUp].self, from: queueData)
        let decodedLedger = try decoder.decode(SessionInputOutboxReceiptLedger.self, from: ledgerData)

        #expect(decodedQueue == queue)
        #expect(decodedLedger == ledger)
        #expect(decodedLedger.contains(entryID: entryID, attemptID: attempt))

        let session = LatticeSession(
            title: "Receipt persistence",
            backend: .codex(model: "gpt-5.4"),
            inputOutboxReceipts: ledger
        )
        let decodedSession = try decoder.decode(LatticeSession.self, from: encoder.encode(session))
        #expect(decodedSession.inputOutboxReceipts == ledger)
    }

    @Test func encodedOutboxArtifactsContainNoSuppliedSecretSentinel() throws {
        // Secret exists only outside the model surface (simulating credentials / provider sessions).
        let credentialMaterial = secretSentinel
        let providerSessionID = "provider-session-\(secretSentinel)"
        let unsafeAck = "acknowledged-unsafe-\(secretSentinel)"
        let transcriptSnippet = "user said \(secretSentinel) in chat"

        let live = SessionInputOutboxContext.capture(
            executionRoute: route(),
            workspacePath: "/Users/dev/project",
            policy: .ask,
            privacyMode: .cloudAllowed,
            reasoningEffort: .medium,
            attachments: [ContextAttachment(path: "/Users/dev/project/notes.md")]
        )
        #expect(!String(describing: live).contains(secretSentinel))

        var entries: [QueuedFollowUp] = []
        SessionInputOutboxPolicy.enqueue(
            text: "Please summarize the open PR",
            context: live,
            into: &entries,
            date: fixedDate
        )
        var ledger = SessionInputOutboxReceiptLedger()
        let attempt = UUID()
        #expect(
            SessionInputOutboxPolicy.claimDispatch(
                entryID: entries[0].id,
                currentContext: live,
                in: &entries,
                attemptID: attempt
            ) == .claimed(attemptID: attempt)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entryData = try encoder.encode(entries)
        let contextData = try encoder.encode(live)
        let ledgerData = try encoder.encode(ledger)
        let failure = QueuedFollowUpFailureReason(
            code: .unknown,
            detail: "provider unavailable"
        )
        let failureData = try encoder.encode(failure)

        let blobs = [entryData, contextData, ledgerData, failureData].map {
            String(decoding: $0, as: UTF8.self)
        }
        for blob in blobs {
            #expect(!blob.contains(secretSentinel))
            #expect(!blob.contains(credentialMaterial))
            #expect(!blob.contains(providerSessionID))
            #expect(!blob.contains(unsafeAck))
            #expect(!blob.contains(transcriptSnippet))
            #expect(!blob.contains("apiKey"))
            #expect(!blob.contains("providerSession"))
            #expect(!blob.contains("credential"))
        }

        // Keep locals "used" so the test documents the secret-adjacent inputs that must not leak.
        #expect(!credentialMaterial.isEmpty)
        #expect(!providerSessionID.isEmpty)
        #expect(!unsafeAck.isEmpty)
        #expect(!transcriptSnippet.isEmpty)
    }

    @Test func receiptLedgerIsBoundedAndDuplicateSafe() {
        var ledger = SessionInputOutboxReceiptLedger()
        let overflow = SessionInputOutboxReceiptLedger.maxReceipts + 8
        var firstEvicted: (UUID, UUID)?
        for index in 0..<overflow {
            let entryID = UUID()
            let attemptID = UUID()
            if index == 0 {
                firstEvicted = (entryID, attemptID)
            }
            #expect(ledger.record(entryID: entryID, attemptID: attemptID))
            #expect(!ledger.record(entryID: entryID, attemptID: attemptID))
        }
        #expect(ledger.receipts.count == SessionInputOutboxReceiptLedger.maxReceipts)
        if let firstEvicted {
            #expect(!ledger.contains(entryID: firstEvicted.0, attemptID: firstEvicted.1))
        }
    }

    @Test func captureHelperIgnoresAttachmentOrderAndMissingWorkspace() {
        let attachments = [
            ContextAttachment(path: "/tmp/b"),
            ContextAttachment(path: "/tmp/a")
        ]
        let captured = SessionInputOutboxContext.capture(
            executionRoute: route(),
            workspacePath: nil,
            policy: .smart,
            privacyMode: .localOnly,
            reasoningEffort: nil,
            attachments: attachments
        )
        #expect(captured.workspacePath == "")
        #expect(captured.attachmentPathIdentities == [
            SessionInputOutboxContext.standardizedPath("/tmp/a"),
            SessionInputOutboxContext.standardizedPath("/tmp/b")
        ])
    }

    // MARK: - Helpers

    private func jsonDate(_ date: Date) -> String {
        // Encode dates the way Foundation's default JSONEncoder does (double seconds).
        String(date.timeIntervalSinceReferenceDate)
    }
}
