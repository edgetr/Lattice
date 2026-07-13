import Foundation
import Testing
@testable import LatticeCore

@Suite("Remote installer script downloader", .serialized)
struct RemoteInstallerScriptDownloaderTests {
    private let endpoint = URL(string: "https://x.ai/cli/install.sh")!
    private let validScript = Data("#!/bin/bash\necho install\n".utf8)

    @Test func oversizedBodyFailsAtHardCap() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        InstallerTestURLProtocol.state.configure(body: Data(repeating: 65, count: 129))

        do {
            _ = try await RemoteInstallerScriptDownloader(
                session: session,
                requestTimeout: 1,
                resourceTimeout: 1,
                maximumByteCount: 128
            ).download(from: endpoint)
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

    @Test func totalDeadlineStopsSlowBody() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        InstallerTestURLProtocol.state.configure(body: validScript, delay: 0.25)
        let startedAt = Date()

        do {
            _ = try await RemoteInstallerScriptDownloader(
                session: session,
                requestTimeout: 1,
                resourceTimeout: 0.05,
                maximumByteCount: 128
            ).download(from: endpoint)
            Issue.record("Slow installer body must time out")
        } catch let error as RemoteInstallerScriptDownloadError {
            #expect(error == .timedOut)
            #expect(Date().timeIntervalSince(startedAt) < 1)
        } catch {
            Issue.record("Expected typed timeout error, got \(error)")
        }
    }

    @Test func credentialedRedirectRejectedBeforeSecondRequest() async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        InstallerTestURLProtocol.state.configure(
            body: validScript,
            redirectTarget: URL(string: "https://user:pass@opencode.ai/install")
        )

        do {
            _ = try await RemoteInstallerScriptDownloader(session: session, resourceTimeout: 1)
                .download(from: endpoint)
            Issue.record("Credentialed redirect must be rejected")
        } catch let error as RemoteInstallerScriptDownloadError {
            if case .redirectRejected = error {
                #expect(InstallerTestURLProtocol.state.requestCount == 1)
            } else {
                Issue.record("Expected redirect rejection, got \(error)")
            }
        } catch {
            Issue.record("Expected typed redirect error, got \(error)")
        }
    }

    @Test func approvedRedirectStripsAmbientAuthHeaders() async throws {
        let session = makeSession(additionalHeaders: [
            "Authorization": "Bearer test-token",
            "Proxy-Authorization": "Basic test-token",
            "Cookie": "session=test-token"
        ])
        defer { session.invalidateAndCancel() }
        InstallerTestURLProtocol.state.configure(
            body: validScript,
            redirectTarget: URL(string: "https://opencode.ai/install")
        )

        let download = try await RemoteInstallerScriptDownloader(session: session, resourceTimeout: 1)
            .download(from: endpoint)
        #expect(download.finalURL == URL(string: "https://opencode.ai/install")!)
        let redirectedHeaders = InstallerTestURLProtocol.state.requestHeaders.last ?? [:]
        #expect(redirectedHeaders["Authorization"] == nil)
        #expect(redirectedHeaders["Proxy-Authorization"] == nil)
        #expect(redirectedHeaders["Cookie"] == nil)
    }

    private func makeSession(additionalHeaders: [String: String] = [:]) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstallerTestURLProtocol.self]
        configuration.httpAdditionalHeaders = additionalHeaders
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
        private var redirectTarget: URL?
        private(set) var requestHeaders = [[String: String]]()

        func configure(body: Data, delay: TimeInterval = 0, redirectTarget: URL? = nil) {
            lock.lock()
            self.body = body
            self.delay = delay
            self.redirectTarget = redirectTarget
            requestHeaders.removeAll()
            lock.unlock()
        }

        func snapshot() -> (body: Data, delay: TimeInterval, redirectTarget: URL?) {
            lock.lock()
            defer { lock.unlock() }
            return (body, delay, redirectTarget)
        }

        func record(_ request: URLRequest) {
            lock.lock()
            requestHeaders.append(request.allHTTPHeaderFields ?? [:])
            lock.unlock()
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requestHeaders.count
        }
    }

    static let state = State()
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        ["x.ai", "opencode.ai", "hermes-agent.nousresearch.com", "antigravity.google"].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let snapshot = Self.state.snapshot()
        Self.state.record(request)
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let target = snapshot.redirectTarget, url.absoluteString == "https://x.ai/cli/install.sh" {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let deadline = Date().addingTimeInterval(snapshot.delay)
        while Date() < deadline {
            if isStopped { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard !isStopped else { return }
        client?.urlProtocol(self, didLoad: snapshot.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
