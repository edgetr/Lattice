import Foundation

public struct RemoteInstallerScriptDownload: Sendable, Equatable {
    public let data: Data
    public let finalURL: URL
    public let statusCode: Int
    public let contentType: String?

    public init(data: Data, finalURL: URL, statusCode: Int, contentType: String?) {
        self.data = data
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.contentType = contentType
    }
}

public enum RemoteInstallerScriptDownloadError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case redirectRejected(String)
    case responseRejected
    case contentRejected(String)
    case bodyLimit(maximumByteCount: Int, observedByteCount: Int)
    case timedOut
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let message):
            return message
        case .redirectRejected(let message):
            return message
        case .responseRejected:
            return "Provider installer download failed."
        case .contentRejected(let message):
            return message
        case .bodyLimit(let maximum, _):
            return "Downloaded installer exceeded Lattice's \(maximum / 1_000_000) MB safety limit."
        case .timedOut:
            return "Installer download timed out."
        case .transport(let message):
            return "Installer download failed: \(message)"
        }
    }
}

/// Downloads installer bytes with a hard total deadline and a bounded in-memory body.
public final class RemoteInstallerScriptDownloader: @unchecked Sendable {
    public static let requestTimeout: TimeInterval = 15
    public static let resourceTimeout: TimeInterval = 60

    private let session: URLSession
    private let ownsSession: Bool
    private let requestTimeoutInterval: TimeInterval
    private let resourceTimeoutInterval: TimeInterval
    private let maximumByteCount: Int

    public init(
        session: URLSession? = nil,
        requestTimeout: TimeInterval = RemoteInstallerScriptDownloader.requestTimeout,
        resourceTimeout: TimeInterval = RemoteInstallerScriptDownloader.resourceTimeout,
        maximumByteCount: Int = RemoteInstallerScriptPolicy.maximumByteCount
    ) {
        self.requestTimeoutInterval = max(0.001, requestTimeout)
        self.resourceTimeoutInterval = max(0.001, resourceTimeout)
        self.maximumByteCount = max(1, maximumByteCount)
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = self.requestTimeoutInterval
            configuration.timeoutIntervalForResource = self.resourceTimeoutInterval
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            self.session = URLSession(configuration: configuration)
            self.ownsSession = true
        }
    }

    deinit {
        if ownsSession { session.invalidateAndCancel() }
    }

    public func download(from url: URL) async throws -> RemoteInstallerScriptDownload {
        guard RemoteInstallerScriptPolicy.validateOriginalURL(url).isAccepted else {
            throw RemoteInstallerScriptDownloadError.invalidURL(
                RemoteInstallerScriptPolicy.validationMessage(for: url) ?? "Invalid installer URL."
            )
        }
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: RemoteInstallerScriptDownload.self) { group in
            group.addTask { [self] in
                try await performDownload(from: url)
            }
            group.addTask { [resourceTimeoutInterval] in
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: resourceTimeoutInterval))
                throw RemoteInstallerScriptDownloadError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RemoteInstallerScriptDownloadError.transport("Installer download produced no result.")
            }
            return result
        }
    }

    private func performDownload(from url: URL) async throws -> RemoteInstallerScriptDownload {
        let delegate = RedirectValidationDelegate(originalURL: url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(requestTimeoutInterval, resourceTimeoutInterval)
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")

        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            if let message = delegate.rejectionMessage {
                throw RemoteInstallerScriptDownloadError.redirectRejected(message)
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw RemoteInstallerScriptDownloadError.responseRejected
            }
            guard let finalURL = http.url,
                  RemoteInstallerScriptPolicy.validateFinalURL(finalURL).isAccepted else {
                throw RemoteInstallerScriptDownloadError.redirectRejected(
                    "Provider installer redirected outside Lattice's approved endpoint."
                )
            }
            if let message = RemoteInstallerScriptPolicy
                .validateContentType(http.value(forHTTPHeaderField: "Content-Type"))
                .message {
                throw RemoteInstallerScriptDownloadError.contentRejected(message)
            }
            if http.expectedContentLength >= 0,
               http.expectedContentLength > Int64(maximumByteCount) {
                throw RemoteInstallerScriptDownloadError.bodyLimit(
                    maximumByteCount: maximumByteCount,
                    observedByteCount: Int(min(http.expectedContentLength, Int64(Int.max)))
                )
            }

            var body = Data()
            body.reserveCapacity(min(maximumByteCount, 64 * 1024))
            for try await byte in bytes {
                try Task.checkCancellation()
                let result = RemoteInstallerScriptPolicy.accumulate(
                    byte: byte,
                    into: &body,
                    maximumByteCount: maximumByteCount
                )
                if case .exceeded(let maximum, let observed) = result {
                    throw RemoteInstallerScriptDownloadError.bodyLimit(
                        maximumByteCount: maximum,
                        observedByteCount: observed
                    )
                }
            }

            return RemoteInstallerScriptDownload(
                data: body,
                finalURL: finalURL,
                statusCode: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type")
            )
        } catch let error as RemoteInstallerScriptDownloadError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw RemoteInstallerScriptDownloadError.timedOut
        } catch {
            if let message = delegate.rejectionMessage {
                throw RemoteInstallerScriptDownloadError.redirectRejected(message)
            }
            throw RemoteInstallerScriptDownloadError.transport(error.localizedDescription)
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        let value = max(1, seconds * 1_000_000_000)
        return UInt64(min(value, Double(UInt64.max)))
    }
}

private final class RedirectValidationDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalURL: URL
    private let lock = NSLock()
    private var storedRejectionMessage: String?

    init(originalURL: URL) {
        self.originalURL = originalURL
    }

    var rejectionMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedRejectionMessage
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let previousURL = response.url ?? task.currentRequest?.url ?? originalURL
        guard let nextURL = request.url else {
            reject("Installer redirect did not contain a URL.")
            completionHandler(nil)
            return
        }
        if let message = RemoteInstallerScriptPolicy.validateRedirect(from: previousURL, to: nextURL).message {
            reject(message)
            completionHandler(nil)
            return
        }

        // Installer endpoints need no ambient auth. Strip headers URLSession may have copied.
        var sanitized = request
        for field in ["Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie"] {
            sanitized.setValue(nil, forHTTPHeaderField: field)
        }
        completionHandler(sanitized)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            reject("Provider installer requested credentials.")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func reject(_ message: String) {
        lock.lock()
        storedRejectionMessage = message
        lock.unlock()
    }
}
