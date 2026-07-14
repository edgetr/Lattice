import Foundation

/// Catalog request outcome. Empty models alone cannot distinguish no models
/// from a failed discovery request.
public enum ProviderCatalogStatus: String, Codable, Hashable, Sendable {
    case unknown
    case loading
    case loaded
    case empty
    case failed

    public var isResolved: Bool {
        switch self {
        case .unknown, .loading: false
        case .loaded, .empty, .failed: true
        }
    }

    public var isRefreshable: Bool {
        switch self {
        case .unknown, .empty, .failed: true
        case .loading, .loaded: false
        }
    }

    public static func resolved(modelCount: Int, succeeded: Bool) -> Self {
        guard succeeded else { return .failed }
        return modelCount == 0 ? .empty : .loaded
    }

    public static func combined(_ primary: Self, _ runtime: Self) -> Self {
        if primary == .failed || runtime == .failed { return .failed }
        if primary == .loading || runtime == .loading { return .loading }
        if primary == .unknown || runtime == .unknown { return .unknown }
        if primary == .empty || runtime == .empty { return .empty }
        return .loaded
    }
}

public struct ProviderCatalogResult<Model: Sendable>: Sendable {
    public let models: [Model]
    public let status: ProviderCatalogStatus

    public init(models: [Model], status: ProviderCatalogStatus) {
        self.models = models
        self.status = status
    }

    public init(models: [Model], succeeded: Bool) {
        self.init(models: models, status: .resolved(modelCount: models.count, succeeded: succeeded))
    }

    public static func unknown() -> Self {
        Self(models: [], status: .unknown)
    }
}

public struct ProviderReadinessSnapshot: Equatable, Hashable, Sendable {
    public let installed: Bool
    public let authenticated: Bool
    public let catalogStatus: ProviderCatalogStatus
    public let runnableModelCount: Int

    public init(installed: Bool, authenticated: Bool, catalogStatus: ProviderCatalogStatus, runnableModelCount: Int) {
        self.installed = installed
        self.authenticated = authenticated
        self.catalogStatus = catalogStatus
        self.runnableModelCount = max(0, runnableModelCount)
    }

    public var isRunnable: Bool {
        installed && authenticated && catalogStatus == .loaded && runnableModelCount > 0
    }
}

public struct ProviderReadinessCopy: Equatable, Sendable {
    public let detail: String
    public let isReady: Bool

    public init(detail: String, isReady: Bool) {
        self.detail = detail
        self.isReady = isReady
    }
}

public enum ProviderReadinessPresentationPolicy: Sendable {
    public static func copy(
        providerName: String,
        readiness: ProviderReadinessSnapshot,
        readyDetail: String = "Available"
    ) -> ProviderReadinessCopy {
        let name = providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Provider" : providerName
        guard readiness.installed else { return ProviderReadinessCopy(detail: "Not installed", isReady: false) }
        guard readiness.authenticated else { return ProviderReadinessCopy(detail: "Sign in required", isReady: false) }

        switch readiness.catalogStatus {
        case .unknown: return ProviderReadinessCopy(detail: "Signed in · models not checked", isReady: false)
        case .loading: return ProviderReadinessCopy(detail: "Signed in · checking models", isReady: false)
        case .empty: return ProviderReadinessCopy(detail: "Signed in · no \(name) models found", isReady: false)
        case .failed: return ProviderReadinessCopy(detail: "Signed in · models unavailable", isReady: false)
        case .loaded:
            guard readiness.runnableModelCount > 0 else { return ProviderReadinessCopy(detail: "Signed in · no runnable models", isReady: false) }
            return ProviderReadinessCopy(detail: readyDetail, isReady: true)
        }
    }
}
