import SwiftUI
import OpenTypelessCore

struct DictationProcessingContent: View {
    let progress: DictationProgress
    var canCancel = true
    var cancel: () -> Void = {}

    var body: some View {
        HStack(spacing: DictationLayout.spacing) {
            DictationProgressView(progress: progress, compact: true)
                .padding(.leading, DictationLayout.progressLeadingPadding)
            if progress.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .resizable().scaledToFit()
                    .foregroundStyle(.green)
                    .frame(width: DictationLayout.buttonSize, height: DictationLayout.buttonSize)
                    .frame(width: DictationLayout.buttonTargetSize, height: DictationLayout.buttonTargetSize)
                    .accessibilityHidden(true)
            } else {
                DictationIconButton(title: "取消处理", symbol: "xmark", action: cancel)
                    .disabled(!canCancel)
                    .help(canCancel ? "取消处理 · Esc" : "即将完成")
            }
        }
        .padding(.horizontal, DictationLayout.horizontalInset)
    }
}
