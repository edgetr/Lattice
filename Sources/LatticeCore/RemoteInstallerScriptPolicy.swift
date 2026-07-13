import CryptoKit
import Foundation

// MARK: - Trust (truthful)

/// Integrity / authenticity posture for a downloaded installer body.
/// Without a pinned digest or signature, Lattice must report the payload as **unsigned**,
/// never as "verified".
public enum InstallerScriptTrust: Sendable, Equatable, Hashable {
    /// No pin was configured. Payload may still be size/content validated, but is not authenticated.
    case unsigned
    /// Caller supplied a pin and the SHA-256 matched.
    case digestMatched(sha256Hex: String)
    /// Caller supplied a pin and the SHA-256 did not match.
    case digestMismatch(expectedSHA256Hex: String, actualSHA256Hex: String)

    public var isAuthenticated: Bool {
        if case .digestMatched = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .unsigned:
            return "Installer is unsigned (no pinned digest or signature)."
        case .digestMatched(let hex):
            return "Installer SHA-256 matched pin \(hex)."
        case .digestMismatch(let expected, let actual):
            return "Installer SHA-256 mismatch (expected \(expected), got \(actual))."
        }
    }
}

// MARK: - Redirect / URL validation outcomes

public enum RemoteInstallerURLValidation: Sendable, Equatable {
    case accepted
    case rejected(String)

    public var message: String? {
        if case .rejected(let message) = self { return message }
        return nil
    }

    public var isAccepted: Bool { self == .accepted }
}

public enum RemoteInstallerContentTypeValidation: Sendable, Equatable {
    case accepted
    case rejected(String)

    public var message: String? {
        if case .rejected(let message) = self { return message }
        return nil
    }
}

public enum BoundedBodyAccumulation: Sendable, Equatable {
    case ok(Data)
    case empty
    case exceeded(maximumByteCount: Int, observedByteCount: Int)

    public var data: Data? {
        if case .ok(let data) = self { return data }
        return nil
    }
}

// MARK: - Policy

public enum RemoteInstallerScriptPolicy {
    public static let maximumByteCount = 2_000_000

    public static let allowedEndpoints: Set<String> = [
        "https://x.ai/cli/install.sh",
        "https://opencode.ai/install",
        "https://hermes-agent.nousresearch.com/install.sh"
    ]

    // MARK: URL surface

    /// Validates a single absolute URL against Lattice installer rules.
    public static func validationMessage(for url: URL) -> String? {
        validate(url: url).message
    }

    public static func validate(url: URL) -> RemoteInstallerURLValidation {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            return .rejected("Installer URL must use HTTPS.")
        }
        if url.user != nil || url.password != nil {
            return .rejected("Installer URL must not contain credentials.")
        }
        if url.query != nil {
            return .rejected("Installer URL must not contain query parameters.")
        }
        if url.fragment != nil {
            return .rejected("Installer URL must not contain fragments.")
        }
        let normalized = normalizeEndpoint(url)
        guard allowedEndpoints.contains(normalized) else {
            return .rejected("Installer URL is not an approved Lattice provider endpoint.")
        }
        return .accepted
    }

    /// Validates the original request URL before any network hop.
    public static func validateOriginalURL(_ url: URL) -> RemoteInstallerURLValidation {
        validate(url: url)
    }

    /// Validates every intermediate redirect target. Rejects scheme downgrade, credentials,
    /// query/fragment additions relative to the previous hop, and destinations outside the
    /// exact approved endpoint set.
    public static func validateRedirect(from previous: URL, to next: URL) -> RemoteInstallerURLValidation {
        if let message = validate(url: next).message {
            return .rejected(message)
        }
        let previousScheme = previous.scheme?.lowercased() ?? ""
        let nextScheme = next.scheme?.lowercased() ?? ""
        if previousScheme == "https", nextScheme != "https" {
            return .rejected("Installer redirect must not downgrade from HTTPS.")
        }
        if introducesQueryOrFragment(from: previous, to: next) {
            return .rejected("Installer redirect must not add query parameters or fragments.")
        }
        // Destination must still be an exact approved endpoint (enforced by validate(url:)).
        return .accepted
    }

    /// Validates the final response URL after redirects settle.
    public static func validateFinalURL(_ url: URL) -> RemoteInstallerURLValidation {
        validate(url: url)
    }

    /// Walks an ordered hop list (original + each redirect target, final last) and returns
    /// the first rejection. Empty lists are rejected.
    public static func validateURLChain(_ urls: [URL]) -> RemoteInstallerURLValidation {
        guard let first = urls.first else {
            return .rejected("Installer URL chain is empty.")
        }
        if let message = validateOriginalURL(first).message {
            return .rejected(message)
        }
        if urls.count == 1 {
            return validateFinalURL(first)
        }
        for index in 1..<urls.count {
            if let message = validateRedirect(from: urls[index - 1], to: urls[index]).message {
                return .rejected(message)
            }
        }
        return validateFinalURL(urls[urls.count - 1])
    }

    // MARK: Content type

    /// Accepts missing content types (some CDNs omit them) and common shell/text types.
    /// Rejects HTML and other non-script media types when present.
    public static func validateContentType(_ contentType: String?) -> RemoteInstallerContentTypeValidation {
        guard let raw = contentType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .accepted
        }
        let media = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        if media.isEmpty { return .accepted }
        let rejectedPrefixes = ["text/html", "application/xhtml", "image/", "audio/", "video/", "font/"]
        if rejectedPrefixes.contains(where: { media.hasPrefix($0) }) {
            return .rejected("Installer response content type is not a shell script (\(media)).")
        }
        let accepted: Set<String> = [
            "text/plain",
            "text/x-shellscript",
            "text/x-sh",
            "application/x-sh",
            "application/x-shellscript",
            "application/octet-stream"
        ]
        if accepted.contains(media) { return .accepted }
        // Unknown but non-HTML types are tolerated; body validation still enforces script shape.
        return .accepted
    }

    // MARK: Bounded body accumulation

    /// Appends `chunk` into `buffer`, failing closed when the combined size would exceed the limit.
    @discardableResult
    public static func accumulate(
        chunk: Data,
        into buffer: inout Data,
        maximumByteCount: Int = maximumByteCount
    ) -> BoundedBodyAccumulation {
        let observed = buffer.count + chunk.count
        if observed > maximumByteCount {
            return .exceeded(maximumByteCount: maximumByteCount, observedByteCount: observed)
        }
        buffer.append(chunk)
        if buffer.isEmpty {
            return .empty
        }
        return .ok(buffer)
    }

    /// Appends one streamed byte without allowing the body buffer past the cap.
    @discardableResult
    public static func accumulate(
        byte: UInt8,
        into buffer: inout Data,
        maximumByteCount: Int = maximumByteCount
    ) -> BoundedBodyAccumulation {
        guard buffer.count < maximumByteCount else {
            return .exceeded(maximumByteCount: maximumByteCount, observedByteCount: maximumByteCount + 1)
        }
        buffer.append(byte)
        return buffer.isEmpty ? .empty : .ok(buffer)
    }

    /// Accumulates an entire body from discrete chunks with a hard cap.
    public static func accumulate(
        chunks: [Data],
        maximumByteCount: Int = maximumByteCount
    ) -> BoundedBodyAccumulation {
        var buffer = Data()
        buffer.reserveCapacity(min(maximumByteCount, chunks.reduce(0) { $0 + $1.count }))
        for chunk in chunks {
            let result = accumulate(chunk: chunk, into: &buffer, maximumByteCount: maximumByteCount)
            if case .exceeded = result { return result }
        }
        if buffer.isEmpty { return .empty }
        return .ok(buffer)
    }

    // MARK: Body content validation

    public static func validationMessage(for data: Data) -> String? {
        guard !data.isEmpty else { return "Downloaded installer was empty." }
        guard data.count <= maximumByteCount else {
            return "Downloaded installer exceeded Lattice's 2 MB safety limit."
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return "Downloaded installer was not a UTF-8 shell script."
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#!") else {
            return "Downloaded installer did not contain a shell-script header."
        }
        let lowercased = trimmed.prefix(512).lowercased()
        guard !lowercased.contains("<html"), !lowercased.contains("<!doctype") else {
            return "Provider returned an HTML page instead of an installer."
        }
        return nil
    }

    // MARK: Digest / trust

    /// Lowercase hex SHA-256 of the raw bytes.
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Trust representation. When `expectedSHA256Hex` is nil/empty the result is always
    /// `.unsigned` — content checks alone never imply authenticity.
    public static func trust(
        for data: Data,
        expectedSHA256Hex: String? = nil
    ) -> InstallerScriptTrust {
        let normalizedExpected = expectedSHA256Hex?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let expected = normalizedExpected, !expected.isEmpty else {
            return .unsigned
        }
        let actual = sha256Hex(of: data)
        if actual == expected {
            return .digestMatched(sha256Hex: actual)
        }
        return .digestMismatch(expectedSHA256Hex: expected, actualSHA256Hex: actual)
    }

    /// Convenience: body content validation + trust evaluation for integration call sites.
    public static func evaluateDownload(
        data: Data,
        contentType: String? = nil,
        expectedSHA256Hex: String? = nil
    ) -> (contentMessage: String?, trust: InstallerScriptTrust) {
        if let typeMessage = validateContentType(contentType).message {
            return (typeMessage, trust(for: data, expectedSHA256Hex: expectedSHA256Hex))
        }
        return (validationMessage(for: data), trust(for: data, expectedSHA256Hex: expectedSHA256Hex))
    }

    // MARK: Helpers

    private static func normalizeEndpoint(_ url: URL) -> String {
        // Approved endpoints are exact absolute-string matches without credentials/query/fragment.
        // Rebuild a stable https://host/path form (drop trailing slash only when path is "/").
        var components = URLComponents()
        components.scheme = "https"
        components.host = url.host?.lowercased()
        components.port = url.port
        var path = url.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path.isEmpty ? "/" : path
        return components.string ?? url.absoluteString
    }

    private static func introducesQueryOrFragment(from previous: URL, to next: URL) -> Bool {
        let previousHadQuery = previous.query != nil
        let previousHadFragment = previous.fragment != nil
        if next.query != nil, !previousHadQuery { return true }
        if next.fragment != nil, !previousHadFragment { return true }
        // Any non-nil query/fragment is already rejected by validate(url:), but keep explicit.
        if next.query != nil || next.fragment != nil { return true }
        return false
    }
}
