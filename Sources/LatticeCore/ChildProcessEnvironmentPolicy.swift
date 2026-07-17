import Foundation

/// Builds provider child environments from an explicit, non-secret allowlist.
/// Provider-owned CLIs may still read their own credential stores from HOME,
/// but unrelated parent-process tokens never cross the launch boundary.
public enum ChildProcessEnvironmentPolicy {
    public static let allowedParentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
        "TERM", "TERM_PROGRAM", "DISPLAY", "WAYLAND_DISPLAY",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"
    ]

    public static func providerOwnedRuntime(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [String: String] {
        var environment = allowedParentKeys.reduce(into: [String: String]()) { result, key in
            if let value = base[key], !value.isEmpty { result[key] = value }
        }
        environment["TMPDIR"] = temporaryDirectory.path.hasSuffix("/")
            ? temporaryDirectory.path
            : temporaryDirectory.path + "/"
        return environment
    }
}
