import Foundation

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
