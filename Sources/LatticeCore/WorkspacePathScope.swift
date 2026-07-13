import Foundation

enum WorkspacePathScope {
    struct LocationMetadata {
        let paths: [String]
        let isMalformed: Bool
    }

    static func locationMetadata(in object: [String: Any]) -> LocationMetadata {
        guard let rawLocations = object["locations"] else {
            return LocationMetadata(paths: [], isMalformed: false)
        }
        guard let entries = rawLocations as? [Any] else {
            return LocationMetadata(paths: [], isMalformed: true)
        }
        guard !entries.isEmpty else {
            return LocationMetadata(paths: [], isMalformed: false)
        }

        var paths: [String] = []
        var isMalformed = false
        for entry in entries {
            guard let location = entry as? [String: Any],
                  let path = location["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                isMalformed = true
                continue
            }
            paths.append(path)
        }
        return LocationMetadata(paths: paths, isMalformed: isMalformed)
    }

    static func isWorkspaceScoped(_ path: String?, workspace: URL) -> Bool {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}
