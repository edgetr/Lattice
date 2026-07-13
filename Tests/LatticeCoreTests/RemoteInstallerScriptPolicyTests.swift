import Testing
import Foundation
import CryptoKit
@testable import LatticeCore

@Suite("Remote installer script policy")
struct RemoteInstallerScriptPolicyTests {
    private let approvedGrok = URL(string: "https://x.ai/cli/install.sh")!
    private let approvedOpenCode = URL(string: "https://opencode.ai/install")!
    private let approvedHermes = URL(string: "https://hermes-agent.nousresearch.com/install.sh")!
    private let unapproved = URL(string: "https://antigravity.google/cli/install.sh")!
    private let validScript = Data("#!/bin/bash\nset -e\necho install\n".utf8)

    // MARK: Original / final URL

    @Test func acceptsExactApprovedEndpoints() {
        for url in [approvedGrok, approvedOpenCode, approvedHermes] {
            #expect(RemoteInstallerScriptPolicy.validateOriginalURL(url).isAccepted)
            #expect(RemoteInstallerScriptPolicy.validateFinalURL(url).isAccepted)
            #expect(RemoteInstallerScriptPolicy.validationMessage(for: url) == nil)
        }
    }

    @Test func rejectsUnapprovedEndpoint() {
        let result = RemoteInstallerScriptPolicy.validate(url: unapproved)
        #expect(!result.isAccepted)
        #expect(result.message?.contains("approved") == true)
    }

    @Test func rejectsHTTPAndCredentialsAndQueryFragment() {
        #expect(RemoteInstallerScriptPolicy.validate(url: URL(string: "http://x.ai/cli/install.sh")!).message != nil)
        #expect(RemoteInstallerScriptPolicy.validate(url: URL(string: "https://user:pass@x.ai/cli/install.sh")!).message != nil)
        #expect(RemoteInstallerScriptPolicy.validate(url: URL(string: "https://x.ai/cli/install.sh?x=1")!).message != nil)
        #expect(RemoteInstallerScriptPolicy.validate(url: URL(string: "https://x.ai/cli/install.sh#frag")!).message != nil)
    }

    // MARK: Redirects

    @Test func acceptsRedirectBetweenApprovedEndpoints() {
        let result = RemoteInstallerScriptPolicy.validateRedirect(from: approvedGrok, to: approvedOpenCode)
        #expect(result.isAccepted)
    }

    @Test func rejectsRedirectToUnapprovedHost() {
        let result = RemoteInstallerScriptPolicy.validateRedirect(from: approvedGrok, to: unapproved)
        #expect(!result.isAccepted)
    }

    @Test func rejectsHTTPSDowngradeOnRedirect() {
        let http = URL(string: "http://x.ai/cli/install.sh")!
        // validate(url:) already rejects http; message must be non-nil either way.
        let result = RemoteInstallerScriptPolicy.validateRedirect(from: approvedGrok, to: http)
        #expect(!result.isAccepted)
    }

    @Test func rejectsQueryOrFragmentAdditionOnRedirect() {
        let withQuery = URL(string: "https://x.ai/cli/install.sh?token=1")!
        let withFragment = URL(string: "https://x.ai/cli/install.sh#part")!
        let withCredentials = URL(string: "https://user:pass@opencode.ai/install")!
        #expect(!RemoteInstallerScriptPolicy.validateRedirect(from: approvedGrok, to: withQuery).isAccepted)
        #expect(!RemoteInstallerScriptPolicy.validateRedirect(from: approvedGrok, to: withFragment).isAccepted)
        #expect(!RemoteInstallerScriptPolicy.validateRedirect(from: approvedGrok, to: withCredentials).isAccepted)
    }

    @Test func validateURLChainWalksEveryHop() {
        #expect(RemoteInstallerScriptPolicy.validateURLChain([approvedGrok, approvedOpenCode, approvedHermes]).isAccepted)
        #expect(!RemoteInstallerScriptPolicy.validateURLChain([approvedGrok, unapproved]).isAccepted)
        #expect(!RemoteInstallerScriptPolicy.validateURLChain([]).isAccepted)
        #expect(RemoteInstallerScriptPolicy.validateURLChain([approvedGrok]).isAccepted)
    }

    // MARK: Body / oversize / content type

    @Test func acceptsBoundedUTF8ShellScript() {
        #expect(RemoteInstallerScriptPolicy.validationMessage(for: validScript) == nil)
    }

    @Test func rejectsHTMLAndOversizedBodies() {
        #expect(RemoteInstallerScriptPolicy.validationMessage(for: Data("<html>not a script</html>".utf8)) != nil)
        let oversized = Data(repeating: 65, count: RemoteInstallerScriptPolicy.maximumByteCount + 1)
        #expect(RemoteInstallerScriptPolicy.validationMessage(for: oversized) != nil)
        #expect(RemoteInstallerScriptPolicy.validationMessage(for: Data()) != nil)
    }

    @Test func boundedAccumulationCapsChunks() {
        var buffer = Data()
        let ok = RemoteInstallerScriptPolicy.accumulate(
            chunk: Data(repeating: 1, count: 100),
            into: &buffer,
            maximumByteCount: 150
        )
        #expect(ok.data?.count == 100)

        let exceeded = RemoteInstallerScriptPolicy.accumulate(
            chunk: Data(repeating: 2, count: 100),
            into: &buffer,
            maximumByteCount: 150
        )
        if case .exceeded(let max, let observed) = exceeded {
            #expect(max == 150)
            #expect(observed == 200)
        } else {
            Issue.record("Expected exceeded accumulation")
        }

        let multi = RemoteInstallerScriptPolicy.accumulate(
            chunks: [Data(repeating: 9, count: 80), Data(repeating: 9, count: 80)],
            maximumByteCount: 100
        )
        if case .exceeded = multi {
            #expect(true)
        } else {
            Issue.record("Multi-chunk accumulate must fail closed past the cap")
        }
    }

    @Test func contentTypeRejectsHTMLAllowsShellAndMissing() {
        #expect(RemoteInstallerScriptPolicy.validateContentType(nil).message == nil)
        #expect(RemoteInstallerScriptPolicy.validateContentType("text/x-shellscript").message == nil)
        #expect(RemoteInstallerScriptPolicy.validateContentType("text/plain; charset=utf-8").message == nil)
        #expect(RemoteInstallerScriptPolicy.validateContentType("text/html").message != nil)
        #expect(RemoteInstallerScriptPolicy.validateContentType("image/png").message != nil)
    }

    // MARK: Digest / trust

    @Test func trustIsUnsignedWithoutPin() {
        let trust = RemoteInstallerScriptPolicy.trust(for: validScript, expectedSHA256Hex: nil)
        #expect(trust == .unsigned)
        #expect(!trust.isAuthenticated)
        #expect(trust.summary.lowercased().contains("unsigned"))
    }

    @Test func trustMatchesAndMismatchesPinnedDigest() {
        let hex = RemoteInstallerScriptPolicy.sha256Hex(of: validScript)
        #expect(hex.count == 64)
        #expect(RemoteInstallerScriptPolicy.trust(for: validScript, expectedSHA256Hex: hex) == .digestMatched(sha256Hex: hex))
        #expect(RemoteInstallerScriptPolicy.trust(for: validScript, expectedSHA256Hex: hex.uppercased()) == .digestMatched(sha256Hex: hex))

        let other = RemoteInstallerScriptPolicy.trust(for: validScript, expectedSHA256Hex: String(repeating: "ab", count: 32))
        if case .digestMismatch(let expected, let actual) = other {
            #expect(expected == String(repeating: "ab", count: 32))
            #expect(actual == hex)
            #expect(!other.isAuthenticated)
        } else {
            Issue.record("Expected digest mismatch")
        }
    }

    @Test func evaluateDownloadCombinesContentAndTrust() {
        let (message, trust) = RemoteInstallerScriptPolicy.evaluateDownload(
            data: validScript,
            contentType: "text/plain",
            expectedSHA256Hex: nil
        )
        #expect(message == nil)
        #expect(trust == .unsigned)

        let (htmlMessage, _) = RemoteInstallerScriptPolicy.evaluateDownload(
            data: validScript,
            contentType: "text/html"
        )
        #expect(htmlMessage != nil)
    }

    @Test func sha256MatchesCryptoKitReference() {
        let data = Data("lattice-installer".utf8)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(RemoteInstallerScriptPolicy.sha256Hex(of: data) == expected)
    }
}
