import Darwin
import Foundation

/// Validates and revalidates local image artifact paths for assistant media.
///
/// Safety invariants:
/// - Accepts plain absolute paths or workspace-relative paths only.
/// - Rejects URL schemes (`file:`, `http:`, `https:`, `data:`) and base64 payloads.
/// - Resolves symlinks, then requires containment under the selected workspace or
///   an explicitly supplied application-support root.
/// - Inspects only a bounded header; never trusts file extension alone.
/// - Authorized-but-absent paths become `.missing` so later revalidation can recover.
public enum AssistantImageArtifactPolicy {
    public static let maximumByteCount = 12 * 1024 * 1024
    public static let maximumHeaderByteCount = 64 * 1024
    public static let maximumPixelDimension = 32_768
    public static let maximumPixelCount = 100_000_000

    public enum Rejection: String, Sendable, Equatable {
        case emptyPath
        case urlScheme
        case base64Payload
        case unsupportedPathForm
        case outsideAuthorizedRoots
        case notRegularFile
        case oversize
        case unsafeDimensions
        case unsupportedSignature
        case unreadable
    }

    public struct ValidatedImage: Equatable, Sendable {
        public let canonicalPath: String
        public let displayName: String
        public let mimeType: String
        public let byteCount: Int
        public let pixelWidth: Int?
        public let pixelHeight: Int?
        public let status: AssistantArtifact.Status
    }

    public enum Outcome: Equatable, Sendable {
        case accepted(ValidatedImage)
        case rejected(Rejection)
    }

    public struct FileProbe: Sendable {
        public var fileExists: @Sendable (String) -> Bool
        public var isSymbolicLink: @Sendable (String) -> Bool
        public var isRegularFile: @Sendable (String) -> Bool
        public var byteCount: @Sendable (String) throws -> Int
        public var readHeader: @Sendable (String, Int) throws -> Data
        public var realPath: @Sendable (String) -> String?

        public init(
            fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
            isSymbolicLink: @escaping @Sendable (String) -> Bool = { path in
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])
                return values?.isSymbolicLink == true
            },
            isRegularFile: @escaping @Sendable (String) -> Bool = { path in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    return false
                }
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            },
            byteCount: @escaping @Sendable (String) throws -> Int = { path in
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                return (attributes[.size] as? NSNumber)?.intValue ?? 0
            },
            readHeader: @escaping @Sendable (String, Int) throws -> Data = { path, limit in
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                return try handle.read(upToCount: limit) ?? Data()
            },
            realPath: @escaping @Sendable (String) -> String? = { path in
                guard let pointer = realpath(path, nil) else { return nil }
                defer { free(pointer) }
                return String(cString: pointer)
            }
        ) {
            self.fileExists = fileExists
            self.isSymbolicLink = isSymbolicLink
            self.isRegularFile = isRegularFile
            self.byteCount = byteCount
            self.readHeader = readHeader
            self.realPath = realPath
        }

        public static let `default` = FileProbe()
    }

    public static func validate(
        path rawPath: String,
        workspace: URL,
        applicationSupportRoot: URL,
        probe: FileProbe = .default
    ) -> Outcome {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.emptyPath) }
        if looksLikeBase64Payload(trimmed) { return .rejected(.base64Payload) }
        guard isPlainLocalPath(trimmed) else {
            if containsURLScheme(trimmed) { return .rejected(.urlScheme) }
            return .rejected(.unsupportedPathForm)
        }

        guard let authorized = authorize(
            path: trimmed,
            workspace: workspace,
            applicationSupportRoot: applicationSupportRoot,
            probe: probe
        ) else {
            return .rejected(.outsideAuthorizedRoots)
        }

        if !probe.fileExists(authorized) {
            return .accepted(
                ValidatedImage(
                    canonicalPath: authorized,
                    displayName: displayName(for: authorized),
                    mimeType: "application/octet-stream",
                    byteCount: 0,
                    pixelWidth: nil,
                    pixelHeight: nil,
                    status: .missing
                )
            )
        }

        if probe.isSymbolicLink(authorized) {
            // Symlink targets must already have been resolved into `authorized`.
            // A remaining symlink leaf means resolution failed or is unsafe.
            guard let resolved = probe.realPath(authorized),
                  isContained(resolved, under: workspace, or: applicationSupportRoot, probe: probe) else {
                return .rejected(.outsideAuthorizedRoots)
            }
            return validateExistingFile(at: resolved, probe: probe)
        }

        return validateExistingFile(at: authorized, probe: probe)
    }

    /// Re-check a previously accepted artifact path. Missing files stay missing;
    /// recovered files promote to available when signature and size checks pass.
    public static func revalidate(
        artifact: AssistantArtifact,
        workspace: URL,
        applicationSupportRoot: URL,
        probe: FileProbe = .default
    ) -> Outcome {
        validate(
            path: artifact.canonicalPath,
            workspace: workspace,
            applicationSupportRoot: applicationSupportRoot,
            probe: probe
        )
    }

    public static func observation(
        from outcome: Outcome,
        id: UUID = UUID(),
        provenance: AssistantArtifact.Provenance,
        at date: Date = .now
    ) -> AssistantArtifactObservation? {
        guard case .accepted(let image) = outcome else { return nil }
        return AssistantArtifactObservation(
            id: id,
            kind: .image,
            status: image.status,
            displayName: image.displayName,
            mimeType: image.mimeType,
            byteCount: image.byteCount,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            canonicalPath: image.canonicalPath,
            provenance: provenance,
            createdAt: date,
            updatedAt: date
        )
    }

    // MARK: - Path form

    private static func looksLikeBase64Payload(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("data:image") { return true }
        if value.count >= 64,
           !value.contains("/"),
           !value.contains("."),
           value.unicodeScalars.allSatisfy({
               CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "/" || $0 == "="
           }) {
            return true
        }
        // Long base64 blobs occasionally include whitespace/newlines.
        let compact = value.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        if compact.count >= 128,
           compact.unicodeScalars.allSatisfy({
               CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "/" || $0 == "="
           }) {
            return true
        }
        return false
    }

    private static func containsURLScheme(_ value: String) -> Bool {
        if value.contains("://") { return true }
        if let colon = value.firstIndex(of: ":") {
            let scheme = value[..<colon]
            guard let first = scheme.unicodeScalars.first,
                  first.properties.isAlphabetic,
                  scheme.unicodeScalars.dropFirst().allSatisfy({
                      $0.properties.isAlphabetic || (48...57).contains($0.value) || $0 == "+" || $0 == "-" || $0 == "."
                  }) else { return false }
            return true
        }
        return false
    }

    private static func isPlainLocalPath(_ path: String) -> Bool {
        guard path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !path.contains("\\"),
              !path.hasPrefix("~"),
              !path.hasPrefix("//") else { return false }
        if containsURLScheme(path) { return false }
        // Windows drive letters are not accepted on the macOS control plane.
        if path.count >= 2,
           let first = path.unicodeScalars.first,
           first.properties.isAlphabetic,
           path.unicodeScalars.dropFirst().first == ":" {
            return false
        }
        return path.hasPrefix("/") || !path.contains(":")
    }

    // MARK: - Authorization

    private static func authorize(
        path: String,
        workspace: URL,
        applicationSupportRoot: URL,
        probe: FileProbe
    ) -> String? {
        guard workspace.isFileURL, applicationSupportRoot.isFileURL else { return nil }
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else {
            absolute = URL(fileURLWithPath: workspace.path, isDirectory: true)
                .appendingPathComponent(path)
                .path
        }
        guard let canonical = canonicalize(absolute, probe: probe) else { return nil }
        guard isContained(canonical, under: workspace, or: applicationSupportRoot, probe: probe) else {
            return nil
        }
        return canonical
    }

    private static func isContained(
        _ candidate: String,
        under workspace: URL,
        or applicationSupportRoot: URL,
        probe: FileProbe
    ) -> Bool {
        let roots = [workspace, applicationSupportRoot].compactMap { resolvedRoot(for: $0, probe: probe) }
        return roots.contains { root in
            let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
            return candidate == normalizedRoot || candidate.hasPrefix(normalizedRoot + "/")
        }
    }

    private static func resolvedRoot(for root: URL, probe: FileProbe) -> String? {
        guard root.isFileURL else { return nil }
        let standardized = root.standardizedFileURL.path
        if let real = probe.realPath(standardized) {
            return real
        }
        // Existing roots should still authorize even if realpath is unavailable.
        if probe.fileExists(standardized) || FileManager.default.fileExists(atPath: standardized) {
            return standardized
        }
        // Non-existent authorized roots (fresh app-support trees) still constrain missing paths.
        return standardized.hasPrefix("/") ? standardized : nil
    }

    /// Resolve existing ancestors with realpath; re-append missing suffix without following a dangling leaf symlink.
    private static func canonicalize(_ absolute: String, probe: FileProbe) -> String? {
        var current = (absolute as NSString).standardizingPath
        var missingSuffix: [String] = []
        while true {
            if probe.fileExists(current) {
                guard let resolved = probe.realPath(current) else { return nil }
                return missingSuffix.reversed().reduce(resolved) { path, component in
                    (path as NSString).appendingPathComponent(component)
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            let name = (current as NSString).lastPathComponent
            guard parent != current, !name.isEmpty, name != ".", name != ".." else { return nil }
            missingSuffix.append(name)
            current = parent
        }
    }

    // MARK: - Existing file checks

    private static func validateExistingFile(at path: String, probe: FileProbe) -> Outcome {
        guard probe.isRegularFile(path) else { return .rejected(.notRegularFile) }
        let size: Int
        do {
            size = try probe.byteCount(path)
        } catch {
            return .rejected(.unreadable)
        }
        guard size > 0 else { return .rejected(.unsupportedSignature) }
        guard size <= maximumByteCount else { return .rejected(.oversize) }

        let header: Data
        do {
            header = try probe.readHeader(path, min(maximumHeaderByteCount, size))
        } catch {
            return .rejected(.unreadable)
        }
        guard let signature = ImageSignature.detect(header) else {
            return .rejected(.unsupportedSignature)
        }
        let dimensions = ImageSignature.dimensions(in: header, kind: signature)
        if let dimensions {
            guard dimensions.width <= maximumPixelDimension,
                  dimensions.height <= maximumPixelDimension,
                  dimensions.width <= maximumPixelCount / dimensions.height else {
                return .rejected(.unsafeDimensions)
            }
        }
        return .accepted(
            ValidatedImage(
                canonicalPath: path,
                displayName: displayName(for: path),
                mimeType: signature.mimeType,
                byteCount: size,
                pixelWidth: dimensions?.width,
                pixelHeight: dimensions?.height,
                status: .available
            )
        )
    }

    private static func displayName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "image" : name
    }
}

/// Converts fresh validation into stable UI capabilities without granting new file authority.
public enum AssistantArtifactPresentationPolicy {
    public enum Availability: Equatable, Sendable {
        case available
        case missing
        case invalid(AssistantImageArtifactPolicy.Rejection)
    }

    public struct Presentation: Equatable, Sendable {
        public let availability: Availability
        public let detail: String
        public let canOpen: Bool
        public let canReveal: Bool
        public let canSaveCopy: Bool
        public let canCopyPath: Bool

        public init(
            availability: Availability,
            detail: String,
            canOpen: Bool,
            canReveal: Bool,
            canSaveCopy: Bool,
            canCopyPath: Bool
        ) {
            self.availability = availability
            self.detail = detail
            self.canOpen = canOpen
            self.canReveal = canReveal
            self.canSaveCopy = canSaveCopy
            self.canCopyPath = canCopyPath
        }
    }

    public static func presentation(
        for artifact: AssistantArtifact,
        workspace: URL,
        applicationSupportRoot: URL,
        probe: AssistantImageArtifactPolicy.FileProbe = .default
    ) -> Presentation {
        switch AssistantImageArtifactPolicy.revalidate(
            artifact: artifact,
            workspace: workspace,
            applicationSupportRoot: applicationSupportRoot,
            probe: probe
        ) {
        case .accepted(let image) where image.status == .available:
            let dimensions = if let width = image.pixelWidth, let height = image.pixelHeight {
                " · \(width)×\(height)"
            } else {
                ""
            }
            return Presentation(
                availability: .available,
                detail: "\(image.mimeType) · \(formattedByteCount(image.byteCount))\(dimensions)",
                canOpen: true,
                canReveal: true,
                canSaveCopy: true,
                canCopyPath: true
            )
        case .accepted:
            return Presentation(
                availability: .missing,
                detail: "The image file is missing. Retry after restoring it to its original location.",
                canOpen: false,
                canReveal: false,
                canSaveCopy: false,
                canCopyPath: true
            )
        case .rejected(let rejection):
            return Presentation(
                availability: .invalid(rejection),
                detail: "This image is no longer safe to open from its recorded location.",
                canOpen: false,
                canReveal: false,
                canSaveCopy: false,
                canCopyPath: false
            )
        }
    }

    private static func formattedByteCount(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(max(0, count)))
    }
}

// MARK: - Bounded signature inspection

private enum ImageSignature {
    enum Kind {
        case png
        case jpeg
        case gif
        case webp

        var mimeType: String {
            switch self {
            case .png: "image/png"
            case .jpeg: "image/jpeg"
            case .gif: "image/gif"
            case .webp: "image/webp"
            }
        }
    }

    static func detect(_ data: Data) -> Kind? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if data.count >= 12,
           data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            return .webp
        }
        return nil
    }

    static func dimensions(in data: Data, kind: Kind) -> (width: Int, height: Int)? {
        switch kind {
        case .png:
            guard data.count >= 24 else { return nil }
            let width = readBE32(data, offset: 16)
            let height = readBE32(data, offset: 20)
            return positive(width, height)
        case .gif:
            guard data.count >= 10 else { return nil }
            let width = Int(data[6]) | (Int(data[7]) << 8)
            let height = Int(data[8]) | (Int(data[9]) << 8)
            return positive(width, height)
        case .jpeg:
            return jpegDimensions(data)
        case .webp:
            return webpDimensions(data)
        }
    }

    private static func jpegDimensions(_ data: Data) -> (width: Int, height: Int)? {
        var offset = 2
        while offset + 9 < data.count {
            guard data[offset] == 0xFF else { return nil }
            let marker = data[offset + 1]
            offset += 2
            if marker == 0xD8 || marker == 0xD9 { continue }
            guard offset + 1 < data.count else { return nil }
            let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
            guard length >= 2, offset + length <= data.count else { return nil }
            // SOF0 / SOF2
            if marker == 0xC0 || marker == 0xC2, length >= 7 {
                let height = (Int(data[offset + 3]) << 8) | Int(data[offset + 4])
                let width = (Int(data[offset + 5]) << 8) | Int(data[offset + 6])
                return positive(width, height)
            }
            offset += length
        }
        return nil
    }

    private static func webpDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 30,
              data[12] == 0x56, data[13] == 0x50, data[14] == 0x38 else { return nil }
        // VP8 lossy bitstream
        if data[15] == 0x20, data.count >= 30 {
            let width = Int(data[26]) | (Int(data[27]) << 8)
            let height = Int(data[28]) | (Int(data[29]) << 8)
            return positive(width & 0x3FFF, height & 0x3FFF)
        }
        // VP8L
        if data[15] == 0x4C, data.count >= 25, data[20] == 0x2F {
            let bits = Int(data[21]) | (Int(data[22]) << 8) | (Int(data[23]) << 16) | (Int(data[24]) << 24)
            let width = (bits & 0x3FFF) + 1
            let height = ((bits >> 14) & 0x3FFF) + 1
            return positive(width, height)
        }
        return nil
    }

    private static func readBE32(_ data: Data, offset: Int) -> Int {
        (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    private static func positive(_ width: Int, _ height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
