import Foundation
import Testing
@testable import LatticeCore

@Suite("Durable session action text")
struct SessionActionTextPolicyTests {
    @Test func redactsCredentialHeadersTokensAndQuerySecrets() {
        let input = "Authorization: Bearer abcdefghijkl token=secret-value https://example.test/?api_key=url-secret&keep=yes sk-proj-1234567890"
        let sanitized = SessionActionTextPolicy.detail(input)
        #expect(!sanitized.contains("abcdefghijkl"))
        #expect(!sanitized.contains("secret-value"))
        #expect(!sanitized.contains("url-secret"))
        #expect(!sanitized.contains("sk-proj-1234567890"))
        #expect(sanitized.contains("[REDACTED]"))
        #expect(sanitized.contains("keep=yes"))
    }

    @Test func redactsEnvironmentVariablesQuotedCredentialsHandlesAndCLIOptions() {
        let input = """
        OPENAI_API_KEY=env-openai-secret AWS_SECRET_ACCESS_KEY='env-aws-secret' SLACK_BOT_TOKEN="env-slack-secret"
        {"api_key":"json-api-secret","client_secret":"json-client-secret","session_id":"antigravity-session-secret","sessionId":"json-session-secret","thread_id":"json-snake-thread-secret","threadId":"json-thread-secret","provider_session_id":"json-snake-provider-secret","providerSessionID":"json-provider-secret","harnessThreadID":"json-harness-secret"}
        --api-key cli-api-secret --token=cli-token-secret --session-id cli-session-secret --thread-id=cli-thread-secret --client-secret cli-client-secret https://example.test/?client_secret=query-client-secret --other ordinary-value TOKEN_COUNT=42
        """
        let sanitized = SessionActionTextPolicy.detail(input)
        for secret in [
            "env-openai-secret", "env-aws-secret", "env-slack-secret", "json-api-secret",
            "json-client-secret", "antigravity-session-secret", "json-session-secret",
            "json-snake-thread-secret", "json-thread-secret", "json-snake-provider-secret",
            "json-provider-secret", "json-harness-secret", "cli-api-secret", "cli-token-secret",
            "cli-session-secret", "cli-thread-secret", "cli-client-secret", "query-client-secret"
        ] {
            #expect(!sanitized.contains(secret))
        }
        #expect(sanitized.contains("--other ordinary-value"))
        #expect(sanitized.contains("TOKEN_COUNT=42"))
    }

    @Test func authorizationRedactionPreservesSchemeAndIsIdempotent() {
        let header = SessionActionTextPolicy.detail("Authorization: Bearer abcdefghijkl")
        #expect(header == "Authorization: Bearer [REDACTED]")
        #expect(SessionActionTextPolicy.detail(header) == header)

        let quoted = SessionActionTextPolicy.detail(#"{"authorization":"Basic abcdefghijkl"}"#)
        #expect(quoted == #"{"authorization":"Basic [REDACTED]"}"#)
        #expect(SessionActionTextPolicy.detail(quoted) == quoted)
    }

    @Test func redactsExactAntigravitySessionIDField() {
        let input = #"{"type":"init","session_id":"antigravity-session-secret"}"#
        let sanitized = SessionActionTextPolicy.detail(input)
        #expect(sanitized == #"{"type":"init","session_id":"[REDACTED]"}"#)
        #expect(SessionActionTextPolicy.detail(sanitized) == sanitized)
    }

    @Test func redactsEntireQuotedMultiwordAndEscapedQuoteValues() {
        let input = #"{"client_secret":"two word secret","password":"correct horse battery staple","token":"prefix \"escaped\" suffix secret"}"#
        let expected = #"{"client_secret":"[REDACTED]","password":"[REDACTED]","token":"[REDACTED]"}"#
        let sanitized = SessionActionTextPolicy.detail(input)
        #expect(sanitized == expected)
        #expect(SessionActionTextPolicy.detail(sanitized) == expected)
    }

    @Test func redactsWholeCookieAndColonCredentialLinesBeforePersistence() throws {
        let cookie = SessionActionTextPolicy.detail("Cookie: session=first-secret; csrf=second-secret")
        #expect(cookie == "Cookie: [REDACTED]")
        #expect(SessionActionTextPolicy.detail(cookie) == cookie)

        let setCookie = SessionActionTextPolicy.detail("Set-Cookie: session=first-secret; Path=/; HttpOnly")
        #expect(setCookie == "Set-Cookie: [REDACTED]")
        #expect(SessionActionTextPolicy.detail(setCookie) == setCookie)

        let password = SessionActionTextPolicy.detail("password: correct horse battery staple")
        #expect(password == "password: [REDACTED]")
        #expect(SessionActionTextPolicy.detail(password) == password)
        #expect(SessionActionTextPolicy.detail("password=single-secret keep=value") == "password=[REDACTED] keep=value")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-action-header-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let action = SessionAction(
            messageID: UUID(),
            kind: .diagnostic,
            title: "Headers",
            detail: "Cookie: session=first-secret; csrf=second-secret\npassword: correct horse battery staple",
            status: .completed
        )
        try store.save([LatticeSession(title: "Headers", backend: .ollama(model: "local"), actions: [action])])
        let raw = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        for secret in ["first-secret", "second-secret", "correct horse battery staple"] {
            #expect(!raw.contains(secret))
        }
    }

    @Test func unquotedValuesPreserveJSONDelimiters() throws {
        let cases = [
            (
                #"{"cmd":"OPENAI_API_KEY=secret"}"#,
                #"{"cmd":"OPENAI_API_KEY=[REDACTED]"}"#
            ),
            (
                #"{"cmd":"--token secret"}"#,
                #"{"cmd":"--token [REDACTED]"}"#
            ),
            (
                #"{"url":"https://example.test/?token=secret"}"#,
                #"{"url":"https://example.test/?token=[REDACTED]"}"#
            ),
            (
                #"{"cmd":"OPENAI_API_KEY=\"quoted env secret\""}"#,
                #"{"cmd":"OPENAI_API_KEY=[REDACTED]"}"#
            ),
            (
                #"{"cmd":"tool --token \"quoted cli secret\""}"#,
                #"{"cmd":"tool --token [REDACTED]"}"#
            )
        ]
        for (input, expected) in cases {
            let sanitized = SessionActionTextPolicy.detail(input)
            #expect(sanitized == expected)
            #expect(SessionActionTextPolicy.detail(sanitized) == expected)
            _ = try JSONSerialization.jsonObject(with: Data(sanitized.utf8))
        }

        let pretty = """
        {
          "password": "secret",
          "keep": "yes"
        }
        """
        let prettySanitized = SessionActionTextPolicy.detail(pretty)
        let prettyObject = try #require(
            JSONSerialization.jsonObject(with: Data(prettySanitized.utf8)) as? [String: String]
        )
        #expect(prettyObject["password"] == "[REDACTED]")
        #expect(prettyObject["keep"] == "yes")
        #expect(SessionActionTextPolicy.detail(prettySanitized) == prettySanitized)
    }

    @Test func truncatedQuotedSensitiveTailFailsClosedBeforeOutputBounding() throws {
        let limit = SessionActionTextPolicy.maximumInputCharacterCount
        let sentinel = "boundary-password-secret"
        let assignmentPrefix = "password=\""
        let tokenUnit = "token=" + String(repeating: "e", count: 180) + " "
        let visibleTailCount = assignmentPrefix.count + sentinel.count + 8
        let preludeTarget = limit - visibleTailCount
        let tokenCount = preludeTarget / tokenUnit.count
        let padding = String(repeating: " ", count: preludeTarget - (tokenCount * tokenUnit.count))
        let input = String(repeating: tokenUnit, count: tokenCount)
            + padding
            + assignmentPrefix
            + sentinel
            + String(repeating: "z", count: 128)
            + "\""
        let expected = SessionActionTextPolicy.oversizedInputMarker

        #expect(input.count > limit)
        #expect(String(input.prefix(limit)).contains(sentinel))
        let sanitized = SessionActionTextPolicy.detail(input)
        #expect(sanitized == expected)
        #expect(!sanitized.contains(sentinel))
        #expect(sanitized.utf8.count <= SessionActionTextPolicy.maximumDetailUTF8ByteCount)
        #expect(SessionActionTextPolicy.detail(sanitized) == sanitized)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-action-boundary-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let action = SessionAction(messageID: UUID(), kind: .diagnostic, title: "Boundary", detail: input, status: .completed)
        let residualAction = SessionAction(
            messageID: UUID(),
            kind: .diagnostic,
            title: "Residual secrets",
            detail: "prefix password: embedded-password-secret suffix | Cookie: embedded-cookie-secret | {\\\"token\\\":\\\"nested-token-secret\\\"} | OPENAI_API_KEY=\\\"escaped-env-secret\\\" | --token \\'escaped-cli-secret\\'",
            status: .completed
        )
        let compactCookieAction = SessionAction(
            messageID: UUID(),
            kind: .diagnostic,
            title: "Compact cookie",
            detail: #"{"headers":"Cookie: session=compact-first-secret; csrf=compact-second-secret"}"#,
            status: .completed
        )
        let delimiterLeakAction = SessionAction(
            messageID: UUID(),
            kind: .diagnostic,
            title: "Delimiter suffixes",
            detail: #"token=first-delimiter-secret; second-delimiter-secret | password=third-delimiter-secret, fourth-delimiter-secret | --token fifth-delimiter-secret&sixth-delimiter-secret | https://x.test/?password[]=bracket-query-secret | https://x.test/?password%5B%5D=encoded-bracket-secret&broken=%ZZ | https://x.test/?pass%25252577ord=four-pass-secret | {"headers":"Cookie: session=cookie-comma-first-secret, csrf=cookie-comma-second-secret"} | {"headers":"Cookie: session=escaped-cookie-first-secret\",csrf=escaped-cookie-second-secret"} | prefix {"pass\u0077ord":"embedded-unicode-secret"} suffix | {"payload":"{\"pass\\u0077ord\":\"nested-unicode-secret\"}"}"#,
            status: .completed
        )
        try store.save([LatticeSession(title: "Boundary", backend: .ollama(model: "local"), actions: [action, residualAction, compactCookieAction, delimiterLeakAction])])
        let raw = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        #expect(!raw.contains(sentinel))
        #expect(!raw.contains(String(repeating: "z", count: 16)))
        for secret in ["embedded-password-secret", "embedded-cookie-secret", "nested-token-secret", "escaped-env-secret", "escaped-cli-secret", "compact-first-secret", "compact-second-secret", "first-delimiter-secret", "second-delimiter-secret", "third-delimiter-secret", "fourth-delimiter-secret", "fifth-delimiter-secret", "sixth-delimiter-secret", "bracket-query-secret", "encoded-bracket-secret", "four-pass-secret", "cookie-comma-first-secret", "cookie-comma-second-secret", "escaped-cookie-first-secret", "escaped-cookie-second-secret", "embedded-unicode-secret", "nested-unicode-secret"] {
            #expect(!raw.contains(secret))
        }
    }

    @Test func oversizedCredentialPrefixesFailClosedAndRemainIdempotent() {
        let prefixes = ["sk-", "ghp_", "github_pat_", "xoxb-", "AIza", "AKIA", "npm_", "hf_", "gsk_", "xai-", "cred_"]
        for prefix in prefixes {
            let sentinel = prefix + "boundary-secret-value"
            let input = String(repeating: "ordinary-token ", count: 1_200) + sentinel
            let sanitized = SessionActionTextPolicy.detail(input)
            #expect(sanitized == SessionActionTextPolicy.oversizedInputMarker)
            #expect(!sanitized.contains(sentinel))
            #expect(SessionActionTextPolicy.detail(sanitized) == sanitized)
        }
    }

    @Test func unresolvedEmbeddedAndEscapedSensitiveSuffixesFailClosed() {
        let inputs = [
            "prefix password: embedded-password-secret suffix",
            "prefix Cookie: embedded-cookie-secret suffix",
            #"{"headers":"Cookie: session=first-secret; csrf=second-secret"}"#,
            #"{"headers":"Cookie: session=first-secret, csrf=second-secret"}"#,
            #"{"headers":"Cookie: session=first-secret&csrf=second-secret"}"#,
            "prefix token=first-secret; second-secret",
            "prefix password=first-secret, second-secret",
            "prefix --token first-secret, second-secret",
            "prefix Authorization: Bearer first-secret, Basic second-secret",
            "https://x.test/?password[]=first-secret",
            "https://x.test/?password%5B%5D=encoded-bracket-secret",
            "https://x.test/?pass%77ord=encoded-name-secret",
            "https://x.test/?password%5B%5D=encoded-secret&broken=%ZZ",
            "https://x.test/?pass%25252577ord=four-pass-secret",
            #"{"headers":"Cookie: session=escaped-cookie-first-secret\",csrf=escaped-cookie-second-secret"}"#,
            #"{"cmd":"OPENAI_API_KEY=escaped-env-first-secret\";escaped-env-second-secret"}"#,
            #"{"pass\u0077ord":"unicode-key-secret"}"#,
            #"prefix {"pass\u0077ord":"embedded-unicode-secret"} suffix"#,
            #"""
            {"keep":"yes"}
            {"pass\u0077ord":"json-lines-secret"}
            """#,
            #"{"payload":"{\"pass\\u0077ord\":\"nested-unicode-secret\"}"}"#,
            #"wrapper {\"token\":\"nested-token-secret\"} tail"#,
            #"wrapper {\"session_id\":\"nested-session-secret\"} tail"#,
            #"wrapper OPENAI_API_KEY=\"escaped-env-secret\" suffix"#,
            #"wrapper --token \'escaped-cli-secret\' suffix"#
        ]
        for input in inputs {
            let sanitized = SessionActionTextPolicy.detail(input)
            #expect(sanitized == SessionActionTextPolicy.oversizedInputMarker)
            #expect(SessionActionTextPolicy.detail(sanitized) == sanitized)
            #expect(!sanitized.contains("secret"))
        }
    }

    @Test func cliFailureCrossingFourThousandNinetySixCharactersFailsClosed() {
        let secret = "cli-boundary-password-secret"
        let line = String(repeating: "x", count: 4_090) + " password=\"\(secret) trailing\""
        #expect(line.count > 4_096)
        let message = CLIActionStatusPolicy.failureMessage(
            prefix: "Install failed",
            output: Data((line + "\n").utf8)
        )
        #expect(!message.contains(secret))
        #expect(message.contains(SessionActionTextPolicy.oversizedInputMarker))
    }

    @Test func normalizesControlsAndCapsUTF8Output() {
        let input = String(repeating: "é", count: 10_000) + "\u{0000}\n\t"
        let sanitized = SessionActionTextPolicy.detail(input)
        #expect(sanitized.utf8.count <= SessionActionTextPolicy.maximumDetailUTF8ByteCount)
        #expect(!sanitized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
    }

    @Test func initializerAndLegacyDecodeSanitizeBeforePersistence() throws {
        let messageID = UUID()
        let action = SessionAction(
            messageID: messageID,
            kind: .tool,
            title: "\u{0000} Build token=title-secret",
            detail: "Authorization: Bearer abcdefghijkl",
            status: .completed
        )
        #expect(!action.title.contains("title-secret"))
        #expect(!action.detail.contains("abcdefghijkl"))

        let legacy = """
        {"id":"\(action.id.uuidString)","messageID":"\(messageID.uuidString)","kind":"tool","title":"\\u0000 token=legacy-title-secret","detail":"password=legacy-secret","status":"completed","workspaceScoped":false}
        """
        let decoded = try JSONDecoder().decode(SessionAction.self, from: Data(legacy.utf8))
        #expect(!decoded.title.contains("legacy-title-secret"))
        #expect(!decoded.detail.contains("legacy-secret"))
        let encoded = try JSONEncoder().encode(decoded)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("legacy-secret"))
        #expect(!json.contains("legacy-title-secret"))
    }

    @Test func mutableDetailCannotBypassDurablePolicy() {
        var action = SessionAction(messageID: UUID(), kind: .diagnostic, title: "Diagnostic", detail: "safe", status: .failed)
        action.detail = "token=mutated-secret\u{0000}"
        #expect(!action.detail.contains("mutated-secret"))
        #expect(!action.detail.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
    }
}
