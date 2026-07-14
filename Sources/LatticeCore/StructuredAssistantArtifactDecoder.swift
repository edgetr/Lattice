import Foundation

/// Shared, explicit-path decoder for structured provider envelopes.
///
/// This intentionally does **not** parse Markdown, recurse nested JSON, or invent
/// path discovery. Callers supply only typed top-level fields that their contract
/// documents (for example Codex `path` / `savedPath`, or an explicit `imagePath`
/// on a structured tool-result envelope).
public enum StructuredAssistantArtifactDecoder {
    /// Known top-level keys that mean "local image path" when present as a String.
    public static let explicitImagePathKeys = ["imagePath", "savedPath", "artifactPath"]

    public static func explicitImagePath(in object: [String: Any]) -> String? {
        for key in explicitImagePathKeys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Builds an artifact event or a metadata-only diagnostic. Never retains rejected path/payload values.
    public static func artifactEvent(
        path: String,
        provider: String,
        origin: AssistantArtifact.Origin,
        eventID: String?,
        workspace: URL,
        applicationSupportRoot: URL,
        probe: AssistantImageArtifactPolicy.FileProbe = .default,
        artifactID: UUID = UUID()
    ) -> AgentEvent {
        let outcome = AssistantImageArtifactPolicy.validate(
            path: path,
            workspace: workspace,
            applicationSupportRoot: applicationSupportRoot,
            probe: probe
        )
        let provenance = AssistantArtifact.Provenance(
            provider: provider,
            origin: origin,
            eventID: eventID
        )
        if let observation = AssistantImageArtifactPolicy.observation(
            from: outcome,
            id: artifactID,
            provenance: provenance
        ) {
            return .artifact(observation)
        }
        let reason: String
        if case .rejected(let rejection) = outcome {
            reason = "Image artifact path was rejected (\(rejection.rawValue))."
        } else {
            reason = "Image artifact path was rejected."
        }
        // Metadata only — never include the rejected path or any payload bytes.
        return HarnessToolEventDecoder.diagnostic(
            provider: provider,
            object: [
                "type": "artifact",
                "origin": origin.rawValue
            ],
            reason: reason
        )
    }

    /// Optional hook for structured tool-result envelopes that already expose an explicit image path field.
    /// Returns nil when the envelope has no explicit path key (most tool results).
    public static func toolResultArtifactEvent(
        from envelope: [String: Any],
        provider: String,
        eventID: String?,
        workspace: URL,
        applicationSupportRoot: URL,
        probe: AssistantImageArtifactPolicy.FileProbe = .default
    ) -> AgentEvent? {
        guard let path = explicitImagePath(in: envelope) else { return nil }
        return artifactEvent(
            path: path,
            provider: provider,
            origin: .structuredToolResult,
            eventID: eventID,
            workspace: workspace,
            applicationSupportRoot: applicationSupportRoot,
            probe: probe
        )
    }
}
