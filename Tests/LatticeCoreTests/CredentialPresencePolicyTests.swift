import Testing
import Foundation
@testable import LatticeCore

@Suite("Credential presence policy")
struct CredentialPresencePolicyTests {
    @Test func OpenCodeRequiresExpectedProviderShapeAndNonBlankKey() {
        #expect(!CredentialPresencePolicy.hasOpenCodeGoCredential(in: [:]))
        #expect(!CredentialPresencePolicy.hasOpenCodeGoCredential(in: ["opencode-go": NSNull()]))
        #expect(!CredentialPresencePolicy.hasOpenCodeGoCredential(in: [
            "opencode-go": ["type": "api", "key": "   "]
        ]))
        #expect(!CredentialPresencePolicy.hasOpenCodeGoCredential(in: [
            "opencode-go": ["type": "oauth", "key": "synthetic-test-value"]
        ]))
        #expect(CredentialPresencePolicy.hasOpenCodeGoCredential(in: [
            "opencode-go": ["type": "api", "key": "synthetic-test-value"]
        ]))
    }

    @Test func AntigravityRejectsUnreadableEmptyAndWrongShapeOAuthFiles() {
        #expect(!CredentialPresencePolicy.hasAntigravityOAuthCredential(in: Data()))
        #expect(!CredentialPresencePolicy.hasAntigravityOAuthCredential(in: Data("not-json".utf8)))
        #expect(!CredentialPresencePolicy.hasAntigravityOAuthCredential(in: Data("{}".utf8)))
        #expect(!CredentialPresencePolicy.hasAntigravityOAuthCredential(in: Data("{\"token\":\"synthetic-test-value\"}".utf8)))
        #expect(!CredentialPresencePolicy.hasAntigravityOAuthCredential(in: Data("{\"refresh_token\":\"   \"}".utf8)))
    }

    @Test func AntigravityAcceptsMinimalOAuthCredentialShapeWithoutInspectingSecretContents() {
        #expect(CredentialPresencePolicy.hasAntigravityOAuthCredential(in: Data("{\"refresh_token\":\"synthetic-test-value\"}".utf8)))
        #expect(CredentialPresencePolicy.hasAntigravityOAuthCredential(in: Data("{\"access_token\":\"synthetic-test-value\"}".utf8)))
    }

    @Test func AntigravityAccountCacheNeedsNonBlankActiveMarkerButIsNotOAuthCredential() {
        #expect(!CredentialPresencePolicy.hasAntigravityAccountMarker(in: Data("{}".utf8)))
        #expect(!CredentialPresencePolicy.hasAntigravityAccountMarker(in: Data("{\"active\":\"   \"}".utf8)))
        #expect(CredentialPresencePolicy.hasAntigravityAccountMarker(in: Data("{\"active\":\"synthetic@example.invalid\"}".utf8)))
        #expect(!CredentialPresencePolicy.hasAntigravityOAuthCredential(in: Data("{\"active\":\"synthetic@example.invalid\"}".utf8)))
    }
}
