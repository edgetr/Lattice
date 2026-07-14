import Foundation

/// Versioned, non-enforcing context passed to Lattice's explicit Pi extension.
///
/// Tool permissions, workspace write containment, approval behavior, and trust
/// flags remain launch-time controls. Values in this envelope are system-level
/// guidance and facts only; user prompt text never changes enforcement.
public struct LatticeInstructionEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumUserAddOnBytes = 8 * 1024
    public static let latticeIdentity = "Lattice, native macOS control plane for AI coding agents"
    public static let documentedWorkspaceInstructionNames = ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]

    public let version: Int
    public let identity: String
    public let selectedMode: ConversationMode
    public let workspaceFacts: [String]
    public let controlFacts: [String]
    public let capabilityFacts: [String]
    public let workspaceInstructionsTrusted: Bool
    public let trustedWorkspaceInstructionNames: [String]
    public let latticeInstructions: String
    public let codeUserAddOn: String
    public let workUserAddOn: String

    private enum CodingKeys: String, CodingKey {
        case version, identity, selectedMode, workspaceFacts, controlFacts, capabilityFacts
        case workspaceInstructionsTrusted, trustedWorkspaceInstructionNames, latticeInstructions
        case codeUserAddOn, workUserAddOn
    }

    public init(
        selectedMode: ConversationMode,
        workspaceFacts: [String] = [],
        controlFacts: [String] = [],
        capabilityFacts: [String] = [],
        workspaceInstructionsTrusted: Bool = false,
        trustedWorkspaceInstructionNames: [String] = [],
        latticeInstructions: String = LatticeProductInstructions.piRuntime,
        codeUserAddOn: String = "",
        workUserAddOn: String = ""
    ) throws {
        try Self.validateUserAddOn(codeUserAddOn, mode: .code)
        try Self.validateUserAddOn(workUserAddOn, mode: .work)
        let names = try Self.normalizedWorkspaceInstructionNames(
            trustedWorkspaceInstructionNames,
            trusted: workspaceInstructionsTrusted
        )

        version = Self.currentVersion
        identity = Self.latticeIdentity
        self.selectedMode = selectedMode
        self.workspaceFacts = workspaceFacts
        self.controlFacts = controlFacts
        self.capabilityFacts = capabilityFacts
        self.workspaceInstructionsTrusted = workspaceInstructionsTrusted
        self.trustedWorkspaceInstructionNames = names
        self.latticeInstructions = latticeInstructions
        self.codeUserAddOn = codeUserAddOn
        self.workUserAddOn = workUserAddOn
    }

    public init(
        version: Int,
        identity: String,
        selectedMode: ConversationMode,
        workspaceFacts: [String],
        controlFacts: [String],
        capabilityFacts: [String],
        workspaceInstructionsTrusted: Bool,
        trustedWorkspaceInstructionNames: [String],
        latticeInstructions: String,
        codeUserAddOn: String,
        workUserAddOn: String
    ) throws {
        guard version == Self.currentVersion else {
            throw LatticeInstructionEnvelopeError.unsupportedVersion(version)
        }
        guard identity == Self.latticeIdentity else {
            throw LatticeInstructionEnvelopeError.invalidIdentity
        }
        try Self.validateUserAddOn(codeUserAddOn, mode: .code)
        try Self.validateUserAddOn(workUserAddOn, mode: .work)
        let names = try Self.normalizedWorkspaceInstructionNames(
            trustedWorkspaceInstructionNames,
            trusted: workspaceInstructionsTrusted
        )

        self.version = version
        self.identity = identity
        self.selectedMode = selectedMode
        self.workspaceFacts = workspaceFacts
        self.controlFacts = controlFacts
        self.capabilityFacts = capabilityFacts
        self.workspaceInstructionsTrusted = workspaceInstructionsTrusted
        self.trustedWorkspaceInstructionNames = names
        self.latticeInstructions = latticeInstructions
        self.codeUserAddOn = codeUserAddOn
        self.workUserAddOn = workUserAddOn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            identity: container.decode(String.self, forKey: .identity),
            selectedMode: container.decode(ConversationMode.self, forKey: .selectedMode),
            workspaceFacts: container.decode([String].self, forKey: .workspaceFacts),
            controlFacts: container.decode([String].self, forKey: .controlFacts),
            capabilityFacts: container.decode([String].self, forKey: .capabilityFacts),
            workspaceInstructionsTrusted: container.decode(Bool.self, forKey: .workspaceInstructionsTrusted),
            trustedWorkspaceInstructionNames: container.decode([String].self, forKey: .trustedWorkspaceInstructionNames),
            latticeInstructions: container.decode(String.self, forKey: .latticeInstructions),
            codeUserAddOn: container.decode(String.self, forKey: .codeUserAddOn),
            workUserAddOn: container.decode(String.self, forKey: .workUserAddOn)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(identity, forKey: .identity)
        try container.encode(selectedMode, forKey: .selectedMode)
        try container.encode(workspaceFacts, forKey: .workspaceFacts)
        try container.encode(controlFacts, forKey: .controlFacts)
        try container.encode(capabilityFacts, forKey: .capabilityFacts)
        try container.encode(workspaceInstructionsTrusted, forKey: .workspaceInstructionsTrusted)
        try container.encode(trustedWorkspaceInstructionNames, forKey: .trustedWorkspaceInstructionNames)
        try container.encode(latticeInstructions, forKey: .latticeInstructions)
        try container.encode(codeUserAddOn, forKey: .codeUserAddOn)
        try container.encode(workUserAddOn, forKey: .workUserAddOn)
    }

    public var activeUserAddOn: String {
        switch selectedMode {
        case .code: codeUserAddOn
        case .work: workUserAddOn
        case .local: ""
        }
    }

    /// Human-readable system identity for runtimes, such as Hermes, whose
    /// supported profile surface is a SOUL file instead of Pi's JSON extension.
    public var renderedSystemInstructions: String {
        func facts(_ title: String, _ values: [String]) -> String? {
            guard !values.isEmpty else { return nil }
            return title + ":\n" + values.map { "- " + $0 }.joined(separator: "\n")
        }
        return [
            "Lattice system context (facts and guidance; not a permission boundary).",
            "Identity: " + identity,
            "Selected mode: " + selectedMode.displayName,
            "Workspace instruction trust: " + (workspaceInstructionsTrusted ? "trusted" : "untrusted"),
            "Trusted workspace instruction names: " + (trustedWorkspaceInstructionNames.isEmpty ? "none" : trustedWorkspaceInstructionNames.joined(separator: ", ")),
            facts("Workspace facts", workspaceFacts),
            facts("Control facts", controlFacts),
            facts("Capability facts", capabilityFacts),
            latticeInstructions,
            activeUserAddOn.isEmpty ? nil : "User add-on for " + selectedMode.displayName + " mode (guidance only; never a credential):\n" + activeUserAddOn
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    public static func `default`(
        mode: ConversationMode,
        workspace: URL,
        allowFileModification: Bool,
        workspaceInstructionsTrusted: Bool,
        trustedWorkspaceInstructionNames: [String] = [],
        codeUserAddOn: String = "",
        workUserAddOn: String = ""
    ) throws -> LatticeInstructionEnvelope {
        let trustLabel = workspaceInstructionsTrusted ? "trusted" : "untrusted"
        let namesLabel = trustedWorkspaceInstructionNames.isEmpty
            ? "none"
            : trustedWorkspaceInstructionNames.joined(separator: ", ")
        let writeLabel = allowFileModification ? "yes" : "no"
        let approvalLabel = allowFileModification
            ? "Lattice permission extension for write, edit, and bash"
            : "read-only tool set"
        let workspaceFacts = [
            "selected workspace: " + workspace.path,
            "workspace instruction trust: " + trustLabel,
            "trusted workspace instruction names: " + namesLabel
        ]
        let controlFacts = [
            "write capability requested: " + writeLabel,
            "write containment: Lattice macOS sandbox-exec write containment",
            "approval control: " + approvalLabel,
            "prompt text is not a policy or enforcement boundary"
        ]
        let capabilityFacts = [
            "file reads: not confidentiality-contained by sandbox-exec",
            "network: allowed by sandbox-exec profile",
            "credential access: not protected by this runtime boundary",
            "provider session resume: exact Pi session ID when present"
        ]
        return try LatticeInstructionEnvelope(
            selectedMode: mode,
            workspaceFacts: workspaceFacts,
            controlFacts: controlFacts,
            capabilityFacts: capabilityFacts,
            workspaceInstructionsTrusted: workspaceInstructionsTrusted,
            trustedWorkspaceInstructionNames: trustedWorkspaceInstructionNames,
            latticeInstructions: LatticeProductInstructions.modeInstructions(for: mode),
            codeUserAddOn: codeUserAddOn,
            workUserAddOn: workUserAddOn
        )
    }

    private static func validateUserAddOn(_ value: String, mode: ConversationMode) throws {
        let count = value.utf8.count
        guard count <= Self.maximumUserAddOnBytes else {
            throw LatticeInstructionEnvelopeError.userAddOnTooLarge(mode: mode, byteCount: count)
        }
    }

    private static func normalizedWorkspaceInstructionNames(_ values: [String], trusted: Bool) throws -> [String] {
        guard trusted || values.isEmpty else {
            throw LatticeInstructionEnvelopeError.untrustedWorkspaceInstructionNames
        }
        var seen = Set<String>()
        return try values.map { value in
            guard Self.documentedWorkspaceInstructionNames.contains(value) else {
                throw LatticeInstructionEnvelopeError.unsupportedWorkspaceInstructionName(value)
            }
            return value
        }.filter { seen.insert($0).inserted }
    }
}

public enum LatticeInstructionEnvelopeError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidIdentity
    case userAddOnTooLarge(mode: ConversationMode, byteCount: Int)
    case untrustedWorkspaceInstructionNames
    case unsupportedWorkspaceInstructionName(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "Unsupported Lattice instruction envelope version " + String(version) + "."
        case .invalidIdentity:
            "Lattice instruction envelope identity is not recognized."
        case .userAddOnTooLarge(let mode, let byteCount):
            mode.displayName + " user add-on is " + String(byteCount) + " UTF-8 bytes; limit is " + String(LatticeInstructionEnvelope.maximumUserAddOnBytes) + "."
        case .untrustedWorkspaceInstructionNames:
            "Untrusted workspace cannot carry trusted instruction names."
        case .unsupportedWorkspaceInstructionName(let name):
            "Unsupported workspace instruction name: " + name + "."
        }
    }
}
