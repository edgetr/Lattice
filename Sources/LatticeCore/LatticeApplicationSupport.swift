import Foundation

/// Canonical Application Support layout and environment for Lattice.
///
/// Legacy brand aliases (`Nisa` / `NISA_*`) exist only for migration and automation
/// compatibility. New writes always use Lattice names and paths.
public enum LatticeApplicationSupport: Sendable {
    public static let productFolderName = "Lattice"
    public static let bundleIdentifier = "com.lattice.desktop"

    /// Deprecated product folder from the pre-rename brand. Do not write here.
    public static let legacyProductFolderName = "Nisa"
    /// Deprecated bundle identifier from the pre-rename brand.
    public static let legacyBundleIdentifier = "com.nisa.desktop"

    public static func environmentValue(primary: String, legacy: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[primary]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let value = ProcessInfo.processInfo.environment[legacy]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return nil
    }

    public static func appSupportOverrideDirectory() -> URL? {
        guard let path = environmentValue(primary: "LATTICE_APP_SUPPORT_DIR", legacy: "NISA_APP_SUPPORT_DIR") else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func sessionStoreOverridePath() -> String? {
        environmentValue(primary: "LATTICE_SESSION_STORE_PATH", legacy: "NISA_SESSION_STORE_PATH")
    }

    public static func standardApplicationSupportBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public static func productRootURL(base: URL? = nil) -> URL {
        if let override = appSupportOverrideDirectory() {
            return override.appendingPathComponent(productFolderName, isDirectory: true)
        }
        return (base ?? standardApplicationSupportBase()).appendingPathComponent(productFolderName, isDirectory: true)
    }

    public static func legacyProductRootURL(base: URL? = nil) -> URL {
        if let override = appSupportOverrideDirectory() {
            return override.appendingPathComponent(legacyProductFolderName, isDirectory: true)
        }
        return (base ?? standardApplicationSupportBase()).appendingPathComponent(legacyProductFolderName, isDirectory: true)
    }

    public static func path(underProduct component: String) -> URL {
        productRootURL().appendingPathComponent(component, isDirectory: component.hasSuffix("/") || !component.contains("."))
    }

    /// Copies legacy Application Support data into the Lattice folder when the destination is absent.
    /// Never overwrites an existing Lattice tree.
    @discardableResult
    public static func migrateLegacyProductDataIfNeeded(fileManager: FileManager = .default, base: URL? = nil) -> Bool {
        let destination = productRootURL(base: base)
        guard !fileManager.fileExists(atPath: destination.path),
              LatticeStorePathSecurity.isDirectoryWithoutFollowingSymlinks(at: destination) == false else {
            return false
        }
        let source = legacyProductRootURL(base: base)
        guard LatticeStorePathSecurity.isDirectoryWithoutFollowingSymlinks(at: source) else { return false }

        // Migration is deliberately narrow. Legacy product roots may contain provider
        // sessions, credentials, runtime profiles, captures, or arbitrary user files.
        // Only Lattice-owned durable session artifacts cross the rename boundary.
        let allowedRootFiles = Set([
            "sessions.json",
            "sessions.search-index.json",
            "self-edit-jobs.json",
            "self-edit-previews.json",
            "workspace-checkpoints.json"
        ])
        let allowedDirectories = Set(["session-transcripts", "session-artifacts"])
        let maximumFileCount = 4_096
        let maximumFileBytes = 10 * 1024 * 1024

        func sidecarNameIsSafe(_ name: String, sessionID: UUID) -> Bool {
            let prefix = sessionID.uuidString.lowercased() + "-"
            guard name.hasPrefix(prefix), name.hasSuffix(".json"), name.utf8.count <= 160 else { return false }
            let digest = name.dropFirst(prefix.count).dropLast(".json".count)
            return digest.count == 16 && digest.allSatisfy { character in
                character.isNumber || ("a"..."f").contains(character)
            }
        }

        func collect(_ directory: URL, relativePrefix: String = "", depth: Int = 0) throws -> [(String, Data)] {
            guard depth <= 2 else { return [] }
            let entries = try LatticeStorePathSecurity.directoryEntriesWithoutFollowingSymlinks(in: directory)
            var result: [(String, Data)] = []
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                guard !entry.name.isEmpty, entry.name != ".", entry.name != "..", entry.name.utf8.count <= 255 else { continue }
                let relative = relativePrefix.isEmpty ? entry.name : relativePrefix + "/" + entry.name
                let url = directory.appendingPathComponent(entry.name)
                if entry.isRegularFile {
                    let allowed: Bool
                    if relativePrefix.isEmpty {
                        allowed = allowedRootFiles.contains(entry.name)
                    } else if relativePrefix == "session-transcripts" || relativePrefix == "session-artifacts",
                              let uuid = UUID(uuidString: String(entry.name.prefix(36))) {
                        allowed = sidecarNameIsSafe(entry.name, sessionID: uuid)
                    } else {
                        allowed = false
                    }
                    guard allowed else { continue }
                    let data = try LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(at: url, maximumByteCount: maximumFileBytes)
                    result.append((relative, data))
                } else if entry.isDirectory, relativePrefix.isEmpty, allowedDirectories.contains(entry.name) {
                    result.append(contentsOf: try collect(url, relativePrefix: relative, depth: depth + 1))
                }
                guard result.count <= maximumFileCount else { throw LatticeStorePathError.fileSystem(source, EOVERFLOW) }
            }
            return result
        }

        do {
            let payloads = try collect(source)
            guard !payloads.isEmpty else { return false }
            try LatticeStorePathSecurity.prepareDirectory(at: destination)
            for (relative, data) in payloads {
                let target = destination.appendingPathComponent(relative)
                let parent = target.deletingLastPathComponent()
                try LatticeStorePathSecurity.prepareDirectory(at: parent)
                try LatticeStorePathSecurity.writeDataAtomicallyWithoutFollowingSymlinks(data, to: target)
            }
            return true
        } catch {
            // Best-effort rollback is descriptor-safe and cannot follow symlinks. A
            // concurrent destination publication is never overwritten.
            if LatticeStorePathSecurity.isDirectoryWithoutFollowingSymlinks(at: destination) {
                try? LatticeStorePathSecurity.removeItem(at: destination, under: destination.deletingLastPathComponent())
            }
            return false
        }
    }

    /// Migrates preference keys from the pre-rename suite when the current suite is missing them.
    public static func migrateLegacyUserDefaultsIfNeeded(
        current: UserDefaults = .standard,
        legacySuiteName: String = legacyBundleIdentifier
    ) {
        guard let legacy = UserDefaults(suiteName: legacySuiteName) else { return }
        let keys = [
            "disabledModelIDs",
            "enabledExtensionIDs",
            "knownExtensionIDs",
            "disabledSkillIDs",
            "localModelIdleUnloadMinutes",
            "defaultBackend",
            "lattice.models.showOnlyFittingLocalRecommendations",
            // Pre-rename AppStorage key
            "nisa.models.showOnlyFittingLocalRecommendations"
        ]
        for key in keys {
            if current.object(forKey: key) != nil { continue }
            if let value = legacy.object(forKey: key) {
                let destinationKey = key == "nisa.models.showOnlyFittingLocalRecommendations"
                    ? "lattice.models.showOnlyFittingLocalRecommendations" : key
                if let safeValue = validatedPreferenceValue(value, forKey: destinationKey) {
                    current.set(safeValue, forKey: destinationKey)
                }
            }
        }
        // Also migrate within the current suite if only the old AppStorage key exists.
        if current.object(forKey: "lattice.models.showOnlyFittingLocalRecommendations") == nil,
           let value = current.object(forKey: "nisa.models.showOnlyFittingLocalRecommendations") {
            if let safeValue = validatedPreferenceValue(value, forKey: "lattice.models.showOnlyFittingLocalRecommendations") {
                current.set(safeValue, forKey: "lattice.models.showOnlyFittingLocalRecommendations")
            }
        }
    }

    private static func validatedPreferenceValue(_ value: Any, forKey key: String) -> Any? {
        switch key {
        case "disabledModelIDs", "enabledExtensionIDs", "knownExtensionIDs", "disabledSkillIDs":
            guard let values = value as? [String], values.count <= 10_000,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
            return values
        case "localModelIdleUnloadMinutes":
            guard let number = value as? NSNumber else { return nil }
            let minutes = number.intValue
            guard number.doubleValue == Double(minutes), (0...1_440).contains(minutes) else { return nil }
            return minutes
        case "defaultBackend":
            guard let backend = value as? String, backend.utf8.count <= 64,
                  !backend.isEmpty, backend.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else { return nil }
            return backend
        case "lattice.models.showOnlyFittingLocalRecommendations":
            return value as? Bool
        default:
            return nil
        }
    }
}

/// Isolated legacy brand constants used only for backward-compatible reads.
/// Do not surface these strings in product UI.
public enum LatticeLegacyBrandCompatibility: Sendable {
    public static let extensionManifestFileName = "nisa-extension.json"
    public static let extensionManifestSuffix = ".nisaextension.json"
    public static let extensionManifestOpeningTag = "<nisa-extension-manifest>"
    public static let extensionManifestClosingTag = "</nisa-extension-manifest>"
    public static let skillSourceMarker = ".nisa-skill-source"
    public static let skillOriginalPathMarker = ".nisa-original-skill-path"
    public static let skillOwnerMarker = ".nisa-skill-owner-extension-id"
    public static let skillImportedBaselineMarker = ".nisa-imported-skill-baseline"
    public static let deletedGlobalSkillsFileName = ".nisa-deleted-global-skills.json"
    public static let selfMapFileName = "nisa-self-map.json"
    public static let selfEditGuideFileName = "NISA_SELF_EDIT.md"
    public static let keychainService = "Nisa"
    public static let hotKeySignature = "NISA"
    public static let productFolderName = LatticeApplicationSupport.legacyProductFolderName
}
