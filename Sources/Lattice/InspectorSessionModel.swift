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
    let canChooseWorkspace: Bool
    let usesLegacyDirectOpenCode: Bool

    init(session: LatticeSession, usesLegacyDirectOpenCode: Bool) {
        self.id = session.id
        self.title = session.title
        self.modeDisplayName = session.executionRoute.mode.displayName
        self.providerDisplayName = session.backend.harnessName
        self.modelDisplayName = session.backend.displayName
        // Display product name for Lattice Agent; persistence wire id remains "pi".
        self.runtimeID = session.executionRoute.runtimeID == "pi"
            ? LatticeAgentExecutable.productDisplayName
            : session.executionRoute.runtimeID
        self.reasoningDisplayName = session.reasoningEffort?.displayName
        self.policy = session.policy
        self.privacyMode = session.privacyMode
        self.isStreaming = session.isStreaming
        self.workspacePath = session.workspacePath
        self.isLocalBackend = session.backend.isLocal
        self.hasUserMessages = session.totalMessageCount > 0
        self.canChooseWorkspace = !session.isStreaming
            && session.isTranscriptLoaded
            && session.totalMessageCount == 0
        self.usesLegacyDirectOpenCode = usesLegacyDirectOpenCode
    }
}
