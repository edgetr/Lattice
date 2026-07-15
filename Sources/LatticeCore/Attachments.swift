import Foundation

/// Typed multimodal attachment role for context inputs.
public enum ContextAttachmentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case image
    case file
}

/// How an attachment entered Lattice. Legacy/imported values preserve pre-metadata archives.
public enum ContextAttachmentSource: String, Codable, Sendable, Hashable, CaseIterable {
    case picker
    case drop
    case paste
    case screenshot
    /// Constructed or decoded without explicit provenance (pre-metadata archives / legacy callers).
    case legacy
    /// Portable-archive or other import token that must not be resolved on disk.
    case imported
}

/// Pixel size when image metadata can be read without decoding full pixel buffers.
public struct ContextAttachmentPixelDimensions: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var longestEdge: Int { max(width, height) }
}

/// How an attachment image entered Lattice context.
public enum ContextAttachmentImageSource: String, Codable, Sendable, Hashable {
    case existingFile
    case clipboard
    case regionCapture
    case windowCapture
}

/// Explicit image-only fallback when authorized accessibility context is absent.
public struct ContextAttachmentImageOnlyFallback: Hashable, Codable, Sendable, Equatable {
    public var isImageOnly: Bool
    public var reason: String?

    public init(isImageOnly: Bool = false, reason: String? = nil) {
        self.isImageOnly = isImageOnly
        self.reason = isImageOnly ? reason : nil
    }

    public static let none = ContextAttachmentImageOnlyFallback(isImageOnly: false, reason: nil)

    public static func imageOnly(reason: String) -> ContextAttachmentImageOnlyFallback {
        ContextAttachmentImageOnlyFallback(isImageOnly: true, reason: reason)
    }
}

/// Optional typed metadata for image attachments, including Lattice-managed captures.
///
/// Accessibility text is never retained unless `accessibilityTextAuthorized` is true.
public struct ContextAttachmentImageMetadata: Hashable, Codable, Sendable, Equatable {
    public static let maxAccessibilityTextLength = 4_000

    /// When true, the file lives under Lattice-managed capture storage and cleanup may delete it.
    public var isLatticeManaged: Bool
    public var source: ContextAttachmentImageSource
    public var capturedAt: Date?
    /// User explicitly opted into attaching app/window identity for this image.
    public var contextMetadataAuthorized: Bool
    public var frontmostApplicationName: String?
    public var frontmostApplicationBundleID: String?
    public var frontmostWindowTitle: String?
    /// User-authorized inclusion of accessibility text for this capture.
    public var accessibilityTextAuthorized: Bool
    /// Bounded accessibility text; always nil unless authorized.
    public var accessibilityText: String?
    public var imageOnlyFallback: ContextAttachmentImageOnlyFallback

    public init(
        isLatticeManaged: Bool = false,
        source: ContextAttachmentImageSource = .existingFile,
        capturedAt: Date? = nil,
        contextMetadataAuthorized: Bool = false,
        frontmostApplicationName: String? = nil,
        frontmostApplicationBundleID: String? = nil,
        frontmostWindowTitle: String? = nil,
        accessibilityTextAuthorized: Bool = false,
        accessibilityText: String? = nil,
        imageOnlyFallback: ContextAttachmentImageOnlyFallback = .none
    ) {
        self.isLatticeManaged = isLatticeManaged
        self.source = source
        self.capturedAt = capturedAt
        self.contextMetadataAuthorized = contextMetadataAuthorized
        self.frontmostApplicationName = contextMetadataAuthorized ? Self.boundedOptional(frontmostApplicationName, max: 256) : nil
        self.frontmostApplicationBundleID = contextMetadataAuthorized ? Self.boundedOptional(frontmostApplicationBundleID, max: 256) : nil
        self.frontmostWindowTitle = contextMetadataAuthorized ? Self.boundedOptional(frontmostWindowTitle, max: 512) : nil
        self.accessibilityTextAuthorized = contextMetadataAuthorized && accessibilityTextAuthorized
        if self.accessibilityTextAuthorized {
            self.accessibilityText = Self.boundedOptional(accessibilityText, max: Self.maxAccessibilityTextLength)
        } else {
            self.accessibilityText = nil
        }
        if self.accessibilityText != nil {
            self.imageOnlyFallback = .none
        } else {
            self.imageOnlyFallback = imageOnlyFallback
        }
    }

    public var isCapture: Bool {
        switch source {
        case .clipboard, .regionCapture, .windowCapture:
            return true
        case .existingFile:
            return isLatticeManaged
        }
    }

    private enum CodingKeys: String, CodingKey {
        case isLatticeManaged, source, capturedAt, contextMetadataAuthorized
        case frontmostApplicationName, frontmostApplicationBundleID, frontmostWindowTitle
        case accessibilityTextAuthorized, accessibilityText, imageOnlyFallback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let authorized = try container.decodeIfPresent(Bool.self, forKey: .accessibilityTextAuthorized) ?? false
        let decodedText = try container.decodeIfPresent(String.self, forKey: .accessibilityText)
        let fallback = try container.decodeIfPresent(ContextAttachmentImageOnlyFallback.self, forKey: .imageOnlyFallback) ?? .none
        self.init(
            isLatticeManaged: try container.decodeIfPresent(Bool.self, forKey: .isLatticeManaged) ?? false,
            source: try container.decodeIfPresent(ContextAttachmentImageSource.self, forKey: .source) ?? .existingFile,
            capturedAt: try container.decodeIfPresent(Date.self, forKey: .capturedAt),
            contextMetadataAuthorized: try container.decodeIfPresent(Bool.self, forKey: .contextMetadataAuthorized) ?? false,
            frontmostApplicationName: try container.decodeIfPresent(String.self, forKey: .frontmostApplicationName),
            frontmostApplicationBundleID: try container.decodeIfPresent(String.self, forKey: .frontmostApplicationBundleID),
            frontmostWindowTitle: try container.decodeIfPresent(String.self, forKey: .frontmostWindowTitle),
            accessibilityTextAuthorized: authorized,
            // Fail closed: ignore unauthorized text even if present in legacy/corrupt JSON.
            accessibilityText: authorized ? decodedText : nil,
            imageOnlyFallback: fallback
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isLatticeManaged, forKey: .isLatticeManaged)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(capturedAt, forKey: .capturedAt)
        try container.encode(contextMetadataAuthorized, forKey: .contextMetadataAuthorized)
        try container.encodeIfPresent(frontmostApplicationName, forKey: .frontmostApplicationName)
        try container.encodeIfPresent(frontmostApplicationBundleID, forKey: .frontmostApplicationBundleID)
        try container.encodeIfPresent(frontmostWindowTitle, forKey: .frontmostWindowTitle)
        try container.encode(accessibilityTextAuthorized, forKey: .accessibilityTextAuthorized)
        if accessibilityTextAuthorized {
            try container.encodeIfPresent(accessibilityText, forKey: .accessibilityText)
        }
        try container.encode(imageOnlyFallback, forKey: .imageOnlyFallback)
    }

    private static func boundedOptional(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max))
    }
}

public struct ContextAttachment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// Local absolute path for live attachments, or a non-resolvable display token for imported/missing ones.
    public let path: String
    /// When true, the attachment is metadata-only and must not be opened, read, or resolved on disk.
    public var isMissing: Bool
    /// Image vs ordinary file classification. Prefer inspected type evidence over extension alone.
    public var kind: ContextAttachmentKind
    /// UTType-like identifier when known (for example `public.png`). Never carries file bytes.
    public var contentTypeIdentifier: String?
    /// MIME type when known (for example `image/png`). Never carries file bytes.
    public var mimeType: String?
    /// Byte length when safely obtainable from filesystem metadata.
    public var byteCount: Int64?
    /// Image pixel dimensions when safely obtainable from bounded image metadata.
    public var pixelDimensions: ContextAttachmentPixelDimensions?
    /// Provenance of how this attachment entered the session.
    public var source: ContextAttachmentSource
    /// Optional Lattice capture metadata. Absent for ordinary non-image attachments and legacy records.
    public var imageMetadata: ContextAttachmentImageMetadata?

    public var name: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "attachment" }
        if trimmed.contains("://") {
            return URL(string: trimmed)?.lastPathComponent.isEmpty == false
                ? (URL(string: trimmed)?.lastPathComponent ?? "attachment")
                : "attachment"
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    /// True when the typed kind is image. Legacy archives derive kind from extension at decode time.
    public var isImage: Bool { kind == .image }

    public var isLatticeManagedCapture: Bool {
        imageMetadata?.isLatticeManaged == true
    }

    /// Legacy-compatible initializer retained for existing callers.
    /// Classifies kind from the path extension only and records `source` as `.legacy`.
    public init(id: UUID = UUID(), path: String, isMissing: Bool = false) {
        self.init(
            id: id,
            path: path,
            isMissing: isMissing,
            kind: ContextAttachmentTypeMap.kind(forPathExtension: ContextAttachmentTypeMap.pathExtension(of: path)),
            contentTypeIdentifier: nil,
            mimeType: nil,
            byteCount: nil,
            pixelDimensions: nil,
            source: .legacy,
            imageMetadata: nil
        )
    }

    /// Capture-oriented convenience: classifies kind from the path and attaches optional image metadata.
    public init(
        id: UUID = UUID(),
        path: String,
        isMissing: Bool = false,
        imageMetadata: ContextAttachmentImageMetadata?
    ) {
        let source: ContextAttachmentSource = {
            guard let imageMetadata else { return .legacy }
            switch imageMetadata.source {
            case .regionCapture, .windowCapture, .clipboard:
                return .screenshot
            case .existingFile:
                return imageMetadata.isLatticeManaged ? .screenshot : .legacy
            }
        }()
        self.init(
            id: id,
            path: path,
            isMissing: isMissing,
            kind: ContextAttachmentTypeMap.kind(forPathExtension: ContextAttachmentTypeMap.pathExtension(of: path)),
            contentTypeIdentifier: nil,
            mimeType: nil,
            byteCount: nil,
            pixelDimensions: nil,
            source: source,
            imageMetadata: imageMetadata
        )
    }

    public init(
        id: UUID = UUID(),
        path: String,
        isMissing: Bool = false,
        kind: ContextAttachmentKind,
        contentTypeIdentifier: String? = nil,
        mimeType: String? = nil,
        byteCount: Int64? = nil,
        pixelDimensions: ContextAttachmentPixelDimensions? = nil,
        source: ContextAttachmentSource,
        imageMetadata: ContextAttachmentImageMetadata? = nil
    ) {
        self.id = id
        self.path = path
        self.isMissing = isMissing
        self.kind = kind
        self.contentTypeIdentifier = Self.normalizedOptional(contentTypeIdentifier)
        self.mimeType = Self.normalizedOptional(mimeType)
        self.byteCount = byteCount.flatMap { $0 >= 0 ? $0 : nil }
        self.pixelDimensions = pixelDimensions
        self.source = source
        self.imageMetadata = imageMetadata
    }

    /// Builds an attachment from a local URL using bounded metadata inspection only.
    public static func inspecting(
        url: URL,
        source: ContextAttachmentSource,
        id: UUID = UUID(),
        imageMetadata: ContextAttachmentImageMetadata? = nil,
        inspector: any ContextAttachmentInspecting = FileContextAttachmentInspector()
    ) -> ContextAttachment {
        inspecting(path: url.path, source: source, id: id, imageMetadata: imageMetadata, inspector: inspector)
    }

    /// Builds an attachment from a path using bounded metadata inspection only.
    public static func inspecting(
        path: String,
        source: ContextAttachmentSource,
        id: UUID = UUID(),
        imageMetadata: ContextAttachmentImageMetadata? = nil,
        inspector: any ContextAttachmentInspecting = FileContextAttachmentInspector()
    ) -> ContextAttachment {
        let classification = ContextAttachmentClassifier.classify(
            path: path,
            evidence: inspector.inspect(path: path)
        )
        return ContextAttachment(
            id: id,
            path: path,
            isMissing: classification.isMissing,
            kind: classification.kind,
            contentTypeIdentifier: classification.contentTypeIdentifier,
            mimeType: classification.mimeType,
            byteCount: classification.byteCount,
            pixelDimensions: classification.pixelDimensions,
            source: source,
            imageMetadata: imageMetadata
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, isMissing
        case kind, contentTypeIdentifier, mimeType, byteCount, pixelDimensions, source, imageMetadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        isMissing = try container.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
        kind = try container.decodeIfPresent(ContextAttachmentKind.self, forKey: .kind)
            ?? ContextAttachmentTypeMap.kind(forPathExtension: ContextAttachmentTypeMap.pathExtension(of: path))
        contentTypeIdentifier = Self.normalizedOptional(
            try container.decodeIfPresent(String.self, forKey: .contentTypeIdentifier)
        )
        mimeType = Self.normalizedOptional(
            try container.decodeIfPresent(String.self, forKey: .mimeType)
        )
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount).flatMap { $0 >= 0 ? $0 : nil }
        pixelDimensions = try container.decodeIfPresent(ContextAttachmentPixelDimensions.self, forKey: .pixelDimensions)
        source = try container.decodeIfPresent(ContextAttachmentSource.self, forKey: .source) ?? .legacy
        imageMetadata = try container.decodeIfPresent(ContextAttachmentImageMetadata.self, forKey: .imageMetadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(isMissing, forKey: .isMissing)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(contentTypeIdentifier, forKey: .contentTypeIdentifier)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(pixelDimensions, forKey: .pixelDimensions)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(imageMetadata, forKey: .imageMetadata)
        // Intentionally never encode file bytes or base64 payloads.
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
