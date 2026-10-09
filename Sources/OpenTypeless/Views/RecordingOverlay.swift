import AppKit
import SwiftUI

struct RecordingOverlay: View {
    @Bindable var model: AppController
    var updateAppearance: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let size = DictationLayout.contentSize
        Group {
            if model.phase == .recording { recording }
            else if model.isProcessing || model.showingCompletion { processing }
            else { result }
        }
        .frame(width: size.width, height: size.height)
        .dictationSurface(appearance: model.settings.configuration.overlayAppearance)
        // Let the system material draw its edge and shadow inside the window.
        .padding(DictationLayout.materialInset)
        .environment(\.appearsActive, true)
        .onChange(of: model.settings.configuration.overlayAppearance) { _, _ in updateAppearance() }
        .onChange(of: reduceTransparency) { _, _ in updateAppearance() }
    }

    private var recording: some View {
        DictationRecordingContent(microphoneConnecting: model.microphoneConnecting,
                                  level: model.level, seconds: model.seconds,
                                  shortcutLabel: model.shortcutLabel,
                                  cancel: { model.cancel() }, stop: { model.stop() })
    }

    private var processing: some View {
        DictationProcessingContent(progress: model.processingProgress, canCancel: model.phase != .inserting) {
            model.cancel()
        }
    }

    private var result: some View {
        DictationResultContent(failed: model.phase == .failed,
                               title: model.phase == .failed ? failureTitle : model.phase == .noSpeech ? "未检测到语音" : "已就绪",
                               message: model.message,
                               canCopy: !model.resultText.isEmpty || !model.rawText.isEmpty,
                               open: { model.goTo(.home); model.dismissOverlay() },
                               copy: { model.copy(model.resultText.isEmpty ? model.rawText : model.resultText); model.dismissOverlay() },
                               dismiss: { model.dismissOverlay() })
    }

    private var failureTitle: String {
        if model.message.contains("没有检测到") { return "未检测到语音" }
        if model.message.contains("麦克风") { return "麦克风不可用" }
        return model.canRecover ? "未完成，可重试" : "听写未完成"
    }

}
