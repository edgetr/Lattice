import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Inspection evidence

/// Bounded metadata probe result. Never carries file body bytes or base64 payloads.
public struct ContextAttachmentInspectionEvidence: Hashable, Sendable, Equatable {
    public var fileExists: Bool
    public var byteCount: Int64?
    public var contentTypeIdentifier: String?
    public var mimeType: String?
    public var pixelDimensions: ContextAttachmentPixelDimensions?
    /// True when type identity came from content-type metadata or magic headers, not extension alone.
    public var typeEvidenceFromContent: Bool

    public init(
        fileExists: Bool,
        byteCount: Int64? = nil,
        contentTypeIdentifier: String? = nil,
        mimeType: String? = nil,
        pixelDimensions: ContextAttachmentPixelDimensions? = nil,
        typeEvidenceFromContent: Bool = false
    ) {
        self.fileExists = fileExists
        self.byteCount = byteCount.flatMap { $0 >= 0 ? $0 : nil }
        self.contentTypeIdentifier = normalizedOptional(contentTypeIdentifier)
        self.mimeType = normalizedOptional(mimeType)
        self.pixelDimensions = pixelDimensions
        self.typeEvidenceFromContent = typeEvidenceFromContent
    }
}

public struct ContextAttachmentClassification: Hashable, Sendable, Equatable {
    public var isMissing: Bool
    public var kind: ContextAttachmentKind
    public var contentTypeIdentifier: String?
    public var mimeType: String?
    public var byteCount: Int64?
    public var pixelDimensions: ContextAttachmentPixelDimensions?

    public init(
        isMissing: Bool,
        kind: ContextAttachmentKind,
        contentTypeIdentifier: String? = nil,
        mimeType: String? = nil,
        byteCount: Int64? = nil,
        pixelDimensions: ContextAttachmentPixelDimensions? = nil
    ) {
        self.isMissing = isMissing
        self.kind = kind
        self.contentTypeIdentifier = normalizedOptional(contentTypeIdentifier)
        self.mimeType = normalizedOptional(mimeType)
        self.byteCount = byteCount.flatMap { $0 >= 0 ? $0 : nil }
        self.pixelDimensions = pixelDimensions
    }
}

// MARK: - Injectable inspection seam

/// Deterministic inspection seam for tests and production. Implementations must never read unbounded contents.
public protocol ContextAttachmentInspecting: Sendable {
    func inspect(path: String) -> ContextAttachmentInspectionEvidence
}

extension ContextAttachmentInspecting {
    public func inspect(fileURL: URL) -> ContextAttachmentInspectionEvidence {
        inspect(path: fileURL.path)
    }
}

/// Closure-backed inspector for deterministic unit tests.
public struct ClosureContextAttachmentInspector: ContextAttachmentInspecting {
    private let handler: @Sendable (String) -> ContextAttachmentInspectionEvidence

    public init(_ handler: @escaping @Sendable (String) -> ContextAttachmentInspectionEvidence) {
        self.handler = handler
    }

    public func inspect(path: String) -> ContextAttachmentInspectionEvidence {
        handler(path)
    }
}

/// Filesystem inspector that uses metadata APIs and a tiny header probe only.
public struct FileContextAttachmentInspector: ContextAttachmentInspecting {
    /// Hard cap on header bytes read for magic-number classification.
    public static let headerProbeByteLimit = 64
    /// ImageIO metadata probing is skipped above this size so inspection stays bounded.
    public static let imageMetadataByteLimit: Int64 = 64 * 1_048_576

    public init() {}

    public func inspect(path: String) -> ContextAttachmentInspectionEvidence {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ContextAttachmentInspectionEvidence(fileExists: false)
        }

        // Non-file tokens (imported archive placeholders) must not be opened.
        if trimmed.contains("://"), URL(string: trimmed)?.isFileURL != true {
            return ContextAttachmentInspectionEvidence(fileExists: false)
        }

        let fileURL = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        // FileManager is process-shared and thread-safe for these queries; do not store it
        // on a Sendable value type (FileManager itself is not Sendable under Swift 6).
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard exists,
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: fileURL.path),
              attributes?[.type] as? FileAttributeType == .typeRegular else {
            return ContextAttachmentInspectionEvidence(fileExists: false)
        }

        var byteCount: Int64?
        var contentTypeIdentifier: String?
        var mimeType: String?
        var typeEvidenceFromContent = false

        if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey]) {
            if let size = values.fileSize {
                byteCount = Int64(size)
            }
            if let contentType = values.contentType {
                contentTypeIdentifier = contentType.identifier
                mimeType = contentType.preferredMIMEType
                typeEvidenceFromContent = true
            }
        }

        // A bounded magic-header match is stronger evidence than extension-derived URL metadata.
        if let sniffed = sniffHeader(at: fileURL) {
            contentTypeIdentifier = sniffed.contentTypeIdentifier
            mimeType = sniffed.mimeType
            typeEvidenceFromContent = true
        }

        var pixelDimensions: ContextAttachmentPixelDimensions?
        let provisionalKind = ContextAttachmentTypeMap.kind(
            contentTypeIdentifier: contentTypeIdentifier,
            mimeType: mimeType,
            pathExtension: ContextAttachmentTypeMap.pathExtension(of: trimmed)
        )
        if provisionalKind == .image,
           let byteCount,
           byteCount <= Self.imageMetadataByteLimit {
            pixelDimensions = readImagePixelDimensions(at: fileURL)
        }

        return ContextAttachmentInspectionEvidence(
            fileExists: true,
            byteCount: byteCount,
            contentTypeIdentifier: contentTypeIdentifier,
            mimeType: mimeType,
            pixelDimensions: pixelDimensions,
            typeEvidenceFromContent: typeEvidenceFromContent
        )
    }

    private func sniffHeader(at fileURL: URL) -> (contentTypeIdentifier: String, mimeType: String)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: Self.headerProbeByteLimit) ?? Data()
        } catch {
            return nil
        }
        return ContextAttachmentTypeMap.sniff(header: data)
    }

    private func readImagePixelDimensions(at fileURL: URL) -> ContextAttachmentPixelDimensions? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options as CFDictionary) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [CFString: Any] else {
            return nil
        }
        let widthValue = properties[kCGImagePropertyPixelWidth]
        let heightValue = properties[kCGImagePropertyPixelHeight]
        let width = intValue(widthValue)
        let height = intValue(heightValue)
        guard let width, let height, width > 0, height > 0 else { return nil }
        return ContextAttachmentPixelDimensions(width: width, height: height)
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        default:
            return nil
        }
    }
}

// MARK: - Classification

public enum ContextAttachmentClassifier {
    /// Merges path-extension fallback with optional inspection evidence into a durable classification.
    public static func classify(
        path: String,
        evidence: ContextAttachmentInspectionEvidence?
    ) -> ContextAttachmentClassification {
        let pathExtension = ContextAttachmentTypeMap.pathExtension(of: path)
        guard let evidence, evidence.fileExists else {
            return ContextAttachmentClassification(
                isMissing: true,
                kind: ContextAttachmentTypeMap.kind(forPathExtension: pathExtension),
                contentTypeIdentifier: ContextAttachmentTypeMap.contentTypeIdentifier(forPathExtension: pathExtension),
                mimeType: ContextAttachmentTypeMap.mimeType(forPathExtension: pathExtension),
                byteCount: nil,
                pixelDimensions: nil
            )
        }

        let contentTypeIdentifier = evidence.contentTypeIdentifier
            ?? ContextAttachmentTypeMap.contentTypeIdentifier(forPathExtension: pathExtension)
        let mimeType = evidence.mimeType
            ?? ContextAttachmentTypeMap.mimeType(forPathExtension: pathExtension)
            ?? contentTypeIdentifier.flatMap { ContextAttachmentTypeMap.mimeType(forContentTypeIdentifier: $0) }
        let kind: ContextAttachmentKind
        if evidence.typeEvidenceFromContent,
           contentTypeIdentifier != nil || mimeType != nil {
            kind = ContextAttachmentTypeMap.isImage(
                contentTypeIdentifier: contentTypeIdentifier,
                mimeType: mimeType
            ) ? .image : .file
        } else {
            kind = ContextAttachmentTypeMap.kind(
                contentTypeIdentifier: contentTypeIdentifier,
                mimeType: mimeType,
                pathExtension: pathExtension
            )
        }

        return ContextAttachmentClassification(
            isMissing: false,
            kind: kind,
            contentTypeIdentifier: contentTypeIdentifier,
            mimeType: mimeType,
            byteCount: evidence.byteCount,
            pixelDimensions: kind == .image ? evidence.pixelDimensions : nil
        )
    }
}

// MARK: - Type map / magic sniff

public enum ContextAttachmentTypeMap {
    public static let imagePathExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"
    ]

    public static func pathExtension(of path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let url = URL(string: trimmed) {
            return url.pathExtension.lowercased()
        }
        return URL(fileURLWithPath: trimmed).pathExtension.lowercased()
    }

    public static func kind(forPathExtension pathExtension: String) -> ContextAttachmentKind {
        imagePathExtensions.contains(pathExtension.lowercased()) ? .image : .file
    }

    public static func kind(
        contentTypeIdentifier: String?,
        mimeType: String?,
        pathExtension: String
    ) -> ContextAttachmentKind {
        if let contentTypeIdentifier,
           let type = UTType(contentTypeIdentifier),
           type.conforms(to: .image) {
            return .image
        }
        if let mimeType {
            let lowered = mimeType.lowercased()
            if lowered.hasPrefix("image/") {
                return .image
            }
        }
        if let contentTypeIdentifier {
            let lowered = contentTypeIdentifier.lowercased()
            if lowered.hasPrefix("public.") && imagePathExtensions.contains(where: { lowered.contains($0) }) {
                // Handles public.png / public.jpeg-style identifiers when UTType lookup is unavailable.
                if lowered.contains("image")
                    || lowered == "public.png"
                    || lowered == "public.jpeg"
                    || lowered == "public.gif"
                    || lowered == "public.tiff"
                    || lowered == "public.heic"
                    || lowered == "public.heif"
                    || lowered == "org.webmproject.webp"
                    || lowered == "com.microsoft.bmp" {
                    return .image
                }
            }
            if lowered.hasPrefix("public.image") || lowered == "public.camera-raw-image" {
                return .image
            }
        }
        return kind(forPathExtension: pathExtension)
    }

    public static func isImage(contentTypeIdentifier: String?, mimeType: String?) -> Bool {
        if let contentTypeIdentifier,
           let type = UTType(contentTypeIdentifier),
           type.conforms(to: .image) {
            return true
        }
        if mimeType?.lowercased().hasPrefix("image/") == true { return true }
        guard let identifier = contentTypeIdentifier?.lowercased() else { return false }
        return identifier.hasPrefix("public.image")
            || identifier == "public.png"
            || identifier == "public.jpeg"
            || identifier == "public.gif"
            || identifier == "public.tiff"
            || identifier == "public.heic"
            || identifier == "public.heif"
            || identifier == "org.webmproject.webp"
            || identifier == "com.microsoft.bmp"
            || identifier == "public.camera-raw-image"
    }

    public static func contentTypeIdentifier(forPathExtension pathExtension: String) -> String? {
        let ext = pathExtension.lowercased()
        switch ext {
        case "png": return UTType.png.identifier
        case "jpg", "jpeg": return UTType.jpeg.identifier
        case "gif": return UTType.gif.identifier
        case "tif", "tiff": return UTType.tiff.identifier
        case "bmp": return UTType.bmp.identifier
        case "heic": return UTType.heic.identifier
        case "heif": return UTType.heif.identifier
        case "webp": return UTType.webP.identifier
        case "pdf": return UTType.pdf.identifier
        case "txt": return UTType.plainText.identifier
        case "md": return UTType(filenameExtension: "md")?.identifier ?? "net.daringfireball.markdown"
        case "json": return UTType.json.identifier
        case "swift": return UTType(filenameExtension: "swift")?.identifier ?? "public.swift-source"
        default:
            return UTType(filenameExtension: ext)?.identifier
        }
    }

    public static func mimeType(forPathExtension pathExtension: String) -> String? {
        if let identifier = contentTypeIdentifier(forPathExtension: pathExtension) {
            return mimeType(forContentTypeIdentifier: identifier) ?? fallbackMIME(forPathExtension: pathExtension)
        }
        return fallbackMIME(forPathExtension: pathExtension)
    }

    public static func mimeType(forContentTypeIdentifier identifier: String) -> String? {
        if let type = UTType(identifier), let mime = type.preferredMIMEType {
            return mime
        }
        switch identifier.lowercased() {
        case "public.png": return "image/png"
        case "public.jpeg": return "image/jpeg"
        case "public.gif": return "image/gif"
        case "public.tiff": return "image/tiff"
        case "com.microsoft.bmp": return "image/bmp"
        case "public.heic": return "image/heic"
        case "public.heif": return "image/heif"
        case "org.webmproject.webp": return "image/webp"
        case "com.adobe.pdf": return "application/pdf"
        case "public.plain-text": return "text/plain"
        case "public.json": return "application/json"
        default: return nil
        }
    }

    /// Magic-number classification from a tiny header buffer (never a full file body).
    public static func sniff(header: Data) -> (contentTypeIdentifier: String, mimeType: String)? {
        guard !header.isEmpty else { return nil }
        let bytes = [UInt8](header)

        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return (UTType.png.identifier, "image/png")
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return (UTType.jpeg.identifier, "image/jpeg")
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return (UTType.gif.identifier, "image/gif")
        }
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return (UTType.webP.identifier, "image/webp")
        }
        if bytes.starts(with: [0x42, 0x4D]) {
            return (UTType.bmp.identifier, "image/bmp")
        }
        if bytes.count >= 4, Array(bytes[0..<4]) == [0x25, 0x50, 0x44, 0x46] {
            return (UTType.pdf.identifier, "application/pdf")
        }
        if isISOBaseMediaImage(bytes) {
            // HEIC/HEIF brands live in the ISO BMFF ftyp box.
            return (UTType.heic.identifier, "image/heic")
        }
        return nil
    }

    private static func isISOBaseMediaImage(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12 else { return false }
        // bytes[4..<8] == "ftyp"
        guard Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] else { return false }
        let brand = String(bytes: bytes[8..<min(12, bytes.count)], encoding: .ascii)?.lowercased() ?? ""
        let imageBrands: Set<String> = ["heic", "heix", "heif", "hevc", "mif1", "msf1", "avif"]
        if imageBrands.contains(brand) { return true }
        // Compatible brands may follow the major brand.
        var index = 16
        while index + 4 <= bytes.count {
            let compat = String(bytes: bytes[index..<(index + 4)], encoding: .ascii)?.lowercased() ?? ""
            if imageBrands.contains(compat) { return true }
            index += 4
        }
        return false
    }

    private static func fallbackMIME(forPathExtension pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        default: return nil
        }
    }
}

// MARK: - Validation / oversize

public struct ContextAttachmentValidationPolicy: Hashable, Sendable, Equatable {
    /// Optional maximum attachment payload size in bytes.
    public var maximumByteCount: Int64?
    /// Optional maximum longest image edge in pixels.
    public var maximumPixelEdge: Int?

    public init(maximumByteCount: Int64? = nil, maximumPixelEdge: Int? = nil) {
        self.maximumByteCount = maximumByteCount.flatMap { $0 > 0 ? $0 : nil }
        self.maximumPixelEdge = maximumPixelEdge.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Conservative defaults for multimodal context inputs. Callers may tighten further.
    public static let `default` = ContextAttachmentValidationPolicy(
        maximumByteCount: 25 * 1_048_576,
        maximumPixelEdge: 8_192
    )
}

public enum ContextAttachmentValidationIssue: Hashable, Sendable, Equatable {
    case missing
    case oversizeBytes(actual: Int64, limit: Int64)
    case oversizePixels(width: Int, height: Int, limit: Int)
}

public enum ContextAttachmentValidator {
    public static func issues(
        for attachment: ContextAttachment,
        limits: ContextAttachmentValidationPolicy = .default
    ) -> [ContextAttachmentValidationIssue] {
        var issues: [ContextAttachmentValidationIssue] = []
        if attachment.isMissing {
            issues.append(.missing)
        }
        if let limit = limits.maximumByteCount, let actual = attachment.byteCount, actual > limit {
            issues.append(.oversizeBytes(actual: actual, limit: limit))
        }
        if let limit = limits.maximumPixelEdge,
           let pixels = attachment.pixelDimensions,
           pixels.longestEdge > limit {
            issues.append(.oversizePixels(width: pixels.width, height: pixels.height, limit: limit))
        }
        return issues
    }

    public static func isAcceptable(
        _ attachment: ContextAttachment,
        limits: ContextAttachmentValidationPolicy = .default
    ) -> Bool {
        issues(for: attachment, limits: limits).isEmpty
    }
}

// MARK: - Helpers

private func normalizedOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
