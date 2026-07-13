import AppKit
import SwiftUI
import LatticeCore

/// Display-only rendering of message text with fenced code blocks.
/// Stored `ChatMessage.text` remains the single source of truth for copy/edit/delete/branch/search/archive.
struct MessageContentView: View {
    let text: String
    var isUser = false

    private var segments: [MessageContentSegment] {
        MessageContentPresentationPolicy.segments(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let plain):
                    if !plain.isEmpty {
                        Text(plain)
                            .textSelection(.enabled)
                            .lineSpacing(isUser ? 3 : 4)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                maxWidth: isUser ? nil : .infinity,
                                alignment: .leading
                            )
                    }
                case .codeBlock(let language, let code):
                    FencedCodeBlockView(language: language, code: code)
                }
            }
        }
        .frame(
            maxWidth: isUser ? nil : .infinity,
            alignment: .leading
        )
    }
}

/// Selectable monospaced, horizontally scrollable fenced code with a labeled Copy action.
private struct FencedCodeBlockView: View {
    let language: String
    let code: String

    private var languageLabel: String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Code" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(languageLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider().opacity(0.35)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
        }
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Code block" : "Code block, \(languageLabel)")
    }
}
