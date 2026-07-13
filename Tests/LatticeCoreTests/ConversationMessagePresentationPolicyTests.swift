import Foundation
import Testing
@testable import LatticeCore

@Suite("Conversation message presentation policy")
struct ConversationMessagePresentationPolicyTests {

    // MARK: - Timestamps

    @Test func roleLabelsAreDistinct() {
        #expect(MessageTimestampPresentationPolicy.roleLabel(for: .user) == "Your message")
        #expect(MessageTimestampPresentationPolicy.roleLabel(for: .assistant) == "Assistant message")
        #expect(MessageTimestampPresentationPolicy.roleLabel(for: .system) == "System message")
    }

    @Test func timestampUsesLocaleAndTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 12, hour: 15, minute: 45))!
        let locale = Locale(identifier: "en_US_POSIX")
        let formatted = MessageTimestampPresentationPolicy.formattedTimestamp(
            date,
            locale: locale,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        #expect(formatted.contains("2024"))
        #expect(formatted.contains("15:45") || formatted.contains("3:45") || formatted.contains("15.45"))
    }

    @Test func accessibilityMetadataCombinesRoleAndTime() {
        let date = Date(timeIntervalSince1970: 1_710_000_000)
        let meta = MessageTimestampPresentationPolicy.accessibilityMetadata(
            role: .assistant,
            date: date,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        #expect(meta.hasPrefix("Assistant message, "))
        #expect(meta.count > "Assistant message, ".count)
    }

    @Test func accessibilityMetadataAnnouncesGeneratingStateOnlyWhenRequested() {
        let date = Date(timeIntervalSince1970: 1_710_000_000)
        let normal = MessageTimestampPresentationPolicy.accessibilityMetadata(
            role: .assistant,
            date: date,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let generating = MessageTimestampPresentationPolicy.accessibilityMetadata(
            role: .assistant,
            date: date,
            isGenerating: true,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(!normal.contains("Generating response"))
        #expect(generating.contains("Assistant message, Generating response"))
        #expect(generating.contains("2024"))
    }

    // MARK: - Provenance

    @Test func provenanceUsesBackendProviderAndModel() {
        let p = ChatRouteProvenancePresentationPolicy.provenance(
            backend: .codex(model: "gpt-5"),
            sessionHarnessID: "codex"
        )
        #expect(p.provider == "Codex")
        #expect(p.model == "gpt-5")
        #expect(p.displayLine == "Codex · gpt-5")
        #expect(p.harnessLabel == nil)
        #expect(p.accessibilityLabel.contains("Codex"))
        #expect(p.accessibilityLabel.contains("gpt-5"))
    }

    @Test func provenanceIncludesDistinctHarness() {
        let p = ChatRouteProvenancePresentationPolicy.provenance(
            backend: .openCode(model: "anthropic/claude"),
            sessionHarnessID: "pi"
        )
        #expect(p.provider == "OpenCode")
        #expect(p.model == "anthropic/claude")
        #expect(p.harnessLabel == "Pi")
        #expect(p.displayLine == "OpenCode · anthropic/claude · Pi")
        #expect(p.accessibilityLabel.contains("harness Pi"))
    }

    @Test func provenanceResolvesMissingHarnessIDToDefault() {
        #expect(ChatRouteProvenancePresentationPolicy.defaultHarnessID(for: .grok(model: "grok-3")) == "grok")
        #expect(ChatRouteProvenancePresentationPolicy.resolvedHarnessID(sessionHarnessID: nil, backend: .ollama(model: "llama3")) == "lattice")
        #expect(ChatRouteProvenancePresentationPolicy.resolvedHarnessID(sessionHarnessID: "  ", backend: .codex(model: "x")) == "codex")
        #expect(ChatRouteProvenancePresentationPolicy.harnessDisplayName(for: "hermes") == "Hermes")
    }

    @Test func appleIntelligenceProvenanceIsRestrained() {
        let p = ChatRouteProvenancePresentationPolicy.provenance(
            backend: .appleIntelligence,
            sessionHarnessID: "lattice"
        )
        #expect(p.provider == "On-device")
        #expect(p.model == "Apple Intelligence")
        #expect(p.displayLine.contains("On-device"))
        #expect(p.displayLine.contains("Apple Intelligence"))
        #expect(p.displayLine.contains("Lattice"))
    }

    // MARK: - Fenced code segments

    @Test func plainTextIsSingleSegment() {
        let segments = MessageContentPresentationPolicy.segments(from: "Hello\nworld")
        #expect(segments == [.text("Hello\nworld")])
        #expect(!MessageContentPresentationPolicy.containsFencedCode("Hello\nworld"))
    }

    @Test func emptyTextYieldsNoSegments() {
        #expect(MessageContentPresentationPolicy.segments(from: "").isEmpty)
    }

    @Test func parsesLanguageTaggedFence() {
        let raw = """
        Intro
        ```swift
        let x = 1
        ```
        Outro
        """
        let segments = MessageContentPresentationPolicy.segments(from: raw)
        #expect(segments.count == 3)
        guard case .text(let intro) = segments[0] else {
            Issue.record("Expected leading text"); return
        }
        #expect(intro == "Intro")
        guard case .codeBlock(let language, let code) = segments[1] else {
            Issue.record("Expected code block"); return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1")
        guard case .text(let outro) = segments[2] else {
            Issue.record("Expected trailing text"); return
        }
        #expect(outro == "Outro")
        #expect(MessageContentPresentationPolicy.containsFencedCode(raw))
    }

    @Test func preservesCodeInteriorExactly() {
        let raw = """
        ```
        line 1

            indented
        ```
        """
        let segments = MessageContentPresentationPolicy.segments(from: raw)
        #expect(segments.count == 1)
        guard case .codeBlock(let language, let code) = segments[0] else {
            Issue.record("Expected sole code block"); return
        }
        #expect(language == "")
        #expect(code == "line 1\n\n    indented")
    }

    @Test func unclosedFenceBecomesCodeToEnd() {
        let raw = """
        before
        ```python
        print(1)
        still code
        """
        let segments = MessageContentPresentationPolicy.segments(from: raw)
        #expect(segments.count == 2)
        guard case .text(let before) = segments[0] else {
            Issue.record("Expected text before fence"); return
        }
        #expect(before == "before")
        guard case .codeBlock(let language, let code) = segments[1] else {
            Issue.record("Expected unclosed code"); return
        }
        #expect(language == "python")
        #expect(code == "print(1)\nstill code")
    }

    @Test func doesNotTreatHTMLAsStructure() {
        let raw = "<div onclick=\"alert(1)\">hello</div>"
        let segments = MessageContentPresentationPolicy.segments(from: raw)
        #expect(segments == [.text(raw)])
    }

    @Test func multipleFencesAreSeparateBlocks() {
        let raw = """
        ```js
        a
        ```
        mid
        ```
        b
        ```
        """
        let segments = MessageContentPresentationPolicy.segments(from: raw)
        #expect(segments.count == 3)
        guard case .codeBlock(let lang1, let code1) = segments[0] else {
            Issue.record("Expected first code"); return
        }
        #expect(lang1 == "js")
        #expect(code1 == "a")
        guard case .text(let mid) = segments[1] else {
            Issue.record("Expected mid text"); return
        }
        #expect(mid == "mid")
        guard case .codeBlock(let lang2, let code2) = segments[2] else {
            Issue.record("Expected second code"); return
        }
        #expect(lang2 == "")
        #expect(code2 == "b")
    }

    // MARK: - Error presentation

    @Test func shortErrorIsHeadlineOnly() {
        let p = ConversationErrorPresentationPolicy.presentation(for: "Choose a connected model.")
        #expect(p.headline == "Choose a connected model.")
        #expect(p.detail == nil)
        #expect(p.accessibilityLabel == "Error")
        #expect(p.accessibilityValue == "Choose a connected model.")
    }

    @Test func multilineErrorSplitsHeadlineAndDetail() {
        let p = ConversationErrorPresentationPolicy.presentation(for: "Route unavailable\nCodex is not signed in.")
        #expect(p.headline == "Route unavailable")
        #expect(p.detail == "Codex is not signed in.")
        #expect(p.accessibilityValue == "Route unavailable. Codex is not signed in.")
    }

    @Test func titleColonDetailSplitsWhenTitleShort() {
        let p = ConversationErrorPresentationPolicy.presentation(for: "Codex: cannot run this model through the current connection.")
        #expect(p.headline == "Codex")
        #expect(p.detail == "cannot run this model through the current connection.")
    }

    @Test func emptyErrorGetsFallbackHeadline() {
        let p = ConversationErrorPresentationPolicy.presentation(for: "   \n  ")
        #expect(p.headline == "Something went wrong")
        #expect(p.detail == nil)
    }

    @Test func longHeadlineIsCondensed() {
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let p = ConversationErrorPresentationPolicy.presentation(for: long)
        #expect(p.headline.count <= ConversationErrorPresentationPolicy.maxHeadlineLength + 1)
        #expect(p.headline.hasSuffix("…") || p.headline.count <= ConversationErrorPresentationPolicy.maxHeadlineLength)
    }
}
