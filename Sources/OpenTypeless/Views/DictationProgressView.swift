import SwiftUI
import OpenTypelessCore

/// Shared by the floating HUD and the main window so the visible task stays one
/// continuous operation, even when the underlying network request changes.
struct DictationProgressView: View {
    let progress: DictationProgress
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.isComplete ? "已完成" : progress.isTakingLonger ? "仍在处理" : compact ? "处理中" : "正在处理")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: compact ? 6 : 8)
                Text(progress.isComplete ? "100%" : compact ? "约\(progress.percentage)%" : "约 \(progress.percentage)%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.72))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .lineLimit(1)
            ProgressView(value: progress.fractionCompleted, total: 1)
                .progressViewStyle(DictationLinearProgressStyle(tint: progress.isComplete ? .green : .accentColor))
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress.fractionCompleted)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.isComplete ? "处理完成" : "正在处理听写")
        .accessibilityValue(progress.isComplete ? "100%" : "预计进度 \(progress.percentage)%")
        .help(progress.isComplete ? "文字处理完成" : "进度根据已完成的工作与等待时间估算，实际完成后到达 100%。")
    }
}

private struct DictationLinearProgressStyle: ProgressViewStyle {
    let tint: Color
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        // AppKit's default bar becomes gray in a non-key NSPanel. Draw the fill
        // with the semantic accent while retaining ProgressView's value model.
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.22 : 0.1))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: 4)
    }
}
