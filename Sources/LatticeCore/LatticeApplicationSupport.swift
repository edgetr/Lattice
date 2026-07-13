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
        if fileManager.fileExists(atPath: destination.path) {
            return false
        }
        let source = legacyProductRootURL(base: base)
        guard fileManager.fileExists(atPath: source.path) else { return false }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            return true
        } catch {
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
                current.set(value, forKey: key == "nisa.models.showOnlyFittingLocalRecommendations"
                    ? "lattice.models.showOnlyFittingLocalRecommendations"
                    : key)
            }
        }
        // Also migrate within the current suite if only the old AppStorage key exists.
        if current.object(forKey: "lattice.models.showOnlyFittingLocalRecommendations") == nil,
           let value = current.object(forKey: "nisa.models.showOnlyFittingLocalRecommendations") {
            current.set(value, forKey: "lattice.models.showOnlyFittingLocalRecommendations")
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
