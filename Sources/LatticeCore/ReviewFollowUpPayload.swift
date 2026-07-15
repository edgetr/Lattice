import Foundation

/// Builds composer-ready follow-up text from a checkpoint review note.
///
/// Notes never enter the composer automatically — only after an explicit
/// “Add to follow-up” action that uses this payload construction.
public enum ReviewFollowUpPayloadPolicy {
    public static let maximumBodyCharacters = 4_000

    public static func compose(
        path: String,
        body: String,
        lineRange: WorkspaceReviewLineRange? = nil,
        hunkHeader: String? = nil,
        kind: WorkspaceReviewNoteKind = .followUpPrompt
    ) -> String {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = sanitizeBody(body)
        var lines: [String] = []

        switch kind {
        case .followUpPrompt:
            lines.append("Follow-up on \(locationLabel(path: cleanPath, lineRange: lineRange)):")
        case .note:
            lines.append("Review note on \(locationLabel(path: cleanPath, lineRange: lineRange)):")
        }

        if let hunkHeader {
            let header = hunkHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            if !header.isEmpty {
                lines.append("Hunk: \(header)")
            }
        }

        if !cleanBody.isEmpty {
            lines.append(cleanBody)
        }

        return lines.joined(separator: "\n")
    }

    public static func compose(from note: WorkspaceReviewNote) -> String {
        compose(
            path: note.path,
            body: note.body,
            lineRange: note.lineRange,
            hunkHeader: note.hunkHeader,
            kind: note.kind
        )
    }

    /// Merge a review payload into an existing draft without silent overwrite.
    public static func mergeIntoDraft(existingDraft: String, payload: String) -> String {
        let draft = existingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let addition = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return existingDraft }
        if draft.isEmpty { return addition }
        if draft.contains(addition) { return existingDraft }
        return draft + "\n\n" + addition
    }

    public static func locationLabel(path: String, lineRange: WorkspaceReviewLineRange?) -> String {
        let base = path.isEmpty ? "(unknown path)" : path
        guard let lineRange else { return base }
        if lineRange.start == lineRange.end {
            return "\(base):\(lineRange.start)"
        }
        return "\(base):\(lineRange.start)-\(lineRange.end)"
    }

    public static func sanitizeBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumBodyCharacters else { return trimmed }
        return String(trimmed.prefix(maximumBodyCharacters))
    }
}
