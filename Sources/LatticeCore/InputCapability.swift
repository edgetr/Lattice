import Foundation

public enum ModelInputModality: String, Codable, Sendable, Hashable {
    case text
    case image
}

public enum InputCapabilitySupport: String, Codable, Sendable, Hashable {
    case supported
    case unsupported
    case unknown
}

public struct ImageInputCapability: Equatable, Sendable {
    public let support: InputCapabilitySupport
    public let unavailableReason: String?

    public init(support: InputCapabilitySupport, unavailableReason: String? = nil) {
        self.support = support
        self.unavailableReason = unavailableReason
    }

    public static func resolve(
        route: ExecutionRoute,
        model: ProviderModel?,
        protocolSupport: InputCapabilitySupport
    ) -> ImageInputCapability {
        guard route.runtimeID == "codex" else {
            return .init(
                support: .unsupported,
                unavailableReason: "Image input is not supported by the current structured \(route.runtimeID) route. Choose a Codex model that advertises image input or remove the image."
            )
        }
        guard protocolSupport == .supported else {
            let reason = protocolSupport == .unsupported
                ? "This Codex app-server does not support structured local image input. Update Codex or remove the image."
                : "Codex image-input protocol support has not been verified. Refresh Connections, update Codex if needed, or remove the image."
            return .init(support: protocolSupport, unavailableReason: reason)
        }
        guard let model else {
            return .init(support: .unknown, unavailableReason: "The selected Codex model was not found in the current runtime catalog. Refresh Connections or remove the image.")
        }
        guard let modalities = model.inputModalities else {
            return .init(support: .unknown, unavailableReason: "The selected Codex model did not advertise input modalities. Choose an image-capable model or remove the image.")
        }
        guard modalities.contains(.image) else {
            return .init(support: .unsupported, unavailableReason: "The selected Codex model does not advertise image input. Choose an image-capable model or remove the image.")
        }
        return .init(support: .supported)
    }
}

public enum ExecutionInputAttachmentPolicy {
    public static let maximumImageCount = 8
    public static let maximumTotalImageBytes: Int64 = 50 * 1_048_576

    public static func unavailableReason(
        attachments: [ContextAttachment],
        capability: ImageInputCapability,
        inspector: any ContextAttachmentInspecting = FileContextAttachmentInspector(),
        limits: ContextAttachmentValidationPolicy = .default
    ) -> String? {
        let images = attachments.filter(\.isImage)
        guard !images.isEmpty else { return nil }
        guard capability.support == .supported else {
            return capability.unavailableReason ?? "Image input is unavailable for this route. Remove the image or choose a compatible route."
        }
        guard images.count <= maximumImageCount else {
            return "Attach at most \(maximumImageCount) images per request."
        }
        var totalImageBytes: Int64 = 0
        for persisted in images {
            let trimmedPath = persisted.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPath.hasPrefix("/"), !trimmedPath.contains("://") else {
                return "Image “\(persisted.name)” is not a valid local file reference. Reattach it before sending."
            }
            let current = ContextAttachment.inspecting(
                path: persisted.path,
                source: persisted.source,
                id: persisted.id,
                inspector: inspector
            )
            if current.isMissing {
                return "Image “\(persisted.name)” is missing or unreadable. Reattach it before sending."
            }
            guard current.isImage else {
                return "Attachment “\(persisted.name)” is no longer recognized as an image. Reattach a supported image file."
            }
            if let byteCount = current.byteCount {
                let (nextTotal, overflow) = totalImageBytes.addingReportingOverflow(byteCount)
                guard !overflow, nextTotal <= maximumTotalImageBytes else {
                    return "Attached images exceed the \(ByteCountFormatter.string(fromByteCount: maximumTotalImageBytes, countStyle: .file)) total limit. Remove or resize images."
                }
                totalImageBytes = nextTotal
            }
            for issue in ContextAttachmentValidator.issues(for: current, limits: limits) {
                switch issue {
                case .missing:
                    return "Image “\(persisted.name)” is missing or unreadable. Reattach it before sending."
                case .oversizeBytes(_, let limit):
                    return "Image “\(persisted.name)” exceeds the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) limit. Choose a smaller image."
                case .oversizePixels(_, _, let limit):
                    return "Image “\(persisted.name)” exceeds the \(limit)-pixel edge limit. Resize it before sending."
                }
            }
        }
        return nil
    }
}
