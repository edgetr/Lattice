import Foundation

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
        let enabledIDs = storedEnabledIDs
            .intersection(runtimeIDs)
        let refreshedKnownIDs = knownIDs.union(runtimeIDs)
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
