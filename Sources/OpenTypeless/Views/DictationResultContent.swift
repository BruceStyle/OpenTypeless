import SwiftUI

struct DictationResultContent: View {
    let failed: Bool
    let title: String
    let message: String
    let canCopy: Bool
    let open: () -> Void
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DictationLayout.inlineSpacing) {
            Button(action: open) {
                HStack(spacing: DictationLayout.inlineSpacing) {
                    Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(failed ? Color.orange : .green)
                        .frame(width: DictationLayout.statusIconSize, height: DictationLayout.statusIconSize)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .padding(.leading, DictationLayout.buttonHitOutset)
                .frame(maxWidth: .infinity, minHeight: DictationLayout.buttonTargetSize, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(message)
            .accessibilityLabel(title)
            .layoutPriority(1)
            HStack(spacing: DictationLayout.inlineSpacing) {
                if canCopy {
                    DictationIconButton(title: "复制结果", symbol: "doc.on.doc", action: copy)
                }
                DictationIconButton(title: "收起提示", symbol: "xmark", action: dismiss)
            }
        }
        .padding(.horizontal, DictationLayout.horizontalInset)
    }
}
