import Foundation

public enum HarnessToolEventDecoder {
    public static func piEvent(from object: [String: Any], workspace: URL) -> AgentEvent? {
        guard let type = object["type"] as? String else { return diagnostic(provider: "Pi", object: object, reason: "Event is missing type.") }
        guard ["tool_execution_start", "tool_execution_update", "tool_execution_end"].contains(type) else {
            if ["message_update", "message_end", "agent_end", "extension_ui_request", "extension_error"].contains(type) { return nil }
            return diagnostic(provider: "Pi", object: object, reason: "Unsupported event.")
        }
        guard let externalID = object["toolCallId"] as? String, !externalID.isEmpty else { return diagnostic(provider: "Pi", object: object, reason: "Tool event is missing toolCallId.") }
        let id = stableID(for: "pi:\(externalID)")

        switch type {
        case "tool_execution_start":
            guard let toolName = object["toolName"] as? String, !toolName.isEmpty else { return diagnostic(provider: "Pi", object: object, reason: "Tool start is missing toolName.") }
            let input = object["args"] as? [String: Any] ?? [:]
            return .toolRequested(.init(
                id: id,
                kind: kind(for: toolName),
                title: "Pi is using \(displayName(toolName))",
                detail: detail(input: input, fallback: toolName),
                workspaceScoped: WorkspacePathScope.isWorkspaceScoped(input["path"] as? String, workspace: workspace),
                reversible: false
            ))
        case "tool_execution_update":
            return .toolProgress(id: id, fraction: 0.5, detail: "Running")
        case "tool_execution_end":
            guard let isError = object["isError"] as? Bool else {
                return .toolProgress(id: id, fraction: 1, detail: "Failed")
            }
            return .toolProgress(id: id, fraction: 1, detail: isError ? "Failed" : "Completed")
        default:
            return nil
        }
    }

    public static func hermesEvent(from object: [String: Any], workspace: URL) -> AgentEvent? {
        guard object["method"] as? String == "session/update" else { return nil }
        guard let params = object["params"] as? [String: Any], let update = params["update"] as? [String: Any], let type = update["sessionUpdate"] as? String else { return diagnostic(provider: "Hermes", object: object, reason: "Session update is malformed.") }
        if type == "agent_message_chunk" { return nil }
        guard let externalID = update["toolCallId"] as? String, !externalID.isEmpty else { return diagnostic(provider: "Hermes", object: update, reason: "Tool update is missing toolCallId.") }
        let id = stableID(for: "hermes:\(externalID)")

        switch type {
        case "tool_call":
            let rawInput = update["rawInput"] as? [String: Any] ?? [:]
            let locationMetadata = WorkspacePathScope.locationMetadata(in: update)
            let locations = locationMetadata.paths
            let detail = locations.isEmpty
                ? detail(input: rawInput, fallback: contentText(update["content"]) ?? "Tool call")
                : locations.joined(separator: ", ")
            let title = update["title"] as? String ?? "Hermes tool call"
            let kindName = update["kind"] as? String ?? title
            return .toolRequested(.init(
                id: id,
                kind: kind(for: kindName),
                title: title,
                detail: detail,
                workspaceScoped: WorkspacePathScope.isWorkspaceScoped(
                    rawInput: update["rawInput"],
                    locations: update["locations"],
                    workspace: workspace
                ),
                reversible: false
            ))
        case "tool_call_update":
            let fraction: Double
            let detail: String
            switch update["status"] as? String {
            case "pending", "in_progress": (fraction, detail) = (0.5, "Running")
            case "completed": (fraction, detail) = (1, "Completed")
            case "failed": (fraction, detail) = (1, "Failed")
            case "cancelled", "canceled": (fraction, detail) = (1, "Cancelled")
            default: (fraction, detail) = (1, "Failed")
            }
            return .toolProgress(id: id, fraction: fraction, detail: detail)
        default:
            return diagnostic(provider: "Hermes", object: update, reason: "Unsupported session update.")
        }
    }

    public static func malformedEvent(provider: String, byteCount: Int) -> AgentEvent { .providerDiagnostic(.init(provider: provider, reason: "Malformed JSON event payload (\(max(0, byteCount)) bytes).")) }

    public static func diagnostic(provider: String, object: [String: Any], reason: String) -> AgentEvent {
        .providerDiagnostic(.init(provider: provider, eventType: (object["type"] as? String) ?? (object["method"] as? String) ?? (object["sessionUpdate"] as? String), reason: reason, fields: object.keys.sorted()))
    }

    private static func detail(input: [String: Any], fallback: String) -> String {
        if let command = input["command"] as? String, !command.isEmpty { return String("$ \(command)".prefix(600)) }
        if let path = input["path"] as? String, !path.isEmpty { return String(path.prefix(600)) }
        guard !input.isEmpty, JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return String(fallback.prefix(600)) }
        return String(text.prefix(600))
    }

    private static func contentText(_ value: Any?) -> String? {
        guard let entries = value as? [[String: Any]] else { return nil }
        for entry in entries {
            if let text = entry["text"] as? String { return text }
            if let content = entry["content"] as? [String: Any], let text = content["text"] as? String { return text }
        }
        return nil
    }

    private static func kind(for rawName: String) -> ToolRequest.Kind {
        let name = rawName.lowercased()
        if name.contains("credential") || name.contains("secret") || name.contains("password") || name.contains("token") || name.contains("api key") || name.contains("keychain") {
            return .credential
        }
        if name.contains("delete") || name.contains("remove") { return .destructive }
        if name.contains("write") || name.contains("edit") || name.contains("patch") || name.contains("move") { return .write }
        if name.contains("bash") || name.contains("terminal") || name.contains("execute") || name.contains("command") { return .command }
        if name.contains("web") || name.contains("fetch") || name.contains("network") { return .network }
        if name.contains("browser") || name.contains("automation") { return .automation }
        let explicitReadNames = ["read", "read_file", "list", "list_files", "search", "grep", "glob", "find", "stat", "inspect", "view"]
        if explicitReadNames.contains(name) { return .read }
        return .unknown
    }

    private static func displayName(_ rawName: String) -> String {
        rawName.replacingOccurrences(of: "_", with: " ")
    }

    static func stableID(for value: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in value.utf8.enumerated() {
            let slot = index % bytes.count
            bytes[slot] = bytes[slot] &* 31 &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
