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

/// Streams installer bytes through URLSession and never accumulates beyond the policy cap.
/// A per-request timeout bounds stalled transfers; the session resource timeout bounds total time.
public final class RemoteInstallerScriptDownloader: @unchecked Sendable {
    public static let requestTimeout: TimeInterval = 15
    public static let resourceTimeout: TimeInterval = 60

    private let session: URLSession
    private let ownsSession: Bool
    private let requestTimeoutInterval: TimeInterval
    private let maximumByteCount: Int

    public init(
        session: URLSession? = nil,
        requestTimeout: TimeInterval = RemoteInstallerScriptDownloader.requestTimeout,
        maximumByteCount: Int = RemoteInstallerScriptPolicy.maximumByteCount
    ) {
        self.requestTimeoutInterval = requestTimeout
        self.maximumByteCount = max(1, maximumByteCount)
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.resourceTimeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
            self.ownsSession = true
        }
    }

    public func download(from url: URL) async throws -> RemoteInstallerScriptDownload {
        defer {
            if ownsSession {
                session.invalidateAndCancel()
            }
        }
        if let message = RemoteInstallerScriptPolicy.validateOriginalURL(url).message {
            throw RemoteInstallerScriptDownloadError.invalidURL(message)
        }

        let delegate = RedirectValidationDelegate(originalURL: url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeoutInterval

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
            if let contentMessage = RemoteInstallerScriptPolicy
                .validateContentType(http.value(forHTTPHeaderField: "Content-Type"))
                .message {
                throw RemoteInstallerScriptDownloadError.contentRejected(contentMessage)
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
        completionHandler(request)
    }

    private func reject(_ message: String) {
        lock.lock()
        storedRejectionMessage = message
        lock.unlock()
    }
}
