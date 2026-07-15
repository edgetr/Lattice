import Foundation

/// Stable keys for provider/runtime connection snapshots.
/// Prefer these over parallel per-provider `@Published` fields.
public enum ProviderConnectionKey: String, CaseIterable, Codable, Hashable, Sendable {
    case codex
    case grok
    case opencode
    case antigravity
    case pi
    case hermes
    case ollama
    case apple
}

/// Map-driven provider runtime observation. Never caches secrets.
public struct ProviderRuntimeSnapshot: Equatable, Sendable {
    public var installed: Bool
    public var authenticated: Bool
    public var catalogStatus: ProviderCatalogStatus
    public var models: [ProviderModel]
    public var harnessModels: [HarnessModel]
    public var cliVersion: String?
    public var latestCLIVersion: String?
    /// Freeform protocol/detail note (unavailable reason, protocol support text, etc.).
    public var protocolDetail: String?
    public var ready: Bool
    public var usage: ProviderUsage?
    public var updateInfo: CLIUpdateInfo?

    public init(
        installed: Bool = false,
        authenticated: Bool = false,
        catalogStatus: ProviderCatalogStatus = .unknown,
        models: [ProviderModel] = [],
        harnessModels: [HarnessModel] = [],
        cliVersion: String? = nil,
        latestCLIVersion: String? = nil,
        protocolDetail: String? = nil,
        ready: Bool = false,
        usage: ProviderUsage? = nil,
        updateInfo: CLIUpdateInfo? = nil
    ) {
        self.installed = installed
        self.authenticated = authenticated
        self.catalogStatus = catalogStatus
        self.models = models
        self.harnessModels = harnessModels
        self.cliVersion = cliVersion
        self.latestCLIVersion = latestCLIVersion
        self.protocolDetail = protocolDetail
        self.ready = ready
        self.usage = usage
        self.updateInfo = updateInfo
    }

    public static let empty = ProviderRuntimeSnapshot()

    public var readiness: ProviderReadinessSnapshot {
        ProviderReadinessSnapshot(
            installed: installed,
            authenticated: authenticated,
            catalogStatus: catalogStatus,
            runnableModelCount: models.count
        )
    }

    /// Apply catalog-loading transition without inventing readiness.
    public func markingCatalogLoading() -> ProviderRuntimeSnapshot {
        var copy = self
        copy.catalogStatus = .loading
        copy.ready = false
        return copy
    }
}

/// Pure helpers for map-driven connection state.
public enum ProviderRuntimeSnapshotStore {
    public static func upsert(
        _ snapshots: inout [String: ProviderRuntimeSnapshot],
        key: ProviderConnectionKey,
        snapshot: ProviderRuntimeSnapshot
    ) {
        snapshots[key.rawValue] = snapshot
    }

    public static func snapshot(
        in snapshots: [String: ProviderRuntimeSnapshot],
        key: ProviderConnectionKey
    ) -> ProviderRuntimeSnapshot {
        snapshots[key.rawValue] ?? .empty
    }

    public static func markLoading(
        _ snapshots: inout [String: ProviderRuntimeSnapshot],
        key: ProviderConnectionKey
    ) {
        var current = snapshot(in: snapshots, key: key)
        current = current.markingCatalogLoading()
        snapshots[key.rawValue] = current
    }

    /// Fail-closed readiness: ready only when installed, authenticated, loaded, and runnable models exist.
    public static func computeReady(
        installed: Bool,
        authenticated: Bool,
        catalogStatus: ProviderCatalogStatus,
        runnableModelCount: Int
    ) -> Bool {
        ProviderReadinessSnapshot(
            installed: installed,
            authenticated: authenticated,
            catalogStatus: catalogStatus,
            runnableModelCount: runnableModelCount
        ).isRunnable
    }
}
