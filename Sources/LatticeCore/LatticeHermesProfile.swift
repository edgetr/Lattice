import Foundation

public enum LatticeHermesProfileError: LocalizedError, Equatable, Sendable {
    case emptySystemIdentity
    case systemIdentityTooLarge(Int)
    case invalidProvider(String)
    case emptyModel
    case invalidModel(String)
    case credentialInjectionNotAllowed
    case invalidHome(String)
    case invalidTemporaryDirectory(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptySystemIdentity:
            "Lattice Hermes Work identity is empty."
        case .systemIdentityTooLarge(let limit):
            "Lattice Hermes Work identity exceeds the \(limit)-byte safety limit."
        case .invalidProvider(let provider):
            "Hermes Work provider is not allowed: \(provider)."
        case .emptyModel:
            "Hermes Work model is empty."
        case .invalidModel(let model):
            "Hermes Work model contains unsupported control characters: \(model)."
        case .credentialInjectionNotAllowed:
            "Only the provider-specific OpenCode key may be injected, and only for an OpenCode Work route."
        case .invalidHome(let path):
            "Hermes profile home is not a directory: \(path)."
        case .invalidTemporaryDirectory(let path):
            "Hermes temporary directory is not a safe directory: \(path)."
        case .writeFailed(let detail):
            "Lattice could not create Hermes profile state: \(detail)"
        }
    }
}

public enum LatticeHermesProvider: String, CaseIterable, Sendable {
    case openAICodex = "openai-codex"
    case xAIOAuth = "xai-oauth"
    case xAI = "xai"
    case openCodeGo = "opencode-go"
    case openCodeZen = "opencode-zen"

    public var isOpenCode: Bool {
        self == .openCodeGo || self == .openCodeZen
    }
}

/// Provider and model selected for one Hermes Work run.
///
/// `model` is intentionally stored byte-for-byte after validation. Work routes
/// must use provider-qualified IDs supplied by the caller; no leaf-name rewrite
/// or fuzzy lookup happens here.
public struct LatticeHermesWorkRoute: Equatable, Hashable, Sendable {
    public static let maximumModelByteCount = 1_024
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.model = model
    }

    public var isAllowedProvider: Bool {
        LatticeHermesProvider(rawValue: provider) != nil
    }

    public var isValid: Bool {
        do {
            try validate()
            return true
        } catch {
            return false
        }
    }

    public var isOpenCodeRoute: Bool {
        LatticeHermesProvider(rawValue: provider)?.isOpenCode == true
    }

    public var openCodeCredentialEnvironmentKey: String? {
        switch LatticeHermesProvider(rawValue: provider) {
        case .openCodeGo: "OPENCODE_GO_API_KEY"
        case .openCodeZen: "OPENCODE_ZEN_API_KEY"
        default: nil
        }
    }

    public func validate() throws {
        guard isAllowedProvider else { throw LatticeHermesProfileError.invalidProvider(provider) }
        guard !model.isEmpty else { throw LatticeHermesProfileError.emptyModel }
        guard model.utf8.count <= Self.maximumModelByteCount else {
            throw LatticeHermesProfileError.invalidModel(model)
        }
        guard model.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LatticeHermesProfileError.invalidModel(model)
        }
        // Hermes expands ${VAR} references in config values. Do not let a model
        // ID turn into an ambient environment read.
        guard !model.contains("${") else { throw LatticeHermesProfileError.invalidModel(model) }
    }
}

public typealias HermesWorkRoute = LatticeHermesWorkRoute

public enum LatticeHermesToolCategory: String, CaseIterable, Sendable {
    case browser
    case computerUse = "computer_use"
    case web
    case file
    case terminal
    case messaging
    case cronjob
    case credentials
    case secrets
    case financial
    case externalConsequential = "external-consequential"
}

public struct LatticeHermesWorkToolPolicy: Equatable, Hashable, Sendable {
    public static let enabled: [LatticeHermesToolCategory] = [
        .browser, .computerUse, .web, .file, .terminal
    ]

    public static let disabled: [LatticeHermesToolCategory] = [
        .messaging, .cronjob, .credentials, .secrets, .financial, .externalConsequential
    ]

    public init() {}

    public var enabledToolsets: [String] {
        Self.enabled.map(\.rawValue)
    }

    public var disabledToolsets: [String] {
        Self.disabled.map(\.rawValue)
    }
}

public enum LatticeHermesReadinessState: String, CaseIterable, Sendable {
    case unknown
    case required
    case validated
}

public struct LatticeHermesReadiness: Equatable, Hashable, Sendable {
    public let runtimePresent: Bool
    public let profileConfigured: Bool
    public let auth: LatticeHermesReadinessState
    public let catalog: LatticeHermesReadinessState

    public init(
        runtimePresent: Bool,
        profileConfigured: Bool,
        auth: LatticeHermesReadinessState = .unknown,
        catalog: LatticeHermesReadinessState = .unknown
    ) {
        self.runtimePresent = runtimePresent
        self.profileConfigured = profileConfigured
        self.auth = auth
        self.catalog = catalog
    }

    public var authentication: LatticeHermesReadinessState { auth }
    public var authState: LatticeHermesReadinessState { auth }
    public var catalogState: LatticeHermesReadinessState { catalog }
    public var isAuthenticated: Bool { auth == .validated }

    public var isReady: Bool {
        runtimePresent && profileConfigured && auth == .validated && catalog == .validated
    }
}

public typealias HermesProfileReadiness = LatticeHermesReadiness

/// Lattice-owned Hermes profile for Work runs.
///
/// Manager never reads, imports, copies, migrates, or persists provider auth or
/// session material. It owns only `config.yaml` and `SOUL.md`; Hermes owns any
/// runtime state it later creates below `homeURL`.
public final class LatticeHermesProfile: @unchecked Sendable {
    public static let defaultDirectoryName = "HermesWork"
    public static let configFileName = "config.yaml"
    public static let soulFileName = "SOUL.md"
    public static let workToolPolicy = LatticeHermesWorkToolPolicy()
    public static let maximumSystemIdentityByteCount = 256 * 1024

    /// Conservative parser for `hermes auth status` output. Only explicit
    /// logged-in/authenticated wording can pass; file contents are irrelevant.
    public static func isLoggedInStatusOutput(_ output: String) -> Bool {
        let status = output.lowercased()
        let loggedOutMarkers = [
            "not logged in", "logged out", "not authenticated", "unauthenticated",
            "no credentials", "no credential", "missing credentials"
        ]
        guard !loggedOutMarkers.contains(where: status.contains) else { return false }
        return ["logged in", "authenticated", "signed in"].contains(where: status.contains)
    }

    public let homeURL: URL
    public let hermesHomeURL: URL
    public let configURL: URL
    public let soulURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        hermesHome: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let home = hermesHome
            ?? LatticeApplicationSupport.productRootURL()
                .appendingPathComponent(Self.defaultDirectoryName, isDirectory: true)
        self.homeURL = home.standardizedFileURL
        self.hermesHomeURL = self.homeURL
        self.configURL = self.homeURL.appendingPathComponent(Self.configFileName)
        self.soulURL = self.homeURL.appendingPathComponent(Self.soulFileName)
        self.fileManager = fileManager
    }

    public convenience init(homeURL: URL, fileManager: FileManager = .default) {
        self.init(hermesHome: homeURL, fileManager: fileManager)
    }

    /// Create or replace only Lattice-owned config and SOUL files.
    @discardableResult
    public func configure(
        systemIdentity: String,
        route: LatticeHermesWorkRoute,
        opencodeAPIKey: String? = nil
    ) throws -> LatticeHermesReadiness {
        guard !systemIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LatticeHermesProfileError.emptySystemIdentity
        }
        guard systemIdentity.utf8.count <= Self.maximumSystemIdentityByteCount else {
            throw LatticeHermesProfileError.systemIdentityTooLarge(Self.maximumSystemIdentityByteCount)
        }
        try route.validate()
        if let opencodeAPIKey, !opencodeAPIKey.isEmpty && !route.isOpenCodeRoute {
            throw LatticeHermesProfileError.credentialInjectionNotAllowed
        }

        lock.lock()
        defer { lock.unlock() }
        try ensureHomeLocked()
        try atomicallyWrite(Data(Self.configurationYAML(for: route).utf8), to: configURL, mode: 0o600)
        try atomicallyWrite(Data(systemIdentity.utf8), to: soulURL, mode: 0o600)
        return readiness(runtimePresent: false)
    }

    public func ensureHome() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureHomeLocked()
    }

    public func isConfigured() -> Bool {
        guard LatticeStorePathSecurity.isRegularFileWithoutFollowingSymlinks(at: configURL),
              LatticeStorePathSecurity.isRegularFileWithoutFollowingSymlinks(at: soulURL),
              let config = try? LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(
                  at: configURL,
                  maximumByteCount: Self.maximumSystemIdentityByteCount
              ),
              let soul = try? LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(
                  at: soulURL,
                  maximumByteCount: Self.maximumSystemIdentityByteCount
              ) else { return false }
        return !config.isEmpty && !soul.isEmpty
    }

    public func readiness(
        runtimePresent: Bool,
        auth: LatticeHermesReadinessState = .unknown,
        catalog: LatticeHermesReadinessState = .unknown
    ) -> LatticeHermesReadiness {
        LatticeHermesReadiness(
            runtimePresent: runtimePresent,
            profileConfigured: isConfigured(),
            auth: auth,
            catalog: catalog
        )
    }

    /// Build child-process env from a non-secret allowlist. Parent provider
    /// credentials never cross this boundary. One selected OpenCode key may
    /// cross only as the provider-specific environment name required by Hermes.
    public func launchEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL,
        route: LatticeHermesWorkRoute? = nil,
        opencodeAPIKey: String? = nil
    ) throws -> [String: String] {
        if let opencodeAPIKey,
           !opencodeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           route?.isOpenCodeRoute != true {
            throw LatticeHermesProfileError.credentialInjectionNotAllowed
        }

        do { try ensureHome() } catch {
            throw LatticeHermesProfileError.invalidHome(homeURL.path)
        }
        let canonicalHome: URL
        do {
            canonicalHome = try LatticeStorePathSecurity.canonicalDirectory(at: homeURL)
        } catch {
            throw LatticeHermesProfileError.invalidHome(homeURL.path)
        }
        let canonicalTemporaryDirectory: URL
        do {
            canonicalTemporaryDirectory = try LatticeStorePathSecurity.canonicalDirectory(at: temporaryDirectory)
        } catch {
            throw LatticeHermesProfileError.invalidTemporaryDirectory(temporaryDirectory.path)
        }

        var environment: [String: String] = [:]
        let safeKeys = [
            "PATH", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TERM",
            "TERM_PROGRAM", "DISPLAY", "WAYLAND_DISPLAY"
        ]
        for key in safeKeys where base[key] != nil {
            environment[key] = base[key]
        }
        environment["HOME"] = canonicalHome.path
        environment["HERMES_HOME"] = canonicalHome.path
        environment["TMPDIR"] = canonicalTemporaryDirectory.path.hasSuffix("/")
            ? canonicalTemporaryDirectory.path
            : canonicalTemporaryDirectory.path + "/"
        if let route,
           let environmentKey = route.openCodeCredentialEnvironmentKey,
           let opencodeAPIKey = opencodeAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !opencodeAPIKey.isEmpty {
            environment[environmentKey] = opencodeAPIKey
        }
        return environment
    }

    public static func redactedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.mapValues { value in
            value
        }.reduce(into: [String: String]()) { result, entry in
            let key = entry.key.uppercased()
            result[entry.key] = key.contains("API_KEY") || key.contains("TOKEN") || key.contains("SECRET") || key.contains("PASSWORD") || key.contains("AUTH")
                ? "<redacted>"
                : entry.value
        }
    }

    public static func configurationYAML(for route: LatticeHermesWorkRoute) -> String {
        let policy = workToolPolicy
        let toolsets = policy.enabledToolsets.map { "    - \(yamlString($0))" }.joined(separator: "\n")
        let disabled = policy.disabledToolsets.map { "    - \(yamlString($0))" }.joined(separator: "\n")
        return """
        model:
          provider: \(yamlString(route.provider))
          default: \(yamlString(route.model))
        toolsets:
        \(toolsets)
        agent:
          disabled_toolsets:
        \(disabled)
        terminal:
          backend: local
        """
    }

    private func ensureHomeLocked() throws {
        do {
            let canonical = try LatticeStorePathSecurity.canonicalDirectory(at: homeURL)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: canonical.path)
        } catch let error as LatticeStorePathError {
            switch error {
            case .symlink, .notDirectory, .invalidPath, .outsideRoot, .notRegularFile:
                throw LatticeHermesProfileError.invalidHome(homeURL.path)
            default:
                throw LatticeHermesProfileError.writeFailed(error.localizedDescription)
            }
        } catch {
            throw LatticeHermesProfileError.writeFailed(error.localizedDescription)
        }
    }

    private func atomicallyWrite(_ data: Data, to url: URL, mode: Int) throws {
        do {
            let canonicalHome = try LatticeStorePathSecurity.canonicalDirectory(at: homeURL)
            try LatticeStorePathSecurity.writeDataAtomically(data, to: url, under: canonicalHome)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            if let profileError = error as? LatticeHermesProfileError { throw profileError }
            throw LatticeHermesProfileError.writeFailed(error.localizedDescription)
        }
    }

    private static func yamlString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
