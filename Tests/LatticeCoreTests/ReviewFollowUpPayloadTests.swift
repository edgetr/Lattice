import Foundation
import Testing
@testable import LatticeCore

@Suite("Review follow-up payload")
struct ReviewFollowUpPayloadTests {
    @Test func composesPathAndLineRange() {
        let payload = ReviewFollowUpPayloadPolicy.compose(
            path: "Sources/App.swift",
            body: "Please fix the nil check",
            lineRange: WorkspaceReviewLineRange(start: 10, end: 14),
            hunkHeader: "@@ -10,5 +10,6 @@",
            kind: .followUpPrompt
        )
        #expect(payload.contains("Sources/App.swift:10-14"))
        #expect(payload.contains("Please fix the nil check"))
        #expect(payload.contains("Hunk:"))
        #expect(payload.hasPrefix("Follow-up on"))
    }

    @Test func emptyDraftInsertsPayloadOnly() {
        let payload = "Follow-up on path:\nbody"
        let merged = ReviewFollowUpPayloadPolicy.mergeIntoDraft(existingDraft: "  ", payload: payload)
        #expect(merged == payload)
    }

    @Test func notesNeverOverwriteDraftSilently() {
        let merged = ReviewFollowUpPayloadPolicy.mergeIntoDraft(
            existingDraft: "Existing draft",
            payload: "Follow-up on path:\nbody"
        )
        #expect(merged.contains("Existing draft"))
        #expect(merged.contains("Follow-up on path:"))
    }

    @Test func remergeSamePayloadIsIdempotent() {
        let payload = "Follow-up on Sources/App.swift:\nfix me"
        let once = ReviewFollowUpPayloadPolicy.mergeIntoDraft(existingDraft: "base", payload: payload)
        let twice = ReviewFollowUpPayloadPolicy.mergeIntoDraft(existingDraft: once, payload: payload)
        #expect(once == twice)
    }

    @Test func emptyPayloadLeavesDraftAlone() {
        let merged = ReviewFollowUpPayloadPolicy.mergeIntoDraft(
            existingDraft: "keep me",
            payload: "   "
        )
        #expect(merged == "keep me")
    }

    @Test func composesFromSavedNote() {
        let note = WorkspaceReviewNote(
            checkpointID: UUID(),
            sessionID: UUID(),
            runID: UUID(),
            path: "README.md",
            lineRange: WorkspaceReviewLineRange(start: 1, end: 1),
            kind: .note,
            body: "Clarify install steps"
        )
        let payload = ReviewFollowUpPayloadPolicy.compose(from: note)
        #expect(payload.contains("Review note on README.md:1"))
        #expect(payload.contains("Clarify install steps"))
    }

    @Test func sanitizesOversizedBody() {
        let body = String(repeating: "x", count: ReviewFollowUpPayloadPolicy.maximumBodyCharacters + 100)
        let sanitized = ReviewFollowUpPayloadPolicy.sanitizeBody(body)
        #expect(sanitized.count == ReviewFollowUpPayloadPolicy.maximumBodyCharacters)
        let composed = ReviewFollowUpPayloadPolicy.compose(path: "a.swift", body: body)
        #expect(!composed.contains(String(repeating: "x", count: ReviewFollowUpPayloadPolicy.maximumBodyCharacters + 1)))
    }
}
