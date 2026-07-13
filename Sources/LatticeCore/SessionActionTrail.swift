import Foundation

public enum SessionActionTrail {
    public static func upsert(_ action: SessionAction, in actions: inout [SessionAction], limit: Int = 200) {
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        if actions.count > limit {
            actions.removeFirst(actions.count - limit)
        }
    }

    @discardableResult
    public static func update(id: UUID, status: SessionAction.Status, in actions: inout [SessionAction], at date: Date = .now) -> Bool {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return false }
        actions[index].status = status
        actions[index].updatedAt = date
        return true
    }

    @discardableResult
    public static func appendDetail(
        id: UUID,
        delta: String,
        in actions: inout [SessionAction],
        limit: Int = 24_000,
        at date: Date = .now
    ) -> Bool {
        guard !delta.isEmpty, let index = actions.firstIndex(where: { $0.id == id }) else { return false }
        let combined = actions[index].detail + delta
        actions[index].detail = combined.count > limit ? String(combined.suffix(limit)) : combined
        actions[index].updatedAt = date
        return true
    }

    @discardableResult
    public static func finishPending(for messageID: UUID, as status: SessionAction.Status, in actions: inout [SessionAction], at date: Date = .now) -> Int {
        var count = 0
        for index in actions.indices
        where actions[index].messageID == messageID && [.running, .waiting].contains(actions[index].status) {
            actions[index].status = status
            actions[index].updatedAt = date
            count += 1
        }
        return count
    }

    @discardableResult
    public static func finishCompletedTurn(for messageID: UUID, in actions: inout [SessionAction], at date: Date = .now) -> Int {
        var count = 0
        for index in actions.indices where actions[index].messageID == messageID {
            switch (actions[index].kind, actions[index].status) {
            case (.tool, .running), (.plan, .running), (.reasoning, .running):
                actions[index].status = .completed
            case (.approval, .waiting):
                actions[index].status = .cancelled
            default:
                continue
            }
            actions[index].updatedAt = date
            count += 1
        }
        return count
    }

    public static func prune(in actions: inout [SessionAction], keepingMessageIDs: Set<UUID>) {
        actions.removeAll { !keepingMessageIDs.contains($0.messageID) }
    }
}

public enum ProviderDiagnosticRetentionPolicy {
    public static func action(for diagnostic: ProviderEventDiagnostic, assistantMessageID: UUID?) -> SessionAction? {
        guard let assistantMessageID else { return nil }
        return SessionAction(
            id: diagnostic.id,
            messageID: assistantMessageID,
            kind: .diagnostic,
            title: diagnostic.title,
            detail: diagnostic.detail,
            status: .failed
        )
    }
}
