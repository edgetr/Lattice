import Foundation

/// Resolves the Lattice-owned Code engine binary (Pi-based “Lattice Agent”).
///
/// Resolution order:
/// 1. `LATTICE_AGENT_EXECUTABLE` env override (absolute path to an executable)
/// 2. App-bundle resource (`Contents/MacOS/LatticeAgent` or `Contents/Resources/Runtimes/LatticeAgent`)
/// 3. Lattice-managed Application Support install (`Runtimes/LatticeAgent/…`)
/// 4. PATH `pi` — **debug / explicit allow only**; never used for packaged release discovery
///
/// Profile/auth state stays under `HarnessRuntime/Pi` via `PI_CODING_AGENT_DIR` and is never `~/.pi`.
public enum LatticeAgentExecutable {
    public static let productDisplayName = "Lattice Agent"
    public static let envOverrideKey = "LATTICE_AGENT_EXECUTABLE"
    public static let bundledBinaryName = "LatticeAgent"
    public static let managedRuntimeDirectoryName = "Runtimes/LatticeAgent"
    public static let npmPackageName = "@earendil-works/pi-coding-agent"

    /// Whether PATH discovery of ambient `pi` is allowed.
    /// Packaged app builds fail closed; debug builds and tests may opt in.
    public static var allowsPathFallback: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static func managedInstallRoot(
        applicationSupport: URL = LatticeApplicationSupport.productRootURL()
    ) -> URL {
        applicationSupport.appendingPathComponent(managedRuntimeDirectoryName, isDirectory: true)
    }

    /// npm/pnpm prefix install places the CLI at `node_modules/.bin/pi`.
    public static func managedExecutableURL(
        applicationSupport: URL = LatticeApplicationSupport.productRootURL()
    ) -> URL? {
        let root = managedInstallRoot(applicationSupport: applicationSupport)
        let bin = root.appendingPathComponent("node_modules/.bin/pi").standardizedFileURL
        if FileManager.default.isExecutableFile(atPath: bin.path) {
            return bin
        }
        // Some prefix installs leave the shim non-executable until npm finishes; accept a present shim and chmod.
        if FileManager.default.fileExists(atPath: bin.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            if FileManager.default.isExecutableFile(atPath: bin.path) {
                return bin
            }
        }
        return nil
    }

    public static func bundledExecutableURL(bundle: Bundle = .main) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let macos = bundle.executableURL?.deletingLastPathComponent() {
            candidates.append(macos.appendingPathComponent(bundledBinaryName))
        }
        if let resources = bundle.resourceURL {
            candidates.append(
                resources
                    .appendingPathComponent("Runtimes", isDirectory: true)
                    .appendingPathComponent(bundledBinaryName)
            )
        }
        // Bundle.main.bundlePath/Contents/MacOS when executableURL is the app binary
        let contents = URL(fileURLWithPath: bundle.bundlePath, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        candidates.append(contents.appendingPathComponent("MacOS/\(bundledBinaryName)"))
        candidates.append(contents.appendingPathComponent("Resources/Runtimes/\(bundledBinaryName)"))

        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            if fileManager.isExecutableFile(atPath: standardized.path) {
                return standardized
            }
        }
        return nil
    }

    public static func environmentOverrideURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = environment[envOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw).standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Resolve the engine executable for launch and readiness.
    public static func resolve(
        bundle: Bundle = .main,
        applicationSupport: URL = LatticeApplicationSupport.productRootURL(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowPathFallback: Bool = allowsPathFallback,
        pathLocator: (String) -> URL? = { ExecutableDiscovery.locate($0) }
    ) -> URL? {
        if let override = environmentOverrideURL(environment: environment) {
            return override
        }
        if let bundled = bundledExecutableURL(bundle: bundle) {
            return bundled
        }
        if let managed = managedExecutableURL(applicationSupport: applicationSupport) {
            return managed
        }
        if allowPathFallback {
            return pathLocator("pi")
        }
        return nil
    }

    public static var isAvailable: Bool { resolve() != nil }

    public static let missingRuntimeMessage =
        "Set up Lattice Agent in Connections. Lattice uses an isolated engine profile and does not use your personal Pi install."

    public static let notInstalledErrorMessage =
        "Lattice Agent is not available. Install it from Connections or reinstall Lattice."
}
