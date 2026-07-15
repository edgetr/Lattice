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
