import Foundation

/// Streaming filter that keeps inline image data URIs out of durable transcript prose.
/// Typed local artifact events are the only authority for image presentation.
public enum AssistantTranscriptMediaPolicy {
    public static let omissionMarker = "[Inline image data omitted]"

    public struct Result: Equatable, Sendable {
        public let text: String
        public let isSuppressingPayload: Bool

        public init(text: String, isSuppressingPayload: Bool) {
            self.text = text
            self.isSuppressingPayload = isSuppressingPayload
        }
    }

    public static func appending(
        _ delta: String,
        to existingText: String,
        isSuppressingPayload: Bool
    ) -> Result {
        if isSuppressingPayload {
            let suffix = suffixAfterBase64Payload(in: delta)
            return Result(
                text: existingText + suffix.text,
                isSuppressingPayload: suffix.isStillSuppressing
            )
        }

        let combined = existingText + delta
        guard let markerRange = combined.range(
            of: #"data:image/[a-z0-9.+-]+;base64,"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return Result(text: combined, isSuppressingPayload: false)
        }

        let prefix = String(combined[..<markerRange.lowerBound]) + omissionMarker
        let payloadAndSuffix = String(combined[markerRange.upperBound...])
        let suffix = suffixAfterBase64Payload(in: payloadAndSuffix)
        return Result(
            text: prefix + suffix.text,
            isSuppressingPayload: suffix.isStillSuppressing
        )
    }

    private static func suffixAfterBase64Payload(in value: String) -> (text: String, isStillSuppressing: Bool) {
        guard let boundary = value.firstIndex(where: { !isBase64PayloadCharacter($0) }) else {
            return ("", true)
        }
        return (String(value[boundary...]), false)
    }

    private static func isBase64PayloadCharacter(_ character: Character) -> Bool {
        // Accept both standard and URL-safe alphabets while the stream is in the
        // payload state; otherwise a URL-safe blob could leak after the first `-`/`_`.
        character.isASCII && (character.isLetter || character.isNumber || character == "+" || character == "/" || character == "=" || character == "-" || character == "_")
    }
}
