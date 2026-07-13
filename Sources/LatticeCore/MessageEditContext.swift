import Foundation

public struct MessageEditContext: Equatable, Sendable {
    public let sessionID: UUID
    public let messageID: UUID

    public init(sessionID: UUID, messageID: UUID) {
        self.sessionID = sessionID
        self.messageID = messageID
    }

    public func belongs(to selectedSessionID: UUID?) -> Bool {
        sessionID == selectedSessionID
    }
}

/// Pure state for preserving the composer draft while a message is being edited.
public struct MessageEditDraftState: Equatable, Sendable {
    public let context: MessageEditContext
    public let preservedComposerDraft: String

    public init(context: MessageEditContext, preservedComposerDraft: String) {
        self.context = context
        self.preservedComposerDraft = preservedComposerDraft
    }

    /// Begin editing: keep the prior composer draft, surface the message text as the active draft.
    public static func begin(
        sessionID: UUID,
        messageID: UUID,
        messageText: String,
        currentDraft: String,
        existing: MessageEditDraftState?
    ) -> (state: MessageEditDraftState, draft: String) {
        let preserved = existing?.preservedComposerDraft ?? currentDraft
        let state = MessageEditDraftState(
            context: MessageEditContext(sessionID: sessionID, messageID: messageID),
            preservedComposerDraft: preserved
        )
        return (state, messageText)
    }

    /// Exit edit mode without sending: restore the draft that was present before editing began.
    public static func cancel(_ state: MessageEditDraftState?) -> String {
        state?.preservedComposerDraft ?? ""
    }

    /// Successful send: clear edit mode while retaining the pre-edit ordinary draft (still unsent).
    /// Transient edited-message text is never treated as the ordinary session draft.
    public static func complete(_ state: MessageEditDraftState?) -> String {
        state?.preservedComposerDraft ?? ""
    }
}

/// Pure selection/edit transitions for per-chat ordinary composer drafts.
/// Keeps AppState free of untestable ordering bugs when switching chats.
public enum ComposerSessionDraftTransition: Sendable {
    public struct Result: Equatable, Sendable {
        /// When non-nil, write this string onto the previous session's durable `draft`.
        public let previousSessionDraft: String?
        /// Composer text after the transition (destination session ordinary draft, or empty).
        public let composerDraft: String
        /// Whether message-edit state must be cleared.
        public let clearsEditState: Bool

        public init(previousSessionDraft: String?, composerDraft: String, clearsEditState: Bool) {
            self.previousSessionDraft = previousSessionDraft
            self.composerDraft = composerDraft
            self.clearsEditState = clearsEditState
        }
    }

    /// Initial selection is assigned during `AppState.init`, where Swift does not run property observers.
    /// Resolve the launch composer explicitly so a restored chat immediately shows its durable draft.
    public static func initialComposerDraft(selectedID: UUID?, storedDraftForSelected: String?) -> String {
        guard selectedID != nil else { return "" }
        return storedDraftForSelected ?? ""
    }

    /// Compute durable draft writes and the next composer text when selection changes.
    ///
    /// While editing, the composer holds transient message text which must never be written
    /// as the ordinary session draft. Leaving that chat restores the preserved ordinary draft
    /// onto the origin session, then loads the destination chat's own draft.
    public static func selecting(
        from previousID: UUID?,
        to nextID: UUID?,
        composerText: String,
        edit: MessageEditDraftState?,
        storedDraftForNext: String
    ) -> Result {
        if previousID == nextID {
            return Result(previousSessionDraft: nil, composerDraft: composerText, clearsEditState: false)
        }

        let previousSessionDraft: String?
        let clearsEditState: Bool

        if let edit {
            if let previousID, edit.context.sessionID == previousID {
                previousSessionDraft = edit.preservedComposerDraft
            } else if previousID != nil {
                previousSessionDraft = composerText
            } else {
                previousSessionDraft = nil
            }
            clearsEditState = !edit.context.belongs(to: nextID)
        } else {
            previousSessionDraft = previousID != nil ? composerText : nil
            clearsEditState = false
        }

        return Result(
            previousSessionDraft: previousSessionDraft,
            composerDraft: storedDraftForNext,
            clearsEditState: clearsEditState
        )
    }

    /// Ordinary send or follow-up queue: clear only this chat's ordinary draft after the text is captured.
    public static func clearingOrdinaryDraft() -> String { "" }

    /// Failed send validation leaves the ordinary draft untouched.
    public static func preservingOrdinaryDraft(_ draft: String) -> String { draft }
}

/// Pure policy for chat deletion while a run may be streaming.
public enum SessionDeletionPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case deleteIdle
        /// Cancel the target session's own run/harness, then delete. Never stop a different selected session.
        case cancelTargetThenDelete(targetSessionID: UUID)
        case rejectStreamingWithoutCancel
    }

    /// Prefer cancelling the target by id. Callers must not stop a different selected session.
    public static func decision(forStreamingTarget targetSessionID: UUID, isStreaming: Bool) -> Decision {
        if isStreaming {
            return .cancelTargetThenDelete(targetSessionID: targetSessionID)
        }
        return .deleteIdle
    }
}
