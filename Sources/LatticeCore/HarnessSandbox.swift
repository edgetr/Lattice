import Darwin
import Foundation

public enum HarnessSandboxError: LocalizedError, Sendable {
    case unavailable
    case invalidWritableDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Lattice cannot enable write-capable tools because the macOS workspace sandbox is unavailable."
        case .invalidWritableDirectory(let path):
            "Lattice cannot sandbox a missing or invalid writable directory: \(path)"
        }
    }
}

public enum HarnessSandbox {
    public static let systemExecutableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    public struct LaunchConfiguration: Sendable, Equatable {
        public let executableURL: URL
        public let arguments: [String]

        public init(executableURL: URL, arguments: [String]) {
            self.executableURL = executableURL
            self.arguments = arguments
        }
    }

    public static func writeRestrictedLaunch(
        command: URL,
        arguments: [String],
        writableDirectories: [URL],
        writablePaths: [URL] = [],
        sandboxExecutableURL: URL? = systemExecutableURL
    ) throws -> LaunchConfiguration {
        guard let sandboxExecutableURL,
              FileManager.default.isExecutableFile(atPath: sandboxExecutableURL.path) else {
            throw HarnessSandboxError.unavailable
        }
        let profile = try writeRestrictedProfile(
            writableDirectories: writableDirectories,
            writablePaths: writablePaths
        )
        return LaunchConfiguration(
            executableURL: sandboxExecutableURL,
            arguments: ["-p", profile, command.path] + arguments
        )
    }

    public static func writeRestrictedProfile(
        writableDirectories: [URL],
        writablePaths: [URL] = []
    ) throws -> String {
        let directories = try canonicalWritableDirectories(writableDirectories)
        let paths = writablePaths.map(canonicalPathForPotentialFile)
        let directoryRules = directories.map { "(subpath \"\(escape($0))\")" }
        let pathRules = paths.flatMap { ["(literal \"\(escape($0))\")", "(subpath \"\(escape($0))\")"] }
        let writeRules = (["(literal \"/dev/null\")"] + directoryRules + pathRules).joined(separator: " ")
        return """
        (version 1)
        (deny default)
        (allow process*)
        (allow file-read*)
        (allow file-write* \(writeRules))
        (allow network*)
        (allow mach*)
        (allow ipc*)
        (allow signal)
        (allow sysctl-read)
        (allow system*)
        (allow user-preference-read)
        (allow iokit-open)
        """
    }

    public static func canonicalDirectory(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let path = realPath(standardized.path) else {
            throw HarnessSandboxError.invalidWritableDirectory(url.path)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func canonicalWritableDirectories(_ urls: [URL]) throws -> [String] {
        var seen = Set<String>()
        return try urls.compactMap { url in
            let path = try canonicalDirectory(url).path
            return seen.insert(path).inserted ? path : nil
        }
    }

    private static func canonicalPathForPotentialFile(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let canonicalParent = realPath(parent.path) ?? parent.resolvingSymlinksInPath().path
        return URL(fileURLWithPath: canonicalParent, isDirectory: true).appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
