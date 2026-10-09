import SwiftUI

struct DictationRecordingContent: View {
    let microphoneConnecting: Bool
    let level: Float
    let seconds: Double
    let shortcutLabel: String
    let cancel: () -> Void
    let stop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DictationLayout.spacing) {
            DictationIconButton(title: "取消录音", symbol: "xmark", action: cancel)
            Group {
                if microphoneConnecting {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在连接麦克风")
                } else {
                    TimelineView(.animation(minimumInterval: 0.09, paused: reduceMotion || level < 0.01)) { timeline in
                        HStack(spacing: 2) {
                            ForEach(0..<11) { index in
                                let energy = min(1, sqrt(Double(max(0, level))))
                                let movement = reduceMotion ? 0.7 : 0.55 + 0.45 * abs(sin(timeline.date.timeIntervalSinceReferenceDate * 7 + Double(index) * 0.8))
                                Capsule().fill(.primary)
                                    .frame(width: 3, height: 3 + energy * movement * Double(10 + (index * 7 % 14)))
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("正在录音")
                    .accessibilityValue("\(Int(seconds)) 秒，麦克风音量 \(Int(level * 100))%")
                }
            }
            .frame(width: DictationLayout.waveformWidth, height: DictationLayout.buttonSize)
            .help(microphoneConnecting ? "正在连接麦克风…" : "正在聆听 · \(Int(seconds)) 秒 · \(shortcutLabel) 完成 · Esc 取消")
            DictationIconButton(title: "完成录音", symbol: "checkmark", prominent: true, action: stop)
                .disabled(microphoneConnecting)
        }
        .padding(.horizontal, DictationLayout.horizontalInset)
    }
}
