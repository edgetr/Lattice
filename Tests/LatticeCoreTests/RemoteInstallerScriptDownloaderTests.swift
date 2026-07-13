import Foundation
import Testing
@testable import LatticeCore

@Suite("Remote installer script downloader", .serialized)
struct RemoteInstallerScriptDownloaderTests {
    private let endpoint = URL(string: "https://x.ai/cli/install.sh")!

    @Test func oversizedBodyFailsAtHardCap() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        InstallerTestURLProtocol.state.configure(
            body: Data(repeating: 65, count: 129),
            delay: 0
        )

        let downloader = RemoteInstallerScriptDownloader(
            session: session,
            requestTimeout: 1,
            maximumByteCount: 128
        )

        do {
            _ = try await downloader.download(from: endpoint)
            Issue.record("Oversized installer body must be rejected")
        } catch let error as RemoteInstallerScriptDownloadError {
            if case .bodyLimit(let maximum, let observed) = error {
                #expect(maximum == 128)
                #expect(observed == 129)
            } else {
                Issue.record("Expected hard body-limit error, got \(error)")
            }
        } catch {
            Issue.record("Expected typed body-limit error, got \(error)")
        }
    }

    @Test func slowBodyTimesOutAndReturnsBounded() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        InstallerTestURLProtocol.state.configure(
            body: Data("#!/bin/bash\n".utf8),
            delay: 0.25
        )

        let downloader = RemoteInstallerScriptDownloader(
            session: session,
            requestTimeout: 0.05,
            maximumByteCount: 128
        )
        let startedAt = Date()

        do {
            _ = try await downloader.download(from: endpoint)
            Issue.record("Slow installer body must time out")
        } catch let error as RemoteInstallerScriptDownloadError {
            #expect(error == .timedOut)
            #expect(Date().timeIntervalSince(startedAt) < 2)
        } catch {
            Issue.record("Expected typed timeout error, got \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstallerTestURLProtocol.self]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

private final class InstallerTestURLProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var body = Data()
        private var delay: TimeInterval = 0

        func configure(body: Data, delay: TimeInterval) {
            lock.lock()
            self.body = body
            self.delay = delay
            lock.unlock()
        }

        func snapshot() -> (body: Data, delay: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            return (body, delay)
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "x.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let snapshot = Self.state.snapshot()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/plain"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if snapshot.delay > 0 {
            Thread.sleep(forTimeInterval: snapshot.delay)
        }
        client?.urlProtocol(self, didLoad: snapshot.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
