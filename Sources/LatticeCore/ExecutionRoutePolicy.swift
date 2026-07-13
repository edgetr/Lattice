import Foundation

public enum ExecutionRoutePolicy {
    public static let qualifiedEngineIDs: Set<String> = ["codex", "opencode", "grok", "antigravity", "ollama", "apple"]
    public static let qualifiedHarnessIDs: Set<String> = ["codex", "opencode", "grok", "antigravity", "pi", "hermes", "lattice"]

    public static func compatibleHarnessIDs(for engineID: String) -> Set<String> {
        switch engineID {
        case "codex": ["codex", "pi"]
        case "opencode": ["opencode", "pi", "hermes"]
        case "grok": ["grok"]
        case "antigravity": ["antigravity"]
        case "ollama": ["lattice"]
        case "apple": ["lattice"]
        default: []
        }
    }

    public static func compatibleEngineIDs(for harnessID: String) -> Set<String> {
        Set(qualifiedEngineIDs.filter { compatibleHarnessIDs(for: $0).contains(harnessID) })
    }

    public static func defaultHarnessID(for engineID: String) -> String? {
        switch engineID {
        case "codex": "codex"
        case "opencode": "opencode"
        case "grok": "grok"
        case "antigravity": "antigravity"
        case "ollama", "apple": "lattice"
        default: nil
        }
    }

    public static func normalize(
        _ route: EngineHarnessSelection?,
        fallbackEngineID: String,
        fallbackHarnessID: String
    ) -> EngineHarnessSelection? {
        guard let route else { return nil }
        guard qualifiedEngineIDs.contains(route.engineID) else {
            return EngineHarnessSelection(engineID: fallbackEngineID, harnessID: fallbackHarnessID)
        }
        guard qualifiedHarnessIDs.contains(route.harnessID) else {
            return EngineHarnessSelection(engineID: route.engineID, harnessID: defaultHarnessID(for: route.engineID) ?? fallbackHarnessID)
        }
        guard compatibleHarnessIDs(for: route.engineID).contains(route.harnessID) else {
            return EngineHarnessSelection(engineID: route.engineID, harnessID: defaultHarnessID(for: route.engineID) ?? fallbackHarnessID)
        }
        return route
    }
}
