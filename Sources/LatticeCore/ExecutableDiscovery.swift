import Foundation

public enum ExecutableDiscovery {
    public static func locate(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let userToolDirectories = [
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.opencode/bin",
            NSHomeDirectory() + "/.grok/bin",
            NSHomeDirectory() + "/.hermes/bin",
            NSHomeDirectory() + "/.bun/bin",
            NSHomeDirectory() + "/Library/pnpm"
        ]
        let searchPath = userToolDirectories + (path ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init) + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/bin",
            "/usr/bin"
        ]
        for directory in searchPath {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }
}
