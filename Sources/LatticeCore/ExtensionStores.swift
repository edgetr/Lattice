import Foundation

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
        try LatticeStorePathSecurity.prepareDirectory(at: rootURL)
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
        let canonicalRoot = try LatticeStorePathSecurity.canonicalDirectory(at: rootURL)
        let bundleURL = try LatticeStorePathSecurity.createChildDirectory(named: manifest.id, under: canonicalRoot)
        let manifestURL = bundleURL.appendingPathComponent("lattice-extension.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            guard data.count <= DurableStoreRecovery.maximumStoreByteCount else {
                throw NSError(domain: "LatticeExtensionStore", code: 6, userInfo: [NSLocalizedDescriptionKey: "Generated extension manifest exceeds the safe storage limit."])
            }
            try LatticeStorePathSecurity.writeDataAtomically(data, to: manifestURL, under: canonicalRoot)
        return manifestURL
    }

    public func manifestData(for manifestID: String) -> Data? {
        guard Self.isSafeManifestID(manifestID) else { return nil }
        guard let canonicalRoot = try? LatticeStorePathSecurity.canonicalDirectory(at: rootURL) else { return nil }
        let bundle = canonicalRoot.appendingPathComponent(manifestID, isDirectory: true)
        guard LatticeStorePathSecurity.isDirectoryWithoutFollowingSymlinks(at: bundle) else { return nil }
        if let existing = firstExistingManifest(in: bundle) {
            return try? LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(at: existing)
        }
        return nil
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
            let canonicalRoot = try LatticeStorePathSecurity.canonicalDirectory(at: rootURL)
            let bundleURL = try LatticeStorePathSecurity.createChildDirectory(named: manifestID, under: canonicalRoot)
            try LatticeStorePathSecurity.writeDataAtomically(
                previousManifestData,
                to: bundleURL.appendingPathComponent("lattice-extension.json"),
                under: canonicalRoot
            )
        } else {
            let canonicalRoot = try LatticeStorePathSecurity.canonicalDirectory(at: rootURL)
            if let bundleURL = try LatticeStorePathSecurity.existingChildDirectory(named: manifestID, under: canonicalRoot) {
                try LatticeStorePathSecurity.removeItem(at: bundleURL, under: canonicalRoot)
            }
        }
    }

    private func manifestCandidates() throws -> [(manifest: URL, bundle: URL)] {
        let canonicalRoot = try LatticeStorePathSecurity.canonicalDirectory(at: rootURL)
        var results: [(URL, URL)] = []
        for entry in try LatticeStorePathSecurity.directoryEntriesWithoutFollowingSymlinks(in: canonicalRoot) {
            let child = canonicalRoot.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            if entry.isDirectory {
                if let manifest = firstExistingManifest(in: child) {
                    results.append((manifest, child))
                }
            } else if entry.isRegularFile,
                      (child.lastPathComponent.hasSuffix(".latticeextension.json")
                        || child.lastPathComponent == "lattice-extension.json"
                        || child.lastPathComponent.hasSuffix(LatticeLegacyBrandCompatibility.extensionManifestSuffix)
                        || child.lastPathComponent == LatticeLegacyBrandCompatibility.extensionManifestFileName) {
                results.append((child, canonicalRoot))
            }
        }
        return results
    }

    private func firstExistingManifest(in bundle: URL) -> URL? {
        guard let entries = try? LatticeStorePathSecurity.directoryEntriesWithoutFollowingSymlinks(in: bundle) else { return nil }
        let names = Set(entries.filter(\.isRegularFile).map(\.name))
        if names.contains("lattice-extension.json") { return bundle.appendingPathComponent("lattice-extension.json") }
        if names.contains(LatticeLegacyBrandCompatibility.extensionManifestFileName) {
            return bundle.appendingPathComponent(LatticeLegacyBrandCompatibility.extensionManifestFileName)
        }
        return nil
    }

    private func loadRecord(manifestURL: URL, bundleURL: URL) -> LatticeExtensionRecord {
        do {
            let manifest = try JSONDecoder().decode(
                LatticeExtensionManifest.self,
                from: LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(at: manifestURL)
            )
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

    private static func isSafeManifestID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == id, trimmed != ".", trimmed != ".." else { return false }
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
        try writeGate.withExclusiveWrite {
            try DurableStoreRecovery.enforceWritable(gate: writeGate, storeName: Self.storeName)
            try io.createDirectory(fileURL.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records.sorted { $0.createdAt > $1.createdAt })
            guard data.count <= DurableStoreRecovery.maximumStoreByteCount else {
                throw NSError(domain: "LatticeExtensionStore", code: 7, userInfo: [NSLocalizedDescriptionKey: "Self-edit history exceeds the safe storage limit."])
            }
            do {
                try io.writeDataAtomically(data, fileURL)
            } catch {
                if (try? io.readDataUpTo(fileURL, DurableStoreRecovery.maximumStoreByteCount)) == data {
                    throw NSError(domain: "LatticeExtensionStore", code: 8, userInfo: [NSLocalizedDescriptionKey: "Self-edit history was published, but write durability could not be confirmed. (error.localizedDescription)"])
                }
                throw error
            }
        }
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
