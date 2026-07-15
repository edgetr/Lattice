import Foundation

public enum LatticeStyleTarget: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case overlay
    case composer
    case search
    case card
}

public struct LatticeStylePatch: Codable, Hashable, Sendable {
    public let target: LatticeStyleTarget
    public let tintHex: String?
    public let accentHex: String?
    public let cornerRadius: Double?

    public init(target: LatticeStyleTarget, tintHex: String? = nil, accentHex: String? = nil, cornerRadius: Double? = nil) {
        self.target = target
        self.tintHex = tintHex
        self.accentHex = accentHex
        self.cornerRadius = cornerRadius
    }
}

public enum LatticeLayoutTarget: String, CaseIterable, Codable, Hashable, Sendable {
    case composer

    public var displayName: String {
        switch self {
        case .composer: "Composer"
        }
    }
}

public enum LatticeLayoutDensity: String, CaseIterable, Codable, Hashable, Sendable {
    case compact
    case comfortable
    case spacious

    public var displayName: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .spacious: "Spacious"
        }
    }
}

public struct LatticeLayoutPatch: Codable, Hashable, Sendable {
    public let target: LatticeLayoutTarget
    public let density: LatticeLayoutDensity

    public init(target: LatticeLayoutTarget, density: LatticeLayoutDensity) {
        self.target = target
        self.density = density
    }
}

public enum LatticeCopyTarget: String, CaseIterable, Codable, Hashable, Sendable {
    case askButton
    case promptPlaceholder
    case emptyChatTitle

    public var displayName: String {
        switch self {
        case .askButton: "Ask button"
        case .promptPlaceholder: "Prompt placeholder"
        case .emptyChatTitle: "Empty chat title"
        }
    }
}

public struct LatticeCopyPatch: Codable, Hashable, Sendable {
    public let target: LatticeCopyTarget
    public let text: String

    public init(target: LatticeCopyTarget, text: String) {
        self.target = target
        self.text = text
    }
}

public struct LatticePromptTemplate: Codable, Hashable, Sendable {
    public let invocation: String
    public let title: String
    public let detail: String
    public let prompt: String

    public init(invocation: String, title: String, detail: String = "", prompt: String) {
        self.invocation = invocation
        self.title = title
        self.detail = detail
        self.prompt = prompt
    }

    public var command: LatticeAppCommand {
        LatticeAppCommand(
            id: "template:\(invocation)",
            invocation: invocation,
            title: title,
            detail: detail.isEmpty ? "Insert prompt template" : detail,
            replacementText: prompt
        )
    }
}

public struct LatticeExtensionOperationPreview: Codable, Hashable, Sendable {
    public let targetSurfaceID: String
    public let operation: LatticeEditableOperation
    public let summary: String
    public let detail: String

    public init(targetSurfaceID: String, operation: LatticeEditableOperation, summary: String, detail: String = "") {
        self.targetSurfaceID = targetSurfaceID
        self.operation = operation
        self.summary = summary
        self.detail = detail
    }
}

public enum LatticeExtensionOperationExecution: String, Codable, Hashable, Sendable {
    case executable
    case recordedOnly

    public var displayName: String {
        switch self {
        case .executable: "Executable"
        case .recordedOnly: "Recorded only"
        }
    }
}

public enum LatticeEditableOperation: String, CaseIterable, Codable, Hashable, Sendable {
    case restyle
    case relayout
    case rewriteCopy
    case addControl
    case addModelRecommendation
    case addHarnessRoute
    case addSkill
    case addAutomation

    public var displayName: String {
        switch self {
        case .restyle: "Restyle"
        case .relayout: "Relayout"
        case .rewriteCopy: "Rewrite copy"
        case .addControl: "Add control"
        case .addModelRecommendation: "Add model recommendation"
        case .addHarnessRoute: "Add harness route"
        case .addSkill: "Add skill"
        case .addAutomation: "Add automation"
        }
    }
}

public enum LatticeExtensionOperationRuntimePolicy {
    public static func execution(for preview: LatticeExtensionOperationPreview, in manifest: LatticeExtensionManifest) -> LatticeExtensionOperationExecution {
        switch preview.operation {
        case .restyle:
            return manifest.stylePatches.contains { patch in
                patch.target == .all || surface(preview.targetSurfaceID, includesStyleTarget: patch.target)
            } ? .executable : .recordedOnly
        case .rewriteCopy:
            return manifest.copyPatches.isEmpty ? .recordedOnly : .executable
        case .addControl:
            return manifest.promptTemplates.isEmpty ? .recordedOnly : .executable
        case .relayout:
            return manifest.layoutPatches.contains { patch in
                surface(preview.targetSurfaceID, includesLayoutTarget: patch.target)
            } ? .executable : .recordedOnly
        case .addSkill:
            return manifest.skillPatches.isEmpty ? .recordedOnly : .executable
        case .addModelRecommendation, .addHarnessRoute, .addAutomation:
            return .recordedOnly
        }
    }

    public static func executableOperationCount(in manifest: LatticeExtensionManifest) -> Int {
        manifest.operationPreviews.filter { execution(for: $0, in: manifest) == .executable }.count
    }

    public static func recordedOnlyOperationCount(in manifest: LatticeExtensionManifest) -> Int {
        manifest.operationPreviews.filter { execution(for: $0, in: manifest) == .recordedOnly }.count
    }

    private static func surface(_ surfaceID: String, includesStyleTarget target: LatticeStyleTarget) -> Bool {
        guard target != .all else { return true }
        return LatticeSelfMap.defaultSurfaces
            .first { $0.id == surfaceID.trimmingCharacters(in: .whitespacesAndNewlines) }?
            .extensionTargets
            .contains(target) == true
    }

    private static func surface(_ surfaceID: String, includesLayoutTarget target: LatticeLayoutTarget) -> Bool {
        switch target {
        case .composer:
            return surfaceID.trimmingCharacters(in: .whitespacesAndNewlines) == "composer"
        }
    }
}

public struct LatticeEditableSurface: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let operations: [LatticeEditableOperation]
    public let extensionTargets: [LatticeStyleTarget]

    public init(id: String, name: String, summary: String, operations: [LatticeEditableOperation], extensionTargets: [LatticeStyleTarget] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.operations = operations
        self.extensionTargets = extensionTargets
    }
}

public struct LatticeSelfMap: Codable, Hashable, Sendable {
    public let surfaces: [LatticeEditableSurface]

    public init(surfaces: [LatticeEditableSurface] = Self.defaultSurfaces) {
        self.surfaces = surfaces
    }

    public static let defaultSurfaces: [LatticeEditableSurface] = [
        .init(id: "overlay", name: "Overlay", summary: "Floating prompt, compact chat, and workspace handoff.", operations: [.restyle, .relayout, .rewriteCopy, .addControl], extensionTargets: [.overlay, .composer]),
        .init(id: "composer", name: "Composer", summary: "Prompt input, attachments, model and reasoning controls.", operations: [.restyle, .relayout, .addControl], extensionTargets: [.composer]),
        .init(id: "chat", name: "Chat", summary: "Conversation transcript, streaming state, work indicators, and branches.", operations: [.restyle, .relayout, .rewriteCopy, .addControl], extensionTargets: [.card]),
        .init(id: "models", name: "Models", summary: "Local/cloud model catalog, recommendations, installs, and unload policy.", operations: [.addModelRecommendation, .rewriteCopy, .relayout], extensionTargets: [.card]),
        .init(id: "connections", name: "Connections", summary: "Provider auth, model visibility, CLI install/update, and usage surfaces.", operations: [.addHarnessRoute, .rewriteCopy, .relayout], extensionTargets: [.card]),
        .init(id: "extensions", name: "Extensions & Skills", summary: "Installed customization bundles, global skills, self-edit history, and rollback controls.", operations: [.restyle, .relayout, .rewriteCopy, .addControl, .addSkill], extensionTargets: [.card]),
        .init(id: "settings", name: "Settings", summary: "Persistent app preferences and local model lifecycle controls.", operations: [.restyle, .rewriteCopy, .addControl], extensionTargets: [.card]),
        .init(id: "sidebar", name: "Sidebar", summary: "Primary navigation and working-chat indicators.", operations: [.restyle, .relayout, .addControl], extensionTargets: [.card])
    ]
}

public enum LatticeEditProposalStatus: String, Codable, Hashable, Sendable {
    case draft
    case previewing
    case applied
    case reverted
    case failed
}

public struct LatticeEditProposal: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let request: String
    public let targetSurfaceID: String
    public let operations: [LatticeEditableOperation]
    public let createdAt: Date
    public var status: LatticeEditProposalStatus
    public var summary: String

    public init(id: UUID = UUID(), request: String, targetSurfaceID: String, operations: [LatticeEditableOperation], createdAt: Date = .now, status: LatticeEditProposalStatus = .draft, summary: String) {
        self.id = id
        self.request = request
        self.targetSurfaceID = targetSurfaceID
        self.operations = operations
        self.createdAt = createdAt
        self.status = status
        self.summary = summary
    }
}
