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

    static func isWorkspaceScoped(toolCall: [String: Any], workspace: URL?) -> Bool {
        guard let workspace else { return false }
        return isWorkspaceScoped(
            rawInput: toolCall["rawInput"],
            locations: toolCall["locations"],
            workspace: workspace
        )
    }

    static func isWorkspaceScoped(rawInput: Any?, locations: Any?, workspace: URL) -> Bool {
        let evidence = pathEvidence(rawInput: rawInput, locations: locations)
        guard !evidence.isEmpty else { return false }
        return evidence.allSatisfy { pathIsWorkspaceScoped($0, workspace: workspace) }
    }

    static func isWorkspaceScoped(_ path: String?, workspace: URL) -> Bool {
        pathIsWorkspaceScoped(path, workspace: workspace)
    }

    private static func pathEvidence(rawInput: Any?, locations: Any?) -> [String?] {
        var evidence: [String?] = []
        if let rawInput {
            guard let rawInput = rawInput as? [String: Any] else {
                return [nil] + locationEvidence(from: locations)
            }
            if rawInput.keys.contains("path") {
                evidence.append(rawInput["path"] as? String)
            }
        }
        evidence.append(contentsOf: locationEvidence(from: locations))
        return evidence
    }

    private static func locationEvidence(from value: Any?) -> [String?] {
        guard let value else { return [] }
        guard let locations = value as? [Any] else { return [nil] }
        return locations.map { location in
            guard let location = location as? [String: Any], location.keys.contains("path") else { return nil }
            return location["path"] as? String
        }
    }

    private static func pathIsWorkspaceScoped(_ path: String?, workspace: URL) -> Bool {
        guard let path, isSupportedPOSIXPathEvidence(path), workspace.isFileURL else { return false }
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard !root.isEmpty, !candidate.isEmpty else { return false }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func isSupportedPOSIXPathEvidence(_ path: String) -> Bool {
        guard !path.isEmpty,
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.contains("\\"),
              !path.hasPrefix("~"),
              !path.hasPrefix("//") else { return false }

        if path.count >= 2,
           let first = path.unicodeScalars.first,
           first.properties.isAlphabetic,
           path.unicodeScalars.dropFirst().first == ":" {
            return false
        }
        if let colon = path.firstIndex(of: ":") {
            let scheme = path[..<colon]
            guard let first = scheme.unicodeScalars.first,
                  first.properties.isAlphabetic,
                  scheme.unicodeScalars.dropFirst().allSatisfy({
                      $0.properties.isAlphabetic || (48...57).contains($0.value) || $0 == "+" || $0 == "-" || $0 == "."
                  }) else { return true }
            return false
        }
        return true
    }
}
