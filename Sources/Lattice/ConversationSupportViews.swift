import SwiftUI
import AppKit
import LatticeCore
import UniformTypeIdentifiers

struct HarnessPermissionNoticeRow: View {
    let notice: HarnessPermissionNotice
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: LatticeStatusSemantic.approval.systemImage)
                .foregroundStyle(LatticeStatusSemantic.approval.color)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(notice.request.title).fontWeight(.semibold)
                    LatticeStatusChip(semantic: .approval, title: "Approval")
                }
                Text(notice.request.detail)
                    .font(LatticeTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("\(notice.providerName) is paused until you choose.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            let options = state.availableHarnessPermissionOptions(for: notice)
            let rejects = options.filter(\.isReject)
            let allows = options.filter(\.isAllow)
            if let reject = rejects.first {
                Button(reject.name) { state.respondToHarnessPermission(notice, option: reject) }
                    .buttonStyle(LatticeSecondaryButtonStyle())
            } else {
                Button("Stop", action: state.stop)
                    .buttonStyle(LatticeSecondaryButtonStyle())
            }
            if allows.count == 1, let allow = allows.first {
                Button(allow.name) { state.respondToHarnessPermission(notice, option: allow) }
                    .buttonStyle(LatticePrimaryButtonStyle())
            } else if !allows.isEmpty {
                Menu("Allow") {
                    ForEach(allows) { option in
                        Button(option.name) { state.respondToHarnessPermission(notice, option: option) }
                    }
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(LatticePrimaryButtonStyle())
            }
        }
        .padding(12)
        .latticeContentSurface(cornerRadius: LatticeMetrics.controlRadius)
        .overlay(
            RoundedRectangle(cornerRadius: LatticeMetrics.controlRadius, style: .continuous)
                .strokeBorder(LatticeStatusSemantic.approval.color.opacity(0.28), lineWidth: 1)
        )
        .accessibilityIdentifier(LatticeAccessibilityID.approvalStrip)
        .accessibilityLabel("\(notice.request.title), pending approval")
        .accessibilityValue(notice.request.detail)
    }
}

struct ErrorRow: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void

    private var presentation: ConversationErrorPresentation {
        ConversationErrorPresentationPolicy.presentation(for: message)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: LatticeStatusSemantic.failed.systemImage)
                .foregroundStyle(LatticeStatusSemantic.failed.color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.headline)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(LatticeStatusSemantic.failed.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(LatticeTypography.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if canRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(LatticePrimaryButtonStyle())
                    .accessibilityLabel("Retry request")
            }
        }
        .padding(12)
        .latticeContentSurface(cornerRadius: LatticeMetrics.controlRadius)
        .overlay(
            RoundedRectangle(cornerRadius: LatticeMetrics.controlRadius, style: .continuous)
                .strokeBorder(LatticeStatusSemantic.failed.color.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
