import Foundation

public enum OverlayMode: String, CaseIterable, Sendable {
    case idle
    case prompt
    case context
    case running
    case result
    case compactChat
}

public struct RunUIActivity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let icon: String
    public let title: String
    public let detail: String

    public init(id: UUID = UUID(), icon: String, title: String, detail: String) {
        self.id = id
        self.icon = icon
        self.title = title
        self.detail = detail
    }
}

public struct RunUIState: Equatable, Sendable {
    public var overlayMode: OverlayMode
    public var composerState: MorphingControlState
    public var overlayControlState: MorphingControlState
    public var activity: [RunUIActivity]
    public var errorMessage: String?

    public init(
        overlayMode: OverlayMode = .idle,
        composerState: MorphingControlState = .expanded,
        overlayControlState: MorphingControlState = .expanded,
        activity: [RunUIActivity] = [],
        errorMessage: String? = nil
    ) {
        self.overlayMode = overlayMode
        self.composerState = composerState
        self.overlayControlState = overlayControlState
        self.activity = activity
        self.errorMessage = errorMessage
    }
}

public enum RunUIAction: Equatable, Sendable {
    case started
    case permissionRequested
    case permissionResolved
    case setActivity([RunUIActivity])
    case upsertActivity(RunUIActivity)
    case clearActivity
    case setComposerState(MorphingControlState)
    case setOverlayControlState(MorphingControlState)
    case setOverlayMode(OverlayMode)
    case setError(String)
    case clearError
    case completed
    case cancelled
    case failed(String)
}

public enum RunUIReducer {
    public static func reduce(_ action: RunUIAction, into state: inout RunUIState) {
        switch action {
        case .started:
            state.overlayMode = .running
            state.composerState = .progress(0.1)
            state.overlayControlState = .progress(0.1)
            state.activity.removeAll()
            state.errorMessage = nil
        case .permissionRequested:
            state.composerState = .approval
            state.overlayControlState = .approval
        case .permissionResolved:
            state.composerState = .progress(0.5)
            state.overlayControlState = .progress(0.5)
        case .setActivity(let activity):
            state.activity = activity
        case .upsertActivity(let item):
            if let index = state.activity.firstIndex(where: { $0.id == item.id }) {
                state.activity[index] = item
            } else {
                state.activity.append(item)
            }
            state.activity = Array(state.activity.suffix(4))
        case .clearActivity:
            state.activity.removeAll()
        case .setComposerState(let value):
            state.composerState = value
        case .setOverlayControlState(let value):
            state.overlayControlState = value
        case .setOverlayMode(let value):
            state.overlayMode = value
        case .setError(let message):
            state.errorMessage = message
        case .clearError:
            state.errorMessage = nil
        case .completed, .cancelled:
            state.overlayMode = .result
            state.composerState = .expanded
            state.overlayControlState = .expanded
            state.activity.removeAll()
            state.errorMessage = nil
        case .failed(let message):
            state.overlayMode = .prompt
            state.composerState = .expanded
            state.overlayControlState = .expanded
            state.activity.removeAll()
            state.errorMessage = message
        }
    }
}
