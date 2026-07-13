import Foundation

public final class StructuredCLIHarness: @unchecked Sendable {
    public enum Kind: String, Sendable { case grok, openCode }

    public let kind: Kind
    private let executableURL: URL?

    public init(kind: Kind, executableURL: URL? = nil) {
        self.kind = kind
        self.executableURL = executableURL ?? ExecutableDiscovery.locate(kind == .grok ? "grok" : "opencode")
    }

    public var isInstalled: Bool { executableURL != nil }

    public func isAuthenticated() async -> Bool {
        guard let executableURL else { return false }
        let result = await Self.run(executableURL, arguments: kind == .grok ? ["models"] : ["auth", "list"])
        guard result.isSuccess else { return false }
        let text = String(decoding: result.combinedOutput, as: UTF8.self)
        return kind == .grok ? text.contains("You are logged in") : text.contains("Credentials") && text.contains("●")
    }

    public func login() async -> Bool {
        guard let executableURL else { return false }
        let arguments = kind == .grok ? ["login"] : ["auth", "login"]
        return await Self.run(executableURL, arguments: arguments).isSuccess
    }

    public func cliVersion() async -> String? {
        guard let executableURL else { return nil }
        let result = await Self.run(executableURL, arguments: ["--version"])
        guard result.isSuccess else { return nil }
        return Self.parseVersion(String(decoding: result.combinedOutput, as: UTF8.self), kind: kind)
    }

    public func updateStatus() async -> CLIUpdateInfo {
        guard kind == .grok, let executableURL else {
            return CLIUpdateInfo(currentVersion: await cliVersion(), detail: "Update status unavailable")
        }
        let result = await Self.run(executableURL, arguments: ["update", "--check", "--json"])
        guard result.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: result.combinedOutput) as? [String: Any] else {
            return CLIUpdateInfo(currentVersion: await cliVersion(), detail: "Update check failed")
        }
        let notes = (object["releaseNotes"] as? String) ?? (object["notes"] as? String) ?? (object["changelog"] as? String)
        return CLIUpdateInfo(
            currentVersion: object["currentVersion"] as? String,
            latestVersion: object["latestVersion"] as? String,
            updateAvailable: object["updateAvailable"] as? Bool,
            releaseNotes: notes,
            detail: object["error"] as? String
        )
    }

    public func updateCLI() async -> Bool {
        guard let executableURL else { return false }
        let arguments = kind == .grok ? ["update"] : ["upgrade"]
        return await Self.run(executableURL, arguments: arguments).isSuccess
    }

    public func models(refreshCache: Bool = false) async -> [ProviderModel] {
        await modelsResult(refreshCache: refreshCache).models
    }

    public func modelsResult(refreshCache: Bool = false) async -> ProviderCatalogResult<ProviderModel> {
        guard let executableURL else { return .unknown() }
        if kind == .openCode {
            if refreshCache {
                _ = await Self.run(executableURL, arguments: ["models", "--refresh"])
            }
            async let free = Self.run(executableURL, arguments: ["models", "opencode", "--verbose"])
            async let go = Self.run(executableURL, arguments: ["models", "opencode-go", "--verbose"])
            let (freeResult, goResult) = await (free, go)
            let results = [freeResult, goResult]
            let successful = results.filter(\.isSuccess)
            let models = successful.flatMap { Self.parseOpenCodeModels($0.combinedOutput) }
            let status: ProviderCatalogStatus = if !models.isEmpty {
                .loaded
            } else if successful.count == results.count {
                .empty
            } else {
                .failed
            }
            return ProviderCatalogResult(models: models, status: status)
        }
        let result = await Self.run(executableURL, arguments: ["models"])
        guard result.isSuccess else { return ProviderCatalogResult(models: [], status: .failed) }
        return ProviderCatalogResult(models: Self.parseModels(result.combinedOutput, kind: kind), succeeded: true)
    }

    public static func parseModels(_ data: Data, kind: Kind) -> [ProviderModel] {
        switch kind {
        case .grok: return parseGrokModels(data)
        case .openCode: return parseOpenCodeModels(data)
        }
    }

    private static func run(_ executable: URL, arguments: [String]) async -> BoundedSubprocessResult {
        await BoundedSubprocess.run(.init(
            executableURL: executable,
            arguments: arguments,
            deadline: 30,
            maximumOutputBytes: BoundedSubprocessRequest.defaultMaximumOutputBytes
        ))
    }

    private static func parseGrokModels(_ data: Data) -> [ProviderModel] {
        let structured = extractJSONObjects(data).compactMap { object -> ProviderModel? in
            guard let id = object["id"] as? String ?? object["model"] as? String else { return nil }
            let name = object["name"] as? String ?? object["displayName"] as? String ?? id
            let options = reasoningEfforts(from: object).map { ReasoningOption(effort: $0) }
            let defaultEffort = (object["defaultReasoningEffort"] as? String).flatMap(ReasoningEffort.init(rawValue:))
                ?? [.medium, .thinking, .high, .max, .low, .minimal, .none].compactMap { preferred in options.first(where: { $0.effort == preferred })?.effort }.first
            return ProviderModel(id: id, name: name, reasoningOptions: options, defaultReasoningEffort: defaultEffort, contextWindow: ProviderModelMetadata.contextWindow(from: object), isDefault: object["isDefault"] as? Bool ?? false)
        }
        if !structured.isEmpty { return structured }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> ProviderModel? in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("- ") || value.hasPrefix("* ") else { return nil }
            let isDefault = value.hasPrefix("* ")
            let id = value.dropFirst(2).replacingOccurrences(of: " (default)", with: "")
            return ProviderModel(id: id, name: id, isDefault: isDefault)
        }
    }

    private static func parseOpenCodeModels(_ data: Data) -> [ProviderModel] {
        var models: [ProviderModel] = []
        for object in extractJSONObjects(data) {
            guard let id = object["id"] as? String, let provider = object["providerID"] as? String, let name = object["name"] as? String else { continue }
            let efforts = reasoningEfforts(from: object)
            let options = efforts.map { ReasoningOption(effort: $0) }
            let defaultEffort = [.medium, .thinking, .high, .max, .low, .none].compactMap { preferred in options.first(where: { $0.effort == preferred })?.effort }.first
            models.append(ProviderModel(id: "\(provider)/\(id)", name: name, reasoningOptions: options, defaultReasoningEffort: defaultEffort, contextWindow: ProviderModelMetadata.contextWindow(from: object)))
        }
        return models
    }

    private static func reasoningEfforts(from object: [String: Any]) -> [ReasoningEffort] {
        if let rawOptions = object["reasoningOptions"] as? [String] {
            return rawOptions.compactMap(ReasoningEffort.init(rawValue:)).sorted { reasoningSortIndex($0) < reasoningSortIndex($1) }
        }
        if let rawEfforts = object["reasoningEfforts"] as? [String] {
            return rawEfforts.compactMap(ReasoningEffort.init(rawValue:)).sorted { reasoningSortIndex($0) < reasoningSortIndex($1) }
        }
        let variants = object["variants"] as? [String: Any] ?? [:]
        return variants.compactMap { key, value -> ReasoningEffort? in
            if let effort = ReasoningEffort(rawValue: key) { return effort }
            if let object = value as? [String: Any],
               let raw = object["reasoningEffort"] as? String,
               let effort = ReasoningEffort(rawValue: raw) { return effort }
            return nil
        }
        .sorted { lhs, rhs in reasoningSortIndex(lhs) < reasoningSortIndex(rhs) }
    }

    private static func reasoningSortIndex(_ effort: ReasoningEffort) -> Int {
        switch effort {
        case .none: 0
        case .minimal: 1
        case .low: 2
        case .medium: 3
        case .high: 4
        case .xhigh: 5
        case .max: 6
        case .thinking: 7
        }
    }

    private static func parseVersion(_ output: String, kind: Kind) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch kind {
        case .grok:
            let parts = value.split(separator: " ")
            return parts.count >= 2 ? String(parts[1]) : value
        case .openCode:
            guard let firstLine = value.split(separator: "\n").first else { return value }
            let parts = firstLine.split(separator: " ")
            return parts.last.map(String.init) ?? String(firstLine)
        }
    }

    private static func extractJSONObjects(_ data: Data) -> [[String: Any]] {
        let bytes = [UInt8](data); var results: [[String: Any]] = []
        var start: Int?; var depth = 0; var inString = false; var escaped = false
        for (index, byte) in bytes.enumerated() {
            if start == nil { if byte == 0x7B { start = index; depth = 1 }; continue }
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
                continue
            }
            if byte == 0x22 { inString = true }
            else if byte == 0x7B { depth += 1 }
            else if byte == 0x7D {
                depth -= 1
                if depth == 0 {
                    if let objectStart = start {
                        let slice = Data(bytes[objectStart...index])
                        if let object = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] { results.append(object) }
                    }
                    start = nil
                }
            }
        }
        return results
    }
}
