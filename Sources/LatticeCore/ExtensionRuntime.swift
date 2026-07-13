import Foundation

public enum LatticeExtensionPermission: String, CaseIterable, Codable, Hashable, Sendable {
    case editUI
    case readWorkspace
    case writeWorkspace
    case runCommands
    case network
    case automation

    public var displayName: String {
        switch self {
        case .editUI: "Edit UI"
        case .readWorkspace: "Read workspace"
        case .writeWorkspace: "Write workspace"
        case .runCommands: "Run commands"
        case .network: "Network"
        case .automation: "Automation"
        }
    }
}

public struct LatticeExtensionManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    public let permissions: [LatticeExtensionPermission]
    public let entrypoint: String?
    public let uiTargets: [String]
    public let stylePatches: [LatticeStylePatch]
    public let layoutPatches: [LatticeLayoutPatch]
    public let copyPatches: [LatticeCopyPatch]
    public let promptTemplates: [LatticePromptTemplate]
    public let skillPatches: [LatticeSkillPatch]
    public let operationPreviews: [LatticeExtensionOperationPreview]
    public var hasRuntimePatches: Bool { !stylePatches.isEmpty || !layoutPatches.isEmpty || !copyPatches.isEmpty || !promptTemplates.isEmpty || !skillPatches.isEmpty }

    public init(schemaVersion: Int = 1, id: String, name: String, version: String, summary: String, permissions: [LatticeExtensionPermission] = [], entrypoint: String? = nil, uiTargets: [String] = [], stylePatches: [LatticeStylePatch] = [], layoutPatches: [LatticeLayoutPatch] = [], copyPatches: [LatticeCopyPatch] = [], promptTemplates: [LatticePromptTemplate] = [], skillPatches: [LatticeSkillPatch] = [], operationPreviews: [LatticeExtensionOperationPreview] = []) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.permissions = permissions
        self.entrypoint = entrypoint
        self.uiTargets = uiTargets
        self.stylePatches = stylePatches
        self.layoutPatches = layoutPatches
        self.copyPatches = copyPatches
        self.promptTemplates = promptTemplates
        self.skillPatches = skillPatches
        self.operationPreviews = operationPreviews
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, version, summary, permissions, entrypoint, uiTargets, stylePatches, layoutPatches, copyPatches, promptTemplates, skillPatches, operationPreviews
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        permissions = try container.decodeIfPresent([LatticeExtensionPermission].self, forKey: .permissions) ?? []
        entrypoint = try container.decodeIfPresent(String.self, forKey: .entrypoint)
        uiTargets = try container.decodeIfPresent([String].self, forKey: .uiTargets) ?? []
        stylePatches = try container.decodeIfPresent([LatticeStylePatch].self, forKey: .stylePatches) ?? []
        layoutPatches = try container.decodeIfPresent([LatticeLayoutPatch].self, forKey: .layoutPatches) ?? []
        copyPatches = try container.decodeIfPresent([LatticeCopyPatch].self, forKey: .copyPatches) ?? []
        promptTemplates = try container.decodeIfPresent([LatticePromptTemplate].self, forKey: .promptTemplates) ?? []
        skillPatches = try container.decodeIfPresent([LatticeSkillPatch].self, forKey: .skillPatches) ?? []
        operationPreviews = try container.decodeIfPresent([LatticeExtensionOperationPreview].self, forKey: .operationPreviews) ?? []
    }
}

public struct LatticeExtensionChangeReview: Hashable, Sendable {
    public let changes: [String]
    public let acceptanceSummary: String
    public var hasChanges: Bool { !changes.isEmpty }

    public init(changes: [String], acceptanceSummary: String) {
        self.changes = changes
        self.acceptanceSummary = acceptanceSummary
    }
}

public enum LatticeSelfEditReviewCopy {
    public static let readyStatus = "Lattice change ready for review."
}

public enum LatticeSelfEditApplyStatusPolicy {
    public static func status(for manifest: LatticeExtensionManifest) -> String {
        let executableOperations = LatticeExtensionOperationRuntimePolicy.executableOperationCount(in: manifest)
        let recordedOnlyOperations = LatticeExtensionOperationRuntimePolicy.recordedOnlyOperationCount(in: manifest)
        if manifest.hasRuntimePatches {
            if recordedOnlyOperations > 0 {
                return "Applied \(manifest.name). Recorded \(recordedOnlyOperations) future-operation \(recordedOnlyOperations == 1 ? "plan" : "plans") for review."
            }
            if executableOperations > 0 {
                return "Applied \(manifest.name) with \(executableOperations) executable operation \(executableOperations == 1 ? "preview" : "previews")."
            }
            return "Applied \(manifest.name)."
        }
        if !manifest.operationPreviews.isEmpty { return "Recorded \(manifest.name) as a review-only plan. No runtime change was applied." }
        return "Cleared \(manifest.name)."
    }
}

public enum LatticeExtensionChangeReviewBuilder {
    public static func review(current: LatticeExtensionManifest, previous: LatticeExtensionManifest?) -> LatticeExtensionChangeReview {
        var changes: [String] = []

        if let previous {
            if current.name != previous.name {
                changes.append("Rename the extension to “\(current.name)”.")
            }
            if current.version != previous.version {
                changes.append("Update the extension version to \(current.version).")
            }
            if current.summary != previous.summary {
                let summary = current.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                changes.append(summary.isEmpty ? "Clear the extension summary." : "Update the extension summary to “\(summary)”.")
            }
        }

        appendChanges(
            current: current.stylePatches,
            previous: previous?.stylePatches ?? [],
            key: { $0.target.rawValue },
            describe: { patch in
                let values = [
                    patch.tintHex.map { "tint \($0)" },
                    patch.accentHex.map { "accent \($0)" },
                    patch.cornerRadius.map { "corner radius \(Int($0)) pt" }
                ].compactMap { $0 }.joined(separator: ", ")
                return "Restyle \(patch.target.rawValue.capitalized): \(values)."
            },
            removed: { "Remove the \($0.target.rawValue) style override." },
            into: &changes
        )
        appendChanges(
            current: current.layoutPatches,
            previous: previous?.layoutPatches ?? [],
            key: { $0.target.rawValue },
            describe: { "Set \($0.target.displayName.lowercased()) density to \($0.density.displayName.lowercased())." },
            removed: { "Remove the \($0.target.displayName.lowercased()) layout override." },
            into: &changes
        )
        appendChanges(
            current: current.copyPatches,
            previous: previous?.copyPatches ?? [],
            key: { $0.target.rawValue },
            describe: { "Change \($0.target.displayName.lowercased()) text to “\($0.text)”." },
            removed: { "Restore the default \($0.target.displayName.lowercased()) text." },
            into: &changes
        )
        appendChanges(
            current: current.promptTemplates,
            previous: previous?.promptTemplates ?? [],
            key: { $0.invocation },
            describe: { template in
                let verb = previous?.promptTemplates.contains(where: { $0.invocation == template.invocation }) == true ? "Update" : "Add"
                return "\(verb) the \(template.invocation) prompt template."
            },
            removed: { "Remove the \($0.invocation) prompt template." },
            into: &changes
        )
        appendChanges(
            current: current.skillPatches,
            previous: previous?.skillPatches ?? [],
            key: { $0.id },
            describe: { skill in
                let verb = previous?.skillPatches.contains(where: { $0.id == skill.id }) == true ? "Update" : "Add"
                return "\(verb) the /\(skill.id) skill: \(skill.summary)"
            },
            removed: { "Remove the /\($0.id) skill owned by this extension." },
            into: &changes
        )
        appendChanges(
            current: recordedOnlyOperations(in: current),
            previous: previous.map(recordedOnlyOperations(in:)) ?? [],
            key: operationKey,
            describe: { operation in
                let detail = operation.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = detail.isEmpty ? "" : " \(detail)"
                return "Record \(operation.operation.displayName.lowercased()) for \(operation.targetSurfaceID): \(operation.summary)\(suffix)"
            },
            removed: { "Remove recorded \($0.operation.displayName.lowercased()) note for \($0.targetSurfaceID)." },
            into: &changes
        )

        let executableCount = LatticeExtensionOperationRuntimePolicy.executableOperationCount(in: current)
        let recordedOnlyCount = LatticeExtensionOperationRuntimePolicy.recordedOnlyOperationCount(in: current)
        let rollback = " You can roll it back later from Extensions & Skills."
        let summary: String
        if changes.isEmpty, recordedOnlyCount > 0, executableCount == 0 {
            summary = "Applying records this proposal for review, but does not change Lattice's runtime behavior."
        } else if changes.isEmpty {
            summary = "This proposal does not change the currently installed customization."
        } else if !current.hasRuntimePatches, recordedOnlyCount > 0, executableCount == 0 {
            let noun = changes.count == 1 ? "change" : "changes"
            summary = "Applying records the \(changes.count) \(noun) shown below for review, but does not change Lattice's runtime behavior. Nothing else in Lattice is modified.\(rollback)"
        } else if current.hasRuntimePatches, recordedOnlyCount > 0 {
            summary = "Applying makes the runtime changes shown below and records \(recordedOnlyCount) future-operation \(recordedOnlyCount == 1 ? "plan" : "plans") for review. Recorded plans do not change Lattice's runtime behavior yet. Nothing else in Lattice is modified.\(rollback)"
        } else {
            let noun = changes.count == 1 ? "change" : "changes"
            summary = "Applying makes the \(changes.count) \(noun) shown below. Nothing else in Lattice is modified.\(rollback)"
        }
        return .init(changes: changes, acceptanceSummary: summary)
    }

    private static func appendChanges<Value: Hashable>(
        current: [Value],
        previous: [Value],
        key: (Value) -> String,
        describe: (Value) -> String,
        removed: (Value) -> String,
        into changes: inout [String]
    ) {
        var previousByKey: [String: Value] = [:]
        for value in previous where previousByKey[key(value)] == nil {
            previousByKey[key(value)] = value
        }
        var currentByKey: [String: Value] = [:]
        for value in current where currentByKey[key(value)] == nil {
            currentByKey[key(value)] = value
        }
        for value in current where previousByKey[key(value)] != value {
            changes.append(describe(value))
        }
        for value in previous where currentByKey[key(value)] == nil {
            changes.append(removed(value))
        }
    }

    private static func recordedOnlyOperations(in manifest: LatticeExtensionManifest) -> [LatticeExtensionOperationPreview] {
        manifest.operationPreviews.filter {
            LatticeExtensionOperationRuntimePolicy.execution(for: $0, in: manifest) == .recordedOnly
        }
    }

    private static func operationKey(_ preview: LatticeExtensionOperationPreview) -> String {
        [
            preview.targetSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines),
            preview.operation.rawValue
        ].joined(separator: "#")
    }
}

public enum LatticeSelfEditReviewDecision: String, Hashable, Sendable {
    case accept
    case discard

    public static func parse(_ text: String) -> Self? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let tokens = normalized.split(separator: " ").map(String.init)
        let tokenSet = Set(tokens)
        let negatedOrAmbiguous = [
            "do not", "don t", "dont", "don't", "not accept", "not apply", "not approve",
            "not discard", "not reject", "never accept", "never apply", "never discard",
            "should i", "can you", "could you", "would you"
        ].contains { original.contains($0) || normalized.contains($0) }
        if negatedOrAmbiguous || original.contains("?") { return nil }
        let acceptPhrases: Set<String> = [
            "accept", "accept it", "accept this", "accept this change", "accept the change",
            "apply", "apply it", "apply this", "apply this change", "apply the change",
            "approve", "approve it", "approve this", "approve this change", "approve the change",
            "yes accept", "yes accept it", "yes apply", "yes apply it", "yes approve", "yes approve it",
            "looks good accept", "looks good apply", "looks good approve",
            "go ahead", "go ahead accept", "go ahead apply", "go ahead approve",
            "go ahead and accept it", "go ahead and apply it", "go ahead and approve it"
        ]
        let discardPhrases: Set<String> = [
            "discard", "discard it", "discard this", "discard this change", "discard the change",
            "reject", "reject it", "reject this", "reject this change", "reject the change",
            "cancel this change", "cancel the change", "cancel it",
            "please cancel it", "please cancel this change", "cancel this proposal",
            "yes discard", "yes discard it", "yes reject", "yes reject it",
            "throw it away", "drop it", "please drop it", "drop this proposal",
            "remove the proposal", "remove this proposal"
        ]
        if acceptPhrases.contains(normalized) { return .accept }
        if discardPhrases.contains(normalized) { return .discard }
        if tokenSet.contains("please") || tokenSet.contains("yes") {
            let acceptTokens: Set<String> = ["accept", "apply", "approve"]
            if !tokenSet.isDisjoint(with: acceptTokens), tokens.count <= 5 { return .accept }
            let discardTokens: Set<String> = ["discard", "reject"]
            if !tokenSet.isDisjoint(with: discardTokens), tokens.count <= 5 { return .discard }
        }
        return nil
    }
}

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

public struct LatticeExtensionRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    public let permissions: [LatticeExtensionPermission]
    public let uiTargets: [String]
    public let stylePatches: [LatticeStylePatch]
    public let layoutPatches: [LatticeLayoutPatch]
    public let copyPatches: [LatticeCopyPatch]
    public let promptTemplates: [LatticePromptTemplate]
    public let skillPatches: [LatticeSkillPatch]
    public let operationPreviews: [LatticeExtensionOperationPreview]
    public let manifestURL: URL
    public let bundleURL: URL
    public let validationMessages: [String]

    public var isValid: Bool { validationMessages.isEmpty }
    public var hasStylePatches: Bool { !stylePatches.isEmpty }
    public var hasRuntimePatches: Bool { !stylePatches.isEmpty || !layoutPatches.isEmpty || !copyPatches.isEmpty || !promptTemplates.isEmpty || !skillPatches.isEmpty }

    public init(id: String, name: String, version: String, summary: String, permissions: [LatticeExtensionPermission], uiTargets: [String], stylePatches: [LatticeStylePatch] = [], layoutPatches: [LatticeLayoutPatch] = [], copyPatches: [LatticeCopyPatch] = [], promptTemplates: [LatticePromptTemplate] = [], skillPatches: [LatticeSkillPatch] = [], operationPreviews: [LatticeExtensionOperationPreview] = [], manifestURL: URL, bundleURL: URL, validationMessages: [String]) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.permissions = permissions
        self.uiTargets = uiTargets
        self.stylePatches = stylePatches
        self.layoutPatches = layoutPatches
        self.copyPatches = copyPatches
        self.promptTemplates = promptTemplates
        self.skillPatches = skillPatches
        self.operationPreviews = operationPreviews
        self.manifestURL = manifestURL
        self.bundleURL = bundleURL
        self.validationMessages = validationMessages
    }
}

public enum LatticeExtensionEnablementPolicy {
    public static func refresh(
        records: [LatticeExtensionRecord],
        storedEnabledIDs: Set<String>,
        knownIDs: Set<String>
    ) -> (enabledIDs: Set<String>, knownIDs: Set<String>) {
        let runtimeIDs = Set(records.filter { $0.isValid && $0.hasRuntimePatches }.map(\.id))
        let firstSeenRuntimeIDs = runtimeIDs.subtracting(knownIDs)
        let enabledIDs = storedEnabledIDs
            .intersection(runtimeIDs)
            .union(firstSeenRuntimeIDs)
        let refreshedKnownIDs = knownIDs.union(firstSeenRuntimeIDs)
        return (enabledIDs, refreshedKnownIDs)
    }
}

public enum LatticeExtensionJobStatus: String, Codable, Hashable, Sendable {
    case recorded
    case applied
    case reverted
    case failed
}

public struct LatticeExtensionDeletionBaseline: Hashable, Sendable {
    public let previousSkillSnapshots: [LatticeSkillSnapshot]
    public let previousDisabledSkillIDs: [String]?

    public init(previousSkillSnapshots: [LatticeSkillSnapshot], previousDisabledSkillIDs: [String]?) {
        self.previousSkillSnapshots = previousSkillSnapshots
        self.previousDisabledSkillIDs = previousDisabledSkillIDs
    }
}

public enum LatticeExtensionDeletionRollbackPolicy {
    public static func baseline(
        manifestID: String,
        currentManifestData: Data?,
        jobs: [LatticeExtensionJobRecord]
    ) -> LatticeExtensionDeletionBaseline? {
        guard let currentManifestData else { return nil }
        return jobs
            .filter { job in
                job.manifestID == manifestID
                    && job.status == .applied
                    && job.appliedManifestData == currentManifestData
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
            .map {
                .init(
                    previousSkillSnapshots: $0.previousSkillSnapshots,
                    previousDisabledSkillIDs: $0.previousDisabledSkillIDs
                )
            }
    }
}

public struct LatticeExtensionJobRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID?
    public let harnessThreadID: String?
    public let request: String
    public let manifestID: String
    public let manifestName: String
    public let summary: String
    public let previousManifestData: Data?
    public let previousSkillSnapshots: [LatticeSkillSnapshot]
    public let previousDisabledSkillIDs: [String]?
    public let previousEnabled: Bool?
    public let appliedManifestData: Data?
    public let appliedSkillSnapshots: [LatticeSkillSnapshot]
    public let appliedEnabled: Bool?
    public let createdAt: Date
    public var status: LatticeExtensionJobStatus
    public var statusDetail: String?

    public init(
        id: UUID = UUID(),
        sessionID: UUID?,
        harnessThreadID: String?,
        request: String,
        manifestID: String,
        manifestName: String,
        summary: String,
        previousManifestData: Data?,
        previousSkillSnapshots: [LatticeSkillSnapshot] = [],
        previousDisabledSkillIDs: [String]? = nil,
        previousEnabled: Bool? = nil,
        appliedManifestData: Data? = nil,
        appliedSkillSnapshots: [LatticeSkillSnapshot] = [],
        appliedEnabled: Bool? = nil,
        createdAt: Date = .now,
        status: LatticeExtensionJobStatus = .applied,
        statusDetail: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.harnessThreadID = harnessThreadID
        self.request = request
        self.manifestID = manifestID
        self.manifestName = manifestName
        self.summary = summary
        self.previousManifestData = previousManifestData
        self.previousSkillSnapshots = previousSkillSnapshots
        self.previousDisabledSkillIDs = previousDisabledSkillIDs
        self.previousEnabled = previousEnabled
        self.appliedManifestData = appliedManifestData
        self.appliedSkillSnapshots = appliedSkillSnapshots
        self.appliedEnabled = appliedEnabled
        self.createdAt = createdAt
        self.status = status
        self.statusDetail = statusDetail
    }

    public var canRollback: Bool { status == .applied || status == .recorded }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, harnessThreadID, request, manifestID, manifestName, summary, previousManifestData, previousSkillSnapshots, previousDisabledSkillIDs, previousEnabled, appliedManifestData, appliedSkillSnapshots, appliedEnabled, createdAt, status, statusDetail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        harnessThreadID = try container.decodeIfPresent(String.self, forKey: .harnessThreadID)
        request = try container.decode(String.self, forKey: .request)
        manifestID = try container.decode(String.self, forKey: .manifestID)
        manifestName = try container.decode(String.self, forKey: .manifestName)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        previousManifestData = try container.decodeIfPresent(Data.self, forKey: .previousManifestData)
        previousSkillSnapshots = try container.decodeIfPresent([LatticeSkillSnapshot].self, forKey: .previousSkillSnapshots) ?? []
        previousDisabledSkillIDs = try container.decodeIfPresent([String].self, forKey: .previousDisabledSkillIDs)
        previousEnabled = try container.decodeIfPresent(Bool.self, forKey: .previousEnabled)
        appliedManifestData = try container.decodeIfPresent(Data.self, forKey: .appliedManifestData)
        appliedSkillSnapshots = try container.decodeIfPresent([LatticeSkillSnapshot].self, forKey: .appliedSkillSnapshots) ?? []
        appliedEnabled = try container.decodeIfPresent(Bool.self, forKey: .appliedEnabled)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        status = try container.decodeIfPresent(LatticeExtensionJobStatus.self, forKey: .status) ?? .applied
        statusDetail = try container.decodeIfPresent(String.self, forKey: .statusDetail)
    }
}

public struct LatticeExtensionPreviewRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let harnessThreadID: String?
    public let request: String
    public let manifest: LatticeExtensionManifest
    public let previousManifestData: Data?
    public let previousSkillSnapshots: [LatticeSkillSnapshot]
    public let previousDisabledSkillIDs: [String]?
    public let previousEnabled: Bool?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        harnessThreadID: String?,
        request: String,
        manifest: LatticeExtensionManifest,
        previousManifestData: Data?,
        previousSkillSnapshots: [LatticeSkillSnapshot] = [],
        previousDisabledSkillIDs: [String]? = nil,
        previousEnabled: Bool? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.harnessThreadID = harnessThreadID
        self.request = request
        self.manifest = manifest
        self.previousManifestData = previousManifestData
        self.previousSkillSnapshots = previousSkillSnapshots
        self.previousDisabledSkillIDs = previousDisabledSkillIDs
        self.previousEnabled = previousEnabled
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, harnessThreadID, request, manifest, previousManifestData, previousSkillSnapshots, previousDisabledSkillIDs, previousEnabled, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        harnessThreadID = try container.decodeIfPresent(String.self, forKey: .harnessThreadID)
        request = try container.decode(String.self, forKey: .request)
        manifest = try container.decode(LatticeExtensionManifest.self, forKey: .manifest)
        previousManifestData = try container.decodeIfPresent(Data.self, forKey: .previousManifestData)
        previousSkillSnapshots = try container.decodeIfPresent([LatticeSkillSnapshot].self, forKey: .previousSkillSnapshots) ?? []
        previousDisabledSkillIDs = try container.decodeIfPresent([String].self, forKey: .previousDisabledSkillIDs)
        previousEnabled = try container.decodeIfPresent(Bool.self, forKey: .previousEnabled)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
}

public enum LatticeExtensionManifestEnvelope {
    public static let openingTag = "<lattice-extension-manifest>"
    public static let closingTag = "</lattice-extension-manifest>"

    public static func decode(from response: String) throws -> LatticeExtensionManifest {
        if response.contains(openingTag) || response.contains(closingTag) {
            return try decode(response, opening: openingTag, closing: closingTag)
        }
        // Legacy brand compatibility: accept pre-rename tagged manifests, produce only lattice tags in new prompts.
        return try decode(
            response,
            opening: LatticeLegacyBrandCompatibility.extensionManifestOpeningTag,
            closing: LatticeLegacyBrandCompatibility.extensionManifestClosingTag
        )
    }

    private static func decode(_ response: String, opening: String, closing: String) throws -> LatticeExtensionManifest {
        guard let start = response.range(of: opening),
              let end = response.range(of: closing, range: start.upperBound..<response.endIndex) else {
            throw NSError(domain: "LatticeExtensionManifestEnvelope", code: 1, userInfo: [NSLocalizedDescriptionKey: "The model did not return a Lattice modification manifest."])
        }
        let before = response[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let after = response[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard before.isEmpty, after.isEmpty else {
            throw NSError(domain: "LatticeExtensionManifestEnvelope", code: 2, userInfo: [NSLocalizedDescriptionKey: "The model returned extra text outside the Lattice modification manifest."])
        }
        let body = String(response[start.upperBound..<end.lowerBound])
        guard body.range(of: opening) == nil, body.range(of: closing) == nil else {
            throw NSError(domain: "LatticeExtensionManifestEnvelope", code: 3, userInfo: [NSLocalizedDescriptionKey: "The model returned more than one Lattice modification manifest."])
        }
        let json = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let manifest = try? JSONDecoder().decode(LatticeExtensionManifest.self, from: data) else {
            throw NSError(domain: "LatticeExtensionManifestEnvelope", code: 4, userInfo: [NSLocalizedDescriptionKey: "The model returned an invalid Lattice modification manifest."])
        }
        return manifest
    }
}

public struct LatticeExtensionStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL = Self.defaultRootURL()) {
        self.rootURL = rootURL
    }

    public static func defaultRootURL() -> URL {
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        return LatticeApplicationSupport.productRootURL().appendingPathComponent("Extensions", isDirectory: true)
    }

    public func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    public func load() -> [LatticeExtensionRecord] {
        do {
            try prepareDirectory()
            let candidates = try manifestCandidates()
            return recordsWithDuplicateIDValidation(candidates.map(loadRecord)).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            return [
                .init(
                    id: "extensions-directory",
                    name: "Extensions",
                    version: "",
                    summary: "Could not read extensions folder.",
                    permissions: [],
                    uiTargets: [],
                    stylePatches: [],
                    layoutPatches: [],
                    copyPatches: [],
                    promptTemplates: [],
                    skillPatches: [],
                    operationPreviews: [],
                    manifestURL: rootURL,
                    bundleURL: rootURL,
                    validationMessages: [error.localizedDescription]
                )
            ]
        }
    }

    private func recordsWithDuplicateIDValidation(_ records: [LatticeExtensionRecord]) -> [LatticeExtensionRecord] {
        let idCounts = Dictionary(grouping: records.filter { !$0.id.hasPrefix("invalid:") }, by: { $0.id.lowercased() })
            .mapValues(\.count)
        return records.map { record in
            guard idCounts[record.id.lowercased(), default: 0] > 1 else { return record }
            var validationMessages = record.validationMessages
            validationMessages.append("Duplicate extension id: \(record.id).")
            return .init(
                id: record.id,
                name: record.name,
                version: record.version,
                summary: record.summary,
                permissions: record.permissions,
                uiTargets: record.uiTargets,
                stylePatches: record.stylePatches,
                layoutPatches: record.layoutPatches,
                copyPatches: record.copyPatches,
                promptTemplates: record.promptTemplates,
                skillPatches: record.skillPatches,
                operationPreviews: record.operationPreviews,
                manifestURL: record.manifestURL,
                bundleURL: record.bundleURL,
                validationMessages: validationMessages
            )
        }
    }

    public func writeGeneratedExtension(_ manifest: LatticeExtensionManifest) throws -> URL {
        let validation = validate(manifest)
        guard validation.isEmpty else {
            throw NSError(domain: "LatticeExtensionStore", code: 1, userInfo: [NSLocalizedDescriptionKey: validation.joined(separator: " ")])
        }
        try prepareDirectory()
        let bundleURL = rootURL.appendingPathComponent(manifest.id, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifestURL = bundleURL.appendingPathComponent("lattice-extension.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    public func manifestData(for manifestID: String) -> Data? {
        guard Self.isSafeManifestID(manifestID) else { return nil }
        let bundle = rootURL.appendingPathComponent(manifestID, isDirectory: true)
        if let existing = firstExistingManifest(in: bundle) {
            return try? Data(contentsOf: existing)
        }
        return try? Data(contentsOf: manifestURL(for: manifestID))
    }

    public func restoreExtension(manifestID: String, previousManifestData: Data?) throws {
        guard Self.isSafeManifestID(manifestID) else {
            throw NSError(domain: "LatticeExtensionStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid extension id."])
        }
        if let previousManifestData {
            let manifest = try JSONDecoder().decode(LatticeExtensionManifest.self, from: previousManifestData)
            guard manifest.id == manifestID else {
                throw NSError(domain: "LatticeExtensionStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "Rollback manifest id does not match the target extension."])
            }
            let validation = validate(manifest)
            guard validation.isEmpty else {
                throw NSError(domain: "LatticeExtensionStore", code: 3, userInfo: [NSLocalizedDescriptionKey: validation.joined(separator: " ")])
            }
            let bundleURL = rootURL.appendingPathComponent(manifestID, isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try previousManifestData.write(to: bundleURL.appendingPathComponent("lattice-extension.json"), options: .atomic)
        } else {
            let bundleURL = rootURL.appendingPathComponent(manifestID, isDirectory: true)
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                try FileManager.default.removeItem(at: bundleURL)
            }
        }
    }

    private func manifestCandidates() throws -> [(manifest: URL, bundle: URL)] {
        let children = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var results: [(URL, URL)] = []
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                if let manifest = firstExistingManifest(in: child) {
                    results.append((manifest, child))
                }
            } else if child.lastPathComponent.hasSuffix(".latticeextension.json")
                        || child.lastPathComponent == "lattice-extension.json"
                        || child.lastPathComponent.hasSuffix(LatticeLegacyBrandCompatibility.extensionManifestSuffix)
                        || child.lastPathComponent == LatticeLegacyBrandCompatibility.extensionManifestFileName {
                results.append((child, child.deletingLastPathComponent()))
            }
        }
        return results
    }

    private func firstExistingManifest(in bundle: URL) -> URL? {
        let primary = bundle.appendingPathComponent("lattice-extension.json")
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        let legacy = bundle.appendingPathComponent(LatticeLegacyBrandCompatibility.extensionManifestFileName)
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return nil
    }

    private func loadRecord(manifestURL: URL, bundleURL: URL) -> LatticeExtensionRecord {
        do {
            let manifest = try JSONDecoder().decode(LatticeExtensionManifest.self, from: Data(contentsOf: manifestURL))
            return .init(
                id: manifest.id,
                name: manifest.name,
                version: manifest.version,
                summary: manifest.summary,
                permissions: manifest.permissions,
                uiTargets: manifest.uiTargets,
                stylePatches: manifest.stylePatches,
                layoutPatches: manifest.layoutPatches,
                copyPatches: manifest.copyPatches,
                promptTemplates: manifest.promptTemplates,
                skillPatches: manifest.skillPatches,
                operationPreviews: manifest.operationPreviews,
                manifestURL: manifestURL,
                bundleURL: bundleURL,
                validationMessages: validate(manifest)
            )
        } catch {
            return .init(
                id: "invalid:\(manifestURL.lastPathComponent)",
                name: manifestURL.deletingPathExtension().lastPathComponent,
                version: "",
                summary: "Manifest could not be decoded.",
                permissions: [],
                uiTargets: [],
                stylePatches: [],
                layoutPatches: [],
                copyPatches: [],
                promptTemplates: [],
                skillPatches: [],
                operationPreviews: [],
                manifestURL: manifestURL,
                bundleURL: bundleURL,
                validationMessages: [error.localizedDescription]
            )
        }
    }

    public func validate(_ manifest: LatticeExtensionManifest) -> [String] {
        var messages: [String] = []
        if manifest.schemaVersion != 1 { messages.append("Unsupported schema version.") }
        if manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messages.append("Missing id.") }
        let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            messages.append("Missing name.")
        } else {
            if name != manifest.name { messages.append("Name must not have leading or trailing whitespace.") }
            if manifest.name.contains(where: \.isNewline) { messages.append("Name must be one line.") }
            if manifest.name.count > 80 { messages.append("Name must be 80 characters or fewer.") }
        }
        let version = manifest.version.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.isEmpty {
            messages.append("Missing version.")
        } else {
            if version != manifest.version { messages.append("Version must not have leading or trailing whitespace.") }
            if manifest.version.contains(where: \.isNewline) { messages.append("Version must be one line.") }
            if manifest.version.count > 40 { messages.append("Version must be 40 characters or fewer.") }
        }
        if !manifest.summary.isEmpty {
            let summary = manifest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty {
                messages.append("Summary is empty.")
            } else {
                if summary != manifest.summary { messages.append("Summary must not have leading or trailing whitespace.") }
                if manifest.summary.contains(where: \.isNewline) { messages.append("Summary must be one line.") }
                if manifest.summary.count > 180 { messages.append("Summary must be 180 characters or fewer.") }
            }
        }
        if !Self.isSafeManifestID(manifest.id) { messages.append("Id may only contain letters, numbers, dots, underscores, and hyphens.") }
        if manifest.id != manifest.id.lowercased() { messages.append("Id must be lowercase.") }
        if let entrypoint = manifest.entrypoint, !entrypoint.isEmpty {
            let trimmed = entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                messages.append("Entrypoint is empty.")
            } else {
                if trimmed != entrypoint {
                    messages.append("Entrypoint must not have leading or trailing whitespace.")
                }
                if entrypoint.contains(where: \.isNewline) {
                    messages.append("Entrypoint must be one line.")
                }
                if trimmed.hasPrefix("/") || trimmed.contains("..") {
                    messages.append("Entrypoint must stay inside the extension bundle.")
                }
            }
        }
        if manifest.permissions.contains(.writeWorkspace), !manifest.permissions.contains(.readWorkspace) {
            messages.append("Write workspace requires read workspace.")
        }
        if !manifest.stylePatches.isEmpty, !manifest.permissions.contains(.editUI) {
            messages.append("Style patches require Edit UI permission.")
        }
        if !manifest.layoutPatches.isEmpty, !manifest.permissions.contains(.editUI) {
            messages.append("Layout patches require Edit UI permission.")
        }
        if !manifest.copyPatches.isEmpty, !manifest.permissions.contains(.editUI) {
            messages.append("Copy patches require Edit UI permission.")
        }
        if !manifest.promptTemplates.isEmpty, !manifest.permissions.contains(.editUI) {
            messages.append("Prompt templates require Edit UI permission.")
        }
        if !manifest.skillPatches.isEmpty, !manifest.permissions.contains(.editUI) {
            messages.append("Skill patches require Edit UI permission.")
        }
        if manifest.stylePatches.count > 12 {
            messages.append("Too many style patches.")
        }
        if manifest.layoutPatches.count > 12 {
            messages.append("Too many layout patches.")
        }
        if manifest.copyPatches.count > 12 {
            messages.append("Too many copy patches.")
        }
        if manifest.promptTemplates.count > 12 {
            messages.append("Too many prompt templates.")
        }
        if manifest.skillPatches.count > 12 {
            messages.append("Too many skill patches.")
        }
        if manifest.operationPreviews.count > 12 {
            messages.append("Too many operation previews.")
        }
        let surfacesByID = Dictionary(uniqueKeysWithValues: LatticeSelfMap.defaultSurfaces.map { ($0.id, $0) })
        var styleTargets = Set<String>()
        for patch in manifest.stylePatches {
            let key = patch.target.rawValue
            if !styleTargets.insert(key).inserted {
                messages.append("Duplicate style patch target: \(key).")
            }
        }
        var layoutPatchTargets = Set<String>()
        for patch in manifest.layoutPatches {
            let key = patch.target.rawValue
            if !layoutPatchTargets.insert(key).inserted {
                messages.append("Duplicate layout patch target: \(key).")
            }
        }
        var copyTargets = Set<String>()
        for patch in manifest.copyPatches {
            let key = patch.target.rawValue
            if !copyTargets.insert(key).inserted {
                messages.append("Duplicate copy patch target: \(key).")
            }
        }
        var uiTargets = Set<String>()
        for target in manifest.uiTargets {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                messages.append("UI target is empty.")
                continue
            }
            if trimmed != target {
                messages.append("UI target \(target) must not have leading or trailing whitespace.")
            }
            if surfacesByID[trimmed] == nil {
                messages.append("Unknown UI target: \(target).")
            }
            if !uiTargets.insert(trimmed).inserted {
                messages.append("Duplicate UI target: \(trimmed).")
            }
        }
        var operationPreviewKeys = Set<String>()
        for preview in manifest.operationPreviews {
            for permission in Self.requiredPermissions(for: preview.operation)
            where !manifest.permissions.contains(permission) {
                messages.append("\(preview.operation.displayName) operation previews require \(permission.displayName) permission.")
            }
            let target = preview.targetSurfaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if target.isEmpty {
                messages.append("Operation preview is missing target surface.")
                continue
            }
            if target != preview.targetSurfaceID {
                messages.append("Operation preview target \(preview.targetSurfaceID) must not have leading or trailing whitespace.")
            }
            if preview.targetSurfaceID.contains(where: \.isNewline) {
                messages.append("Operation preview target must be one line.")
            }
            let operationPreviewKey = "\(target)#\(preview.operation.rawValue)"
            if !operationPreviewKeys.insert(operationPreviewKey).inserted {
                messages.append("Duplicate operation preview for \(target) \(preview.operation.displayName).")
            }
            guard let surface = surfacesByID[target] else {
                messages.append("Unknown operation preview surface: \(preview.targetSurfaceID).")
                continue
            }
            if !surface.operations.contains(preview.operation) {
                messages.append("\(preview.operation.displayName) is not supported on \(surface.name).")
            }
            let summary = preview.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty {
                messages.append("Operation preview for \(surface.name) is missing a summary.")
            }
            if summary != preview.summary {
                messages.append("Operation preview summary for \(surface.name) must not have leading or trailing whitespace.")
            }
            if preview.summary.contains(where: \.isNewline) {
                messages.append("Operation preview summary for \(surface.name) must be one line.")
            }
            if preview.summary.count > 180 {
                messages.append("Operation preview summary for \(surface.name) is too long.")
            }
            if !preview.detail.isEmpty {
                let detail = preview.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    messages.append("Operation preview detail for \(surface.name) is empty.")
                }
                if detail != preview.detail {
                    messages.append("Operation preview detail for \(surface.name) must not have leading or trailing whitespace.")
                }
                if preview.detail.contains(where: \.isNewline) {
                    messages.append("Operation preview detail for \(surface.name) must be one line.")
                }
            }
            if preview.detail.count > 600 {
                messages.append("Operation preview detail for \(surface.name) is too long.")
            }
        }
        for patch in manifest.stylePatches {
            if let tint = patch.tintHex, !Self.isValidHexColor(tint) { messages.append("Invalid tint color for \(patch.target.rawValue).") }
            if let accent = patch.accentHex, !Self.isValidHexColor(accent) { messages.append("Invalid accent color for \(patch.target.rawValue).") }
            if let radius = patch.cornerRadius, radius < 6 || radius > 40 { messages.append("Corner radius for \(patch.target.rawValue) must be 6...40.") }
        }
        let layoutTargets = Set(manifest.uiTargets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        for patch in manifest.layoutPatches {
            if patch.target == .composer, !layoutTargets.isEmpty, !layoutTargets.contains("composer") {
                messages.append("Composer layout patches require composer in uiTargets.")
            }
        }
        for patch in manifest.copyPatches {
            let trimmed = patch.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                messages.append("Copy patch for \(patch.target.displayName) is empty.")
            }
            if trimmed != patch.text {
                messages.append("Copy patch for \(patch.target.displayName) must not have leading or trailing whitespace.")
            }
            if patch.text.contains(where: \.isNewline) {
                messages.append("Copy patch for \(patch.target.displayName) must be one line.")
            }
            if patch.text.count > 80 {
                messages.append("Copy patch for \(patch.target.displayName) must be 80 characters or fewer.")
            }
        }
        var templateInvocations = Set<String>()
        for template in manifest.promptTemplates {
            let invocation = template.invocation.trimmingCharacters(in: .whitespacesAndNewlines)
            if invocation != template.invocation {
                messages.append("Prompt template invocation must not have leading or trailing whitespace.")
            }
            if !invocation.hasPrefix("/") || invocation.count < 2 {
                messages.append("Prompt template invocation must start with slash.")
            }
            if invocation == LatticeSelfEditCommand.name {
                messages.append("Prompt templates cannot replace /self-edit.")
            }
            let token = invocation.dropFirst()
            if token.isEmpty || token.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
                messages.append("Prompt template invocation may only contain letters, numbers, hyphens, and underscores after slash.")
            }
            if !templateInvocations.insert(invocation.lowercased()).inserted {
                messages.append("Duplicate prompt template invocation: \(invocation).")
            }
            let title = template.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                messages.append("Prompt template \(invocation) is missing a title.")
            }
            if title != template.title {
                messages.append("Prompt template \(invocation) title must not have leading or trailing whitespace.")
            }
            if template.title.contains(where: \.isNewline) {
                messages.append("Prompt template \(invocation) title must be one line.")
            }
            if template.title.count > 60 {
                messages.append("Prompt template \(invocation) title must be 60 characters or fewer.")
            }
            if !template.detail.isEmpty {
                let detail = template.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    messages.append("Prompt template \(invocation) detail is empty.")
                }
                if detail != template.detail {
                    messages.append("Prompt template \(invocation) detail must not have leading or trailing whitespace.")
                }
                if template.detail.contains(where: \.isNewline) {
                    messages.append("Prompt template \(invocation) detail must be one line.")
                }
            }
            if template.detail.count > 120 {
                messages.append("Prompt template \(invocation) detail must be 120 characters or fewer.")
            }
            let prompt = template.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.isEmpty {
                messages.append("Prompt template \(invocation) prompt is empty.")
            }
            if prompt.count > 1_000 {
                messages.append("Prompt template \(invocation) prompt must be 1000 characters or fewer.")
            }
        }
        var skillIDs = Set<String>()
        for skill in manifest.skillPatches {
            for message in LatticeSkillStore.validate(skill) {
                messages.append("Skill \(skill.id): \(message)")
            }
            let skillInvocation = "/\(skill.id)".lowercased()
            if templateInvocations.contains(skillInvocation) {
                messages.append("Skill \(skill.id) conflicts with prompt template \(skillInvocation).")
            }
            if !skillIDs.insert(skill.id.lowercased()).inserted {
                messages.append("Duplicate skill patch id: \(skill.id).")
            }
        }
        return messages
    }

    private func manifestURL(for manifestID: String) -> URL {
        rootURL
            .appendingPathComponent(manifestID, isDirectory: true)
            .appendingPathComponent("lattice-extension.json")
    }

    private static func isSafeManifestID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == id else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return trimmed.rangeOfCharacter(from: allowed.inverted) == nil
    }

    private static func requiredPermissions(for operation: LatticeEditableOperation) -> [LatticeExtensionPermission] {
        switch operation {
        case .restyle, .relayout, .rewriteCopy, .addControl, .addModelRecommendation, .addHarnessRoute, .addSkill:
            return [.editUI]
        case .addAutomation:
            return [.editUI, .automation]
        }
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard [6, 8].contains(hex.count) else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }
}

public struct LatticeExtensionJobStore: Sendable {
    public static let storeID = "self-edit-jobs"
    public static let storeName = "Self-edit history"
    public static let fileName = "self-edit-jobs.json"

    public let fileURL: URL
    public let writeGate: DurableStoreWriteGate
    public let io: DurableStoreFileIO

    public init(
        fileURL: URL? = nil,
        writeGate: DurableStoreWriteGate = DurableStoreWriteGate(),
        io: DurableStoreFileIO = .default
    ) {
        self.writeGate = writeGate
        self.io = io
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        self.fileURL = LatticeApplicationSupport.productRootURL().appendingPathComponent(Self.fileName)
    }

    /// Classifying load: missing vs loaded vs failed. Prefer this over `load()` at app startup.
    public func loadResult() -> DurableStoreLoadResult<[LatticeExtensionJobRecord]> {
        switch DurableStoreRecovery.loadJSONArray(
            from: fileURL,
            as: LatticeExtensionJobRecord.self,
            storeID: Self.storeID,
            storeName: Self.storeName,
            io: io
        ) {
        case .missing:
            return .missing
        case .failed(let issue):
            return .failed(issue)
        case .loaded(let records):
            return .loaded(records.sorted { $0.createdAt > $1.createdAt })
        }
    }

    /// Convenience loader. Missing/failed both yield `[]` for API stability; recovery must use `loadResult()`.
    public func load() -> [LatticeExtensionJobRecord] {
        switch loadResult() {
        case .missing, .failed:
            return []
        case .loaded(let records):
            return records
        }
    }

    public func save(_ records: [LatticeExtensionJobRecord]) throws {
        try DurableStoreRecovery.enforceWritable(gate: writeGate, storeName: Self.storeName)
        try io.createDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try io.writeDataAtomically(encoder.encode(records.sorted { $0.createdAt > $1.createdAt }), fileURL)
    }

    public func record(_ record: LatticeExtensionJobRecord, in records: [LatticeExtensionJobRecord]) throws -> [LatticeExtensionJobRecord] {
        var updated = records
        updated.removeAll { $0.id == record.id }
        updated.insert(record, at: 0)
        try save(updated)
        return load()
    }

    public func markReverted(_ id: UUID, detail: String?, in records: [LatticeExtensionJobRecord]) throws -> [LatticeExtensionJobRecord] {
        var updated = records
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return records }
        updated[index].status = .reverted
        updated[index].statusDetail = detail
        try save(updated)
        return load()
    }
}

public enum LatticeExtensionPreviewEditor {
    private static func replacingManifest(
        in preview: LatticeExtensionPreviewRecord,
        with manifest: LatticeExtensionManifest
    ) -> LatticeExtensionPreviewRecord {
        LatticeExtensionPreviewRecord(
            id: preview.id,
            sessionID: preview.sessionID,
            harnessThreadID: preview.harnessThreadID,
            request: preview.request,
            manifest: manifest,
            previousManifestData: preview.previousManifestData,
            previousSkillSnapshots: preview.previousSkillSnapshots,
            previousDisabledSkillIDs: preview.previousDisabledSkillIDs,
            previousEnabled: preview.previousEnabled,
            createdAt: preview.createdAt
        )
    }

    public static func replacingMetadata(
        in preview: LatticeExtensionPreviewRecord,
        name: String,
        version: String,
        summary: String
    ) -> LatticeExtensionPreviewRecord {
        let manifest = LatticeExtensionManifest(
            schemaVersion: preview.manifest.schemaVersion,
            id: preview.manifest.id,
            name: name,
            version: version,
            summary: summary,
            permissions: preview.manifest.permissions,
            entrypoint: preview.manifest.entrypoint,
            uiTargets: preview.manifest.uiTargets,
            stylePatches: preview.manifest.stylePatches,
            layoutPatches: preview.manifest.layoutPatches,
            copyPatches: preview.manifest.copyPatches,
            promptTemplates: preview.manifest.promptTemplates,
            skillPatches: preview.manifest.skillPatches,
            operationPreviews: preview.manifest.operationPreviews
        )
        return replacingManifest(in: preview, with: manifest)
    }

    public static func replacingStylePatch(
        in preview: LatticeExtensionPreviewRecord,
        index: Int,
        tintHex: String?,
        accentHex: String?,
        cornerRadius: Double?
    ) throws -> LatticeExtensionPreviewRecord {
        guard preview.manifest.stylePatches.indices.contains(index) else {
            throw NSError(domain: "LatticeExtensionPreviewEditor", code: 5, userInfo: [NSLocalizedDescriptionKey: "The style preview no longer exists."])
        }
        var updatedPatches = preview.manifest.stylePatches
        let existing = updatedPatches[index]
        updatedPatches[index] = .init(
            target: existing.target,
            tintHex: tintHex,
            accentHex: accentHex,
            cornerRadius: cornerRadius
        )
        let manifest = LatticeExtensionManifest(
            schemaVersion: preview.manifest.schemaVersion,
            id: preview.manifest.id,
            name: preview.manifest.name,
            version: preview.manifest.version,
            summary: preview.manifest.summary,
            permissions: preview.manifest.permissions,
            entrypoint: preview.manifest.entrypoint,
            uiTargets: preview.manifest.uiTargets,
            stylePatches: updatedPatches,
            layoutPatches: preview.manifest.layoutPatches,
            copyPatches: preview.manifest.copyPatches,
            promptTemplates: preview.manifest.promptTemplates,
            skillPatches: preview.manifest.skillPatches,
            operationPreviews: preview.manifest.operationPreviews
        )
        return replacingManifest(in: preview, with: manifest)
    }

    public static func replacingLayoutPatch(
        in preview: LatticeExtensionPreviewRecord,
        index: Int,
        density: LatticeLayoutDensity
    ) throws -> LatticeExtensionPreviewRecord {
        guard preview.manifest.layoutPatches.indices.contains(index) else {
            throw NSError(domain: "LatticeExtensionPreviewEditor", code: 6, userInfo: [NSLocalizedDescriptionKey: "The layout preview no longer exists."])
        }
        var updatedPatches = preview.manifest.layoutPatches
        let existing = updatedPatches[index]
        updatedPatches[index] = .init(target: existing.target, density: density)
        let manifest = LatticeExtensionManifest(
            schemaVersion: preview.manifest.schemaVersion,
            id: preview.manifest.id,
            name: preview.manifest.name,
            version: preview.manifest.version,
            summary: preview.manifest.summary,
            permissions: preview.manifest.permissions,
            entrypoint: preview.manifest.entrypoint,
            uiTargets: preview.manifest.uiTargets,
            stylePatches: preview.manifest.stylePatches,
            layoutPatches: updatedPatches,
            copyPatches: preview.manifest.copyPatches,
            promptTemplates: preview.manifest.promptTemplates,
            skillPatches: preview.manifest.skillPatches,
            operationPreviews: preview.manifest.operationPreviews
        )
        return replacingManifest(in: preview, with: manifest)
    }

    public static func replacingCopyPatch(
        in preview: LatticeExtensionPreviewRecord,
        target: LatticeCopyTarget,
        text: String
    ) throws -> LatticeExtensionPreviewRecord {
        guard preview.manifest.copyPatches.contains(where: { $0.target == target }) else {
            throw NSError(domain: "LatticeExtensionPreviewEditor", code: 2, userInfo: [NSLocalizedDescriptionKey: "The copy preview no longer exists."])
        }
        let updatedPatches = preview.manifest.copyPatches.map { patch in
            patch.target == target ? LatticeCopyPatch(target: target, text: text) : patch
        }
        let manifest = LatticeExtensionManifest(
            schemaVersion: preview.manifest.schemaVersion,
            id: preview.manifest.id,
            name: preview.manifest.name,
            version: preview.manifest.version,
            summary: preview.manifest.summary,
            permissions: preview.manifest.permissions,
            entrypoint: preview.manifest.entrypoint,
            uiTargets: preview.manifest.uiTargets,
            stylePatches: preview.manifest.stylePatches,
            layoutPatches: preview.manifest.layoutPatches,
            copyPatches: updatedPatches,
            promptTemplates: preview.manifest.promptTemplates,
            skillPatches: preview.manifest.skillPatches,
            operationPreviews: preview.manifest.operationPreviews
        )
        return replacingManifest(in: preview, with: manifest)
    }

    public static func replacingPromptTemplate(
        in preview: LatticeExtensionPreviewRecord,
        originalInvocation: String,
        invocation: String,
        title: String,
        detail: String,
        prompt: String
    ) throws -> LatticeExtensionPreviewRecord {
        guard preview.manifest.promptTemplates.contains(where: { $0.invocation == originalInvocation }) else {
            throw NSError(domain: "LatticeExtensionPreviewEditor", code: 3, userInfo: [NSLocalizedDescriptionKey: "The prompt template preview no longer exists."])
        }
        let updatedTemplate = LatticePromptTemplate(invocation: invocation, title: title, detail: detail, prompt: prompt)
        let updatedTemplates = preview.manifest.promptTemplates.map { template in
            template.invocation == originalInvocation ? updatedTemplate : template
        }
        let manifest = LatticeExtensionManifest(
            schemaVersion: preview.manifest.schemaVersion,
            id: preview.manifest.id,
            name: preview.manifest.name,
            version: preview.manifest.version,
            summary: preview.manifest.summary,
            permissions: preview.manifest.permissions,
            entrypoint: preview.manifest.entrypoint,
            uiTargets: preview.manifest.uiTargets,
            stylePatches: preview.manifest.stylePatches,
            layoutPatches: preview.manifest.layoutPatches,
            copyPatches: preview.manifest.copyPatches,
            promptTemplates: updatedTemplates,
            skillPatches: preview.manifest.skillPatches,
            operationPreviews: preview.manifest.operationPreviews
        )
        return replacingManifest(in: preview, with: manifest)
    }

    public static func replacingOperationPreview(
        in preview: LatticeExtensionPreviewRecord,
        index: Int,
        summary: String,
        detail: String
    ) throws -> LatticeExtensionPreviewRecord {
        guard preview.manifest.operationPreviews.indices.contains(index) else {
            throw NSError(domain: "LatticeExtensionPreviewEditor", code: 4, userInfo: [NSLocalizedDescriptionKey: "The operation preview no longer exists."])
        }
        var updatedOperations = preview.manifest.operationPreviews
        let existing = updatedOperations[index]
        updatedOperations[index] = .init(
            targetSurfaceID: existing.targetSurfaceID,
            operation: existing.operation,
            summary: summary,
            detail: detail
        )
        let manifest = LatticeExtensionManifest(
            schemaVersion: preview.manifest.schemaVersion,
            id: preview.manifest.id,
            name: preview.manifest.name,
            version: preview.manifest.version,
            summary: preview.manifest.summary,
            permissions: preview.manifest.permissions,
            entrypoint: preview.manifest.entrypoint,
            uiTargets: preview.manifest.uiTargets,
            stylePatches: preview.manifest.stylePatches,
            layoutPatches: preview.manifest.layoutPatches,
            copyPatches: preview.manifest.copyPatches,
            promptTemplates: preview.manifest.promptTemplates,
            skillPatches: preview.manifest.skillPatches,
            operationPreviews: updatedOperations
        )
        return replacingManifest(in: preview, with: manifest)
    }

    public static func replacingSkillPatch(
        in preview: LatticeExtensionPreviewRecord,
        skillID: String,
        title: String,
        summary: String,
        markdown: String
    ) throws -> LatticeExtensionPreviewRecord {
        guard preview.manifest.skillPatches.contains(where: { $0.id == skillID }) else {
            throw NSError(domain: "LatticeExtensionPreviewEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: "The skill preview no longer exists."])
        }
        let updatedSkill = LatticeSkillPatch(id: skillID, title: title, summary: summary, markdown: markdown)
        let updatedSkills = preview.manifest.skillPatches.map { skill in
            skill.id == skillID ? updatedSkill : skill
        }
        let manifest = LatticeExtensionManifest(
            schemaVersion: preview.manifest.schemaVersion,
            id: preview.manifest.id,
            name: preview.manifest.name,
            version: preview.manifest.version,
            summary: preview.manifest.summary,
            permissions: preview.manifest.permissions,
            entrypoint: preview.manifest.entrypoint,
            uiTargets: preview.manifest.uiTargets,
            stylePatches: preview.manifest.stylePatches,
            layoutPatches: preview.manifest.layoutPatches,
            copyPatches: preview.manifest.copyPatches,
            promptTemplates: preview.manifest.promptTemplates,
            skillPatches: updatedSkills,
            operationPreviews: preview.manifest.operationPreviews
        )
        return replacingManifest(in: preview, with: manifest)
    }
}

public struct LatticeExtensionPreviewStore: Sendable {
    public static let storeID = "self-edit-previews"
    public static let storeName = "Self-edit previews"
    public static let fileName = "self-edit-previews.json"

    public let fileURL: URL
    public let writeGate: DurableStoreWriteGate
    public let io: DurableStoreFileIO

    public init(
        fileURL: URL? = nil,
        writeGate: DurableStoreWriteGate = DurableStoreWriteGate(),
        io: DurableStoreFileIO = .default
    ) {
        self.writeGate = writeGate
        self.io = io
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        self.fileURL = LatticeApplicationSupport.productRootURL().appendingPathComponent(Self.fileName)
    }

    /// Classifying load: missing vs loaded vs failed. Prefer this over `load()` at app startup.
    public func loadResult() -> DurableStoreLoadResult<[LatticeExtensionPreviewRecord]> {
        switch DurableStoreRecovery.loadJSONArray(
            from: fileURL,
            as: LatticeExtensionPreviewRecord.self,
            storeID: Self.storeID,
            storeName: Self.storeName,
            io: io
        ) {
        case .missing:
            return .missing
        case .failed(let issue):
            return .failed(issue)
        case .loaded(let records):
            return .loaded(records.sorted { $0.createdAt > $1.createdAt })
        }
    }

    /// Convenience loader. Missing/failed both yield `[]` for API stability; recovery must use `loadResult()`.
    public func load() -> [LatticeExtensionPreviewRecord] {
        switch loadResult() {
        case .missing, .failed:
            return []
        case .loaded(let records):
            return records
        }
    }

    public func save(_ records: [LatticeExtensionPreviewRecord]) throws {
        try DurableStoreRecovery.enforceWritable(gate: writeGate, storeName: Self.storeName)
        try io.createDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try io.writeDataAtomically(encoder.encode(records.sorted { $0.createdAt > $1.createdAt }), fileURL)
    }

    public func record(_ record: LatticeExtensionPreviewRecord, in records: [LatticeExtensionPreviewRecord]) throws -> [LatticeExtensionPreviewRecord] {
        var updated = records
        updated.removeAll { $0.id == record.id || $0.sessionID == record.sessionID }
        updated.insert(record, at: 0)
        try save(updated)
        return load()
    }

    public func remove(_ id: UUID, from records: [LatticeExtensionPreviewRecord]) throws -> [LatticeExtensionPreviewRecord] {
        var updated = records
        updated.removeAll { $0.id == id }
        try save(updated)
        return load()
    }

    public func removePreviews(for sessionID: UUID, from records: [LatticeExtensionPreviewRecord]) throws -> [LatticeExtensionPreviewRecord] {
        var updated = records
        updated.removeAll { $0.sessionID == sessionID }
        try save(updated)
        return load()
    }
}
