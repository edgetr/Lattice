import Foundation
import LatticeCore

/// Narrow session projection for inspector details (avoids threading full AppState into every row).
struct InspectorSessionModel: Equatable {
    let id: UUID
    let title: String
    let modeDisplayName: String
    let providerDisplayName: String
    let modelDisplayName: String
    let runtimeID: String
    let reasoningDisplayName: String?
    let policy: ExecutionPolicy
    let privacyMode: SessionPrivacyMode
    let isStreaming: Bool
    let workspacePath: String?
    let isLocalBackend: Bool
    let hasUserMessages: Bool
    let usesLegacyDirectOpenCode: Bool

    init(session: LatticeSession, usesLegacyDirectOpenCode: Bool) {
        self.id = session.id
        self.title = session.title
        self.modeDisplayName = session.executionRoute.mode.displayName
        self.providerDisplayName = session.backend.harnessName
        self.modelDisplayName = session.backend.displayName
        self.runtimeID = session.executionRoute.runtimeID
        self.reasoningDisplayName = session.reasoningEffort?.displayName
        self.policy = session.policy
        self.privacyMode = session.privacyMode
        self.isStreaming = session.isStreaming
        self.workspacePath = session.workspacePath
        self.isLocalBackend = session.backend.isLocal
        self.hasUserMessages = session.messages.contains { $0.role == .user }
        self.usesLegacyDirectOpenCode = usesLegacyDirectOpenCode
    }
}
