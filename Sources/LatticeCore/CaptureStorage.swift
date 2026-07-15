import Foundation

// MARK: - Sidecar metadata

/// Bounded on-disk sidecar for Lattice-managed captures. Never stores secrets.
public struct CaptureSidecarMetadata: Hashable, Codable, Sendable, Equatable {
    public static let maxAccessibilityTextLength = ContextAttachmentImageMetadata.maxAccessibilityTextLength
    public static let schemaVersion = 1

    public var id: UUID
    public var source: ContextAttachmentImageSource
    public var capturedAt: Date
    public var contextMetadataAuthorized: Bool
    public var frontmostApplicationName: String?
    public var frontmostApplicationBundleID: String?
    public var frontmostWindowTitle: String?
    public var accessibilityTextAuthorized: Bool
    public var accessibilityText: String?
    public var imageOnlyFallback: ContextAttachmentImageOnlyFallback
    public var imageFileName: String

    public init(
        id: UUID = UUID(),
        source: ContextAttachmentImageSource,
        capturedAt: Date = Date(),
        contextMetadataAuthorized: Bool = false,
        frontmostApplicationName: String? = nil,
        frontmostApplicationBundleID: String? = nil,
        frontmostWindowTitle: String? = nil,
        accessibilityTextAuthorized: Bool = false,
        accessibilityText: String? = nil,
        imageOnlyFallback: ContextAttachmentImageOnlyFallback = .none,
        imageFileName: String
    ) {
        self.id = id
        self.source = source
        self.capturedAt = capturedAt
        self.contextMetadataAuthorized = contextMetadataAuthorized
        self.frontmostApplicationName = contextMetadataAuthorized ? Self.bound(frontmostApplicationName, max: 256) : nil
        self.frontmostApplicationBundleID = contextMetadataAuthorized ? Self.bound(frontmostApplicationBundleID, max: 256) : nil
        self.frontmostWindowTitle = contextMetadataAuthorized ? Self.bound(frontmostWindowTitle, max: 512) : nil
        self.accessibilityTextAuthorized = contextMetadataAuthorized && accessibilityTextAuthorized
        if self.accessibilityTextAuthorized {
            self.accessibilityText = Self.bound(accessibilityText, max: Self.maxAccessibilityTextLength)
        } else {
            self.accessibilityText = nil
        }
        if self.accessibilityText != nil {
            self.imageOnlyFallback = .none
        } else {
            self.imageOnlyFallback = imageOnlyFallback
        }
        self.imageFileName = imageFileName
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, capturedAt, contextMetadataAuthorized
        case frontmostApplicationName, frontmostApplicationBundleID, frontmostWindowTitle
        case accessibilityTextAuthorized, accessibilityText, imageOnlyFallback, imageFileName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            source: try container.decode(ContextAttachmentImageSource.self, forKey: .source),
            capturedAt: try container.decode(Date.self, forKey: .capturedAt),
            contextMetadataAuthorized: try container.decodeIfPresent(Bool.self, forKey: .contextMetadataAuthorized) ?? false,
            frontmostApplicationName: try container.decodeIfPresent(String.self, forKey: .frontmostApplicationName),
            frontmostApplicationBundleID: try container.decodeIfPresent(String.self, forKey: .frontmostApplicationBundleID),
            frontmostWindowTitle: try container.decodeIfPresent(String.self, forKey: .frontmostWindowTitle),
            accessibilityTextAuthorized: try container.decodeIfPresent(Bool.self, forKey: .accessibilityTextAuthorized) ?? false,
            accessibilityText: try container.decodeIfPresent(String.self, forKey: .accessibilityText),
            imageOnlyFallback: try container.decodeIfPresent(ContextAttachmentImageOnlyFallback.self, forKey: .imageOnlyFallback) ?? .none,
            imageFileName: try container.decode(String.self, forKey: .imageFileName)
        )
    }

    public func asAttachmentImageMetadata() -> ContextAttachmentImageMetadata {
        ContextAttachmentImageMetadata(
            isLatticeManaged: true,
            source: source,
            capturedAt: capturedAt,
            contextMetadataAuthorized: contextMetadataAuthorized,
            frontmostApplicationName: frontmostApplicationName,
            frontmostApplicationBundleID: frontmostApplicationBundleID,
            frontmostWindowTitle: frontmostWindowTitle,
            accessibilityTextAuthorized: accessibilityTextAuthorized,
            accessibilityText: accessibilityText,
            imageOnlyFallback: imageOnlyFallback
        )
    }

    private static func bound(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max))
    }
}

public struct CaptureWriteResult: Equatable, Sendable {
    public var imageURL: URL
    public var sidecarURL: URL
    public var attachment: ContextAttachment

    public init(imageURL: URL, sidecarURL: URL, attachment: ContextAttachment) {
        self.imageURL = imageURL
        self.sidecarURL = sidecarURL
        self.attachment = attachment
    }
}

public struct CaptureCleanupResult: Equatable, Sendable {
    public var removedFileCount: Int
    public var remainingCaptureCount: Int

    public init(removedFileCount: Int, remainingCaptureCount: Int) {
        self.removedFileCount = removedFileCount
        self.remainingCaptureCount = remainingCaptureCount
    }
}

public enum CaptureStorageError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidImageExtension(String)
    case emptyImageData
    case pathEscapesRoot(String)
    case unsupportedFileName(String)
    case fileSystem(String)
}

public struct CaptureStorageConfiguration: Equatable, Sendable {
    public var maxCaptureCount: Int
    public var maxAge: TimeInterval
    public var allowedImageExtensions: Set<String>

    public init(
        maxCaptureCount: Int = 40,
        maxAge: TimeInterval = 60 * 60 * 24 * 14,
        allowedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    ) {
        self.maxCaptureCount = max(1, maxCaptureCount)
        self.maxAge = max(0, maxAge)
        self.allowedImageExtensions = Set(allowedImageExtensions.map { $0.lowercased() })
    }
}

/// Lattice-owned capture storage under Application Support (or an injected test root).
/// Deletes only known capture image/sidecar names inside its canonical managed root.
///
/// Marked `@unchecked Sendable` because `FileManager` is not statically Sendable; callers
/// treat a store instance as value-owned configuration plus injected I/O dependencies.
public struct CaptureStorage: @unchecked Sendable {
    public let rootURL: URL
    public let configuration: CaptureStorageConfiguration

    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public static let defaultFolderName = "Captures"

    public init(
        rootURL: URL,
        configuration: CaptureStorageConfiguration = CaptureStorageConfiguration(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.configuration = configuration
        self.fileManager = fileManager
        self.now = now
    }

    /// Default product location: Application Support/Lattice/Captures (or override root).
    public static func applicationSupportStore(
        base: URL? = nil,
        configuration: CaptureStorageConfiguration = CaptureStorageConfiguration(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> CaptureStorage {
        let root = LatticeApplicationSupport.productRootURL(base: base)
            .appendingPathComponent(defaultFolderName, isDirectory: true)
        return CaptureStorage(rootURL: root, configuration: configuration, fileManager: fileManager, now: now)
    }

    public func ensureRoot() throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw CaptureStorageError.fileSystem(error.localizedDescription)
        }
    }

    /// Atomically writes image bytes plus a bounded metadata sidecar.
    public func writeCapture(
        imageData: Data,
        imageExtension: String,
        metadata: CaptureSidecarMetadata,
        protectedCaptureIDs: Set<UUID> = []
    ) throws -> CaptureWriteResult {
        guard !imageData.isEmpty else { throw CaptureStorageError.emptyImageData }
        let ext = normalizedExtension(imageExtension)
        guard configuration.allowedImageExtensions.contains(ext) else {
            throw CaptureStorageError.invalidImageExtension(imageExtension)
        }

        try ensureRoot()

        let captureID = metadata.id
        let imageName = "\(captureID.uuidString.lowercased()).\(ext)"
        let sidecarName = "\(captureID.uuidString.lowercased()).json"
        let imageURL = rootURL.appendingPathComponent(imageName, isDirectory: false)
        let sidecarURL = rootURL.appendingPathComponent(sidecarName, isDirectory: false)

        try validateManagedFileURL(imageURL)
        try validateManagedFileURL(sidecarURL)

        var sidecar = metadata
        sidecar.imageFileName = imageName
        // Enforce authorization boundary again at the storage edge.
        if !sidecar.contextMetadataAuthorized {
            sidecar.frontmostApplicationName = nil
            sidecar.frontmostApplicationBundleID = nil
            sidecar.frontmostWindowTitle = nil
            sidecar.accessibilityTextAuthorized = false
            sidecar.accessibilityText = nil
        } else if !sidecar.accessibilityTextAuthorized {
            sidecar.accessibilityText = nil
        } else if let text = sidecar.accessibilityText, text.count > CaptureSidecarMetadata.maxAccessibilityTextLength {
            sidecar.accessibilityText = String(text.prefix(CaptureSidecarMetadata.maxAccessibilityTextLength))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sidecarData: Data
        do {
            sidecarData = try encoder.encode(sidecar)
        } catch {
            throw CaptureStorageError.fileSystem(error.localizedDescription)
        }

        // Write image then sidecar with unique temps in the managed root, then replace.
        try atomicWrite(data: imageData, to: imageURL)
        do {
            try atomicWrite(data: sidecarData, to: sidecarURL)
        } catch {
            try? removeManagedFile(at: imageURL)
            throw error
        }

        let imageMeta = sidecar.asAttachmentImageMetadata()
        let attachment = ContextAttachment(
            id: captureID,
            path: imageURL.path,
            isMissing: false,
            kind: .image,
            contentTypeIdentifier: "public.png",
            mimeType: "image/png",
            byteCount: Int64(imageData.count),
            pixelDimensions: nil,
            source: .screenshot,
            imageMetadata: imageMeta
        )
        _ = try? cleanup(protectedCaptureIDs: protectedCaptureIDs.union([captureID]))
        return CaptureWriteResult(imageURL: imageURL, sidecarURL: sidecarURL, attachment: attachment)
    }

    /// Removes a managed capture image and its sidecar when the path is inside the root.
    public func removeCapture(at url: URL) throws {
        let standardized = url.standardizedFileURL
        try validateManagedFileURL(standardized)
        let name = standardized.lastPathComponent
        guard isKnownCaptureFileName(name) else {
            throw CaptureStorageError.unsupportedFileName(name)
        }
        try removeCapturePair(baseName: (name as NSString).deletingPathExtension)
    }

    public func removeCapture(attachment: ContextAttachment) throws {
        guard attachment.isLatticeManagedCapture else { return }
        try removeCapture(at: URL(fileURLWithPath: attachment.path))
    }

    /// Startup / age / count cleanup. Only deletes known capture names under the managed root.
    @discardableResult
    public func cleanup(protectedCaptureIDs: Set<UUID> = []) throws -> CaptureCleanupResult {
        try ensureRoot()
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CaptureStorageError.fileSystem(error.localizedDescription)
        }

        var removed = 0
        var captures: [(base: String, imageURL: URL?, sidecarURL: URL?, modified: Date)] = []
        var byBase: [String: (imageURL: URL?, sidecarURL: URL?, modified: Date)] = [:]

        for url in contents {
            let name = url.lastPathComponent
            guard isKnownCaptureFileName(name) else { continue }
            guard isContained(url) else { continue }
            let base = (name as NSString).deletingPathExtension.lowercased()
            let ext = (name as NSString).pathExtension.lowercased()
            var entry = byBase[base] ?? (imageURL: nil, sidecarURL: nil, modified: .distantPast)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if ext == "json" {
                entry.sidecarURL = url
            } else {
                entry.imageURL = url
            }
            entry.modified = max(entry.modified, modified)
            byBase[base] = entry
        }

        let cutoff = now().addingTimeInterval(-configuration.maxAge)
        for (base, entry) in byBase {
            let captureID = UUID(uuidString: base)
            if entry.modified < cutoff, captureID.map({ !protectedCaptureIDs.contains($0) }) ?? true {
                removed += try removePair(image: entry.imageURL, sidecar: entry.sidecarURL)
                continue
            }
            captures.append((base, entry.imageURL, entry.sidecarURL, entry.modified))
        }

        captures.sort { $0.modified > $1.modified }
        if captures.count > configuration.maxCaptureCount {
            var retained = captures
            for candidate in captures.reversed() where retained.count > configuration.maxCaptureCount {
                guard let captureID = UUID(uuidString: candidate.base), !protectedCaptureIDs.contains(captureID) else { continue }
                removed += try removePair(image: candidate.imageURL, sidecar: candidate.sidecarURL)
                retained.removeAll { $0.base == candidate.base }
            }
            captures = retained
        }

        return CaptureCleanupResult(removedFileCount: removed, remainingCaptureCount: captures.count)
    }

    public func isManagedURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let name = url.standardizedFileURL.lastPathComponent
        return isContained(url) && isKnownCaptureFileName(name)
    }

    // MARK: - Private

    private func removeCapturePair(baseName: String) throws {
        let base = baseName.lowercased()
        guard UUID(uuidString: base) != nil else {
            throw CaptureStorageError.unsupportedFileName(baseName)
        }
        var removed = 0
        for ext in configuration.allowedImageExtensions.union(["json"]) {
            let url = rootURL.appendingPathComponent("\(base).\(ext)", isDirectory: false)
            guard isContained(url), fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                throw CaptureStorageError.fileSystem(error.localizedDescription)
            }
        }
        if removed == 0 {
            // Idempotent: already gone.
            return
        }
    }

    private func removePair(image: URL?, sidecar: URL?) throws -> Int {
        var count = 0
        for url in [image, sidecar].compactMap({ $0 }) {
            guard isContained(url), isKnownCaptureFileName(url.lastPathComponent) else {
                throw CaptureStorageError.pathEscapesRoot(url.path)
            }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                count += 1
            } catch {
                throw CaptureStorageError.fileSystem(error.localizedDescription)
            }
        }
        return count
    }

    private func removeManagedFile(at url: URL) throws {
        try validateManagedFileURL(url)
        guard isKnownCaptureFileName(url.lastPathComponent) else {
            throw CaptureStorageError.unsupportedFileName(url.lastPathComponent)
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw CaptureStorageError.fileSystem(error.localizedDescription)
        }
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        try validateManagedFileURL(url)
        let temporary = rootURL.appendingPathComponent(
            ".lattice-capture-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: temporary, to: url)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw CaptureStorageError.fileSystem(error.localizedDescription)
        }
    }

    private func validateManagedFileURL(_ url: URL) throws {
        guard url.isFileURL else { throw CaptureStorageError.pathEscapesRoot(url.absoluteString) }
        let standardized = url.standardizedFileURL
        guard isContained(standardized) else {
            throw CaptureStorageError.pathEscapesRoot(standardized.path)
        }
        let relative = standardized.path.dropFirst(rootURL.path.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relative.contains("/") || relative.contains("..") {
            throw CaptureStorageError.pathEscapesRoot(standardized.path)
        }
        let name = standardized.lastPathComponent
        if name == ".." || name == "." || name.isEmpty {
            throw CaptureStorageError.pathEscapesRoot(standardized.path)
        }
    }

    private func isContained(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        let root = rootURL.path
        return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func isKnownCaptureFileName(_ name: String) -> Bool {
        let ns = name as NSString
        let base = ns.deletingPathExtension.lowercased()
        let ext = ns.pathExtension.lowercased()
        guard UUID(uuidString: base) != nil else { return false }
        if ext == "json" { return true }
        return configuration.allowedImageExtensions.contains(ext)
    }

    private func normalizedExtension(_ value: String) -> String {
        var ext = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ext.hasPrefix(".") { ext = String(ext.dropFirst()) }
        return ext
    }
}
