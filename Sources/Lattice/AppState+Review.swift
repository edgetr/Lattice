import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    // MARK: - Review navigation

    func openCheckpointReview() {
        showInspector = true
        preferredInspectorSurface = .review
        if let runID = selectedCheckpointReview?.runID {
            lastAutoPromotedReviewRunID = runID
        }
    }

    /// Promote Review at most once per checkpoint runID, without fighting a deliberate Details choice.
    func maybeAutoPromoteCheckpointReview(for review: WorkspaceCheckpointReviewState) {
        guard review.activity == .ready else { return }
        guard selectedSession?.executionRoute.mode == .code else { return }
        if lastAutoPromotedReviewRunID == review.runID { return }
        lastAutoPromotedReviewRunID = review.runID
        preferredInspectorSurface = .review
        // Do not force-show inspector if user hid it; strip CTA still uses openCheckpointReview().
    }

    // MARK: - Review follow-up

    func addReviewNoteToComposer(_ note: WorkspaceReviewNote) {
        let payload = ReviewFollowUpPayloadPolicy.compose(from: note)
        draft = ReviewFollowUpPayloadPolicy.mergeIntoDraft(existingDraft: draft, payload: payload)
        if case .compact = composerStateForBinding {
            setVisibleComposerState(.expanded, for: selectedSession?.id)
        }
    }

    func addReviewSelectionToComposer(
        path: String,
        body: String,
        kind: WorkspaceReviewNoteKind,
        lineRange: WorkspaceReviewLineRange?,
        hunkHeader: String?
    ) {
        let payload = ReviewFollowUpPayloadPolicy.compose(
            path: path,
            body: body,
            lineRange: lineRange,
            hunkHeader: hunkHeader,
            kind: kind
        )
        draft = ReviewFollowUpPayloadPolicy.mergeIntoDraft(existingDraft: draft, payload: payload)
        if case .compact = composerStateForBinding {
            setVisibleComposerState(.expanded, for: selectedSession?.id)
        }
    }
}

extension String {
    /// Minimal single-quote escape for pre-filling a shell `cd` path.
    var shellSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
