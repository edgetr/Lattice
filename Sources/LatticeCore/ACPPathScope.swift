import Foundation

enum ACPPathScope {
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
        guard let path else { return false }
        return pathIsWorkspaceScoped(path, workspace: workspace)
    }

    private static func pathEvidence(rawInput: Any?, locations: Any?) -> [String?] {
        var evidence: [String?] = []

        if let rawInput {
            guard let rawInput = rawInput as? [String: Any] else {
                evidence.append(nil)
                return evidence + locationEvidence(from: locations)
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
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              workspace.isFileURL else { return false }

        let rootURL = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let candidateURL = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let root = rootURL.path
        let candidate = candidateURL.path
        guard !root.isEmpty, !candidate.isEmpty else { return false }
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}
