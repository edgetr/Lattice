import Foundation

/// Decision for whether attachments may be transported to a model/route.
public enum AttachmentTransportDecision: Equatable, Sendable {
    case allowed
    case blocked(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var reason: String? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }
}

/// Pure policy: never claim image support unless the model advertises image input.
public enum AttachmentTransportPolicy {
    public static let imagesNotAdvertisedReason =
        "This model does not advertise image input. Remove image attachments or choose a model that lists image support."
    public static let imagesUnknownReason =
        "This model has not advertised input modalities. Remove image attachments or choose a model with confirmed image support."

    public static func evaluate(
        attachments: [ContextAttachment],
        model: ProviderModel
    ) -> AttachmentTransportDecision {
        evaluate(attachments: attachments, inputModalities: model.inputModalities, modelName: model.name)
    }

    public static func evaluate(
        attachments: [ContextAttachment],
        inputModalities: Set<ModelInputModality>?,
        modelName: String? = nil
    ) -> AttachmentTransportDecision {
        let imageAttachments = attachments.filter { attachment in
            !attachment.isMissing && (attachment.isImage || attachment.imageMetadata != nil)
        }
        guard !imageAttachments.isEmpty else { return .allowed }

        guard let modalities = inputModalities, !modalities.isEmpty else {
            let label = modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let label, !label.isEmpty {
                return .blocked(reason: "\(label) has not advertised input modalities. Remove image attachments or choose a model with confirmed image support.")
            }
            return .blocked(reason: imagesUnknownReason)
        }
        guard modalities.contains(.image) else {
            let label = modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let label, !label.isEmpty {
                return .blocked(reason: "\(label) does not advertise image input. Remove image attachments or choose a model that lists image support.")
            }
            return .blocked(reason: imagesNotAdvertisedReason)
        }
        return .allowed
    }
}
