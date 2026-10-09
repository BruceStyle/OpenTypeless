#if DEBUG
import SwiftUI
import OpenTypelessCore

/// Uses the shipping content and surface with inert values. It never creates
/// an AppController, captures audio, changes preferences, or sends requests.
struct OverlayVisualVerification: View {
    @State private var backdrop = Backdrop.light
    @State private var showGuides = false

    private enum Backdrop: String, CaseIterable {
        case light = "白色页面", dark = "深色页面", colorful = "彩色图案"
    }

    private enum Sample: String, CaseIterable {
        case connecting = "连接麦克风", recording = "录音", processing = "处理中"
        case delivering = "即将完成", takingLonger = "等待较久", completed = "已完成"
        case ready = "结果", readyWithoutCopy = "结果（无复制）", failed = "可恢复错误"
        case noSpeech = "未检测到语音", microphoneFailed = "麦克风不可用", unrecoverable = "听写未完成"

        var resultTitle: String {
            switch self {
            case .ready, .readyWithoutCopy: return "已就绪"
            case .failed: return "未完成，可重试"
            default: return rawValue
            }
        }

        var leadingInset: CGFloat {
            switch self {
            case .processing, .delivering, .takingLonger, .completed:
                return DictationLayout.progressLeadingInset
            default:
                return DictationLayout.visibleInset
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("背景", selection: $backdrop) {
                    ForEach(Backdrop.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 300)
                Spacer()
                Toggle("显示内容边界", isOn: $showGuides).toggleStyle(.checkbox)
                    .help("文字与进度距左端 20 pt；圆形控件距胶囊边缘 12 pt。")
            }
            HStack(spacing: 12) {
                Text("状态").frame(width: 90, alignment: .leading)
                ForEach(OverlayAppearance.allCases) { appearance in
                    Text(appearance.title).frame(width: 240)
                }
            }.font(.headline)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Sample.allCases, id: \.self) { sample in
                        HStack(spacing: 12) {
                            Text(sample.rawValue).frame(width: 90, alignment: .leading)
                            ForEach(OverlayAppearance.allCases) { appearance in
                                cell(sample, appearance: appearance)
                            }
                        }
                    }
                }
            }
            Text("静态视觉检查 · 复用实际浮窗内容和材质 · 不录音、不请求模型、不更改外观偏好")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .environment(\.appearsActive, true)
    }

    private func cell(_ sample: Sample, appearance: OverlayAppearance) -> some View {
        let size = DictationLayout.contentSize
        return sampleContent(sample)
            .frame(width: size.width, height: size.height)
            .dictationSurface(appearance: appearance, preview: true)
            .overlay {
                if showGuides {
                    Path { path in
                        for x in [sample.leadingInset, size.width - DictationLayout.visibleInset] {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                    }
                    .stroke(.pink, style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .accessibilityHidden(true)
                }
            }
            .frame(width: 240, height: 72)
            .background {
                switch backdrop {
                case .light: Color(white: 0.97)
                case .dark: Color(white: 0.12)
                case .colorful:
                    LinearGradient(colors: [.cyan, .blue, .pink, .orange],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(appearance.title)，\(sample.rawValue)")
    }

    @ViewBuilder private func sampleContent(_ sample: Sample) -> some View {
        switch sample {
        case .connecting, .recording:
            DictationRecordingContent(microphoneConnecting: sample == .connecting,
                                      level: 0.5, seconds: 12, shortcutLabel: "Fn", cancel: {}, stop: {})
        case .processing, .delivering, .takingLonger, .completed:
            DictationProcessingContent(progress: progress(for: sample), canCancel: sample != .delivering)
        case .ready, .readyWithoutCopy, .failed, .noSpeech, .microphoneFailed, .unrecoverable:
            DictationResultContent(failed: sample != .ready && sample != .readyWithoutCopy,
                                   title: sample.resultTitle,
                                   message: "视觉检查", canCopy: sample == .ready,
                                   open: {}, copy: {}, dismiss: {})
        }
    }

    private func progress(for sample: Sample) -> DictationProgress {
        var progress = DictationProgress()
        progress.begin(at: 0, audioSeconds: 10, totalChunks: 1, completedChunks: 0, includesRewrite: true)
        progress.tick(at: 5)
        if sample == .delivering { progress.advance(to: .delivery, at: 5) }
        if sample == .takingLonger {
            progress.advance(to: .delivery, at: 5)
            progress.tick(at: 40)
        }
        if sample == .completed { progress.complete() }
        return progress
    }
}
#endif
