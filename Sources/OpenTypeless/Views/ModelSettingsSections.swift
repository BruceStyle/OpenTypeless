import SwiftUI
import OpenTypelessCore

struct ModelSettingsSections: View {
    @Bindable var model: AppController

    var body: some View {
        @Bindable var settings = model.settings
        Group {
            Section("模型") {
                SettingsItem(spacing: 12) {
                    modelChoice("语音识别主模型", selected: $settings.configuration.transcriptionModel,
                                recommended: speechRecommendations,
                                models: model.transcriptionModels)
                    modelChoice("超时备用模型", selected: $settings.configuration.transcriptionFallbackModel,
                                recommended: speechRecommendations, models: model.transcriptionModels,
                                allowsOff: true, excluding: settings.configuration.transcriptionModel)
                    Text("停止录音后等待 8 秒仍未获得完整结果时，才尝试备用模型。先成功的完整结果只回填一次，备用调用可能增加费用。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("30 秒以内保留整段上下文识别；更长录音提前分段处理。备用优先使用完整录音，超过 2 分钟时使用带前后文的片段。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingsItem {
                    modelChoice("文字整理", selected: $settings.configuration.rewriteModel,
                                recommended: ["google/gemini-3.1-flash-lite", "openai/gpt-4.1-mini", "qwen/qwen3-30b-a3b-instruct-2507"],
                                models: model.rewriteModels)
                }
                SettingsItem {
                    HStack {
                        Button(model.loadingModels ? "正在刷新…" : "刷新模型列表") { Task { await model.loadModels() } }.disabled(model.loadingModels)
                        Text(model.catalogMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.disabled(model.isBusy)
                .onChange(of: settings.configuration.transcriptionModel) { _, _ in clearDuplicateFallback() }
                .onChange(of: settings.configuration.transcriptionFallbackModel) { _, _ in clearDuplicateFallback() }
            RewriteTestSection(model: model)
        }
    }
    private let speechRecommendations = ["fish-audio/transcribe-1", "qwen/qwen3-asr-1.7b", "openai/gpt-4o-mini-transcribe", "openai/whisper-large-v3-turbo", "openai/whisper-large-v3"]

    private func clearDuplicateFallback() {
        if !model.settings.configuration.transcriptionFallbackModel.isEmpty,
           model.settings.configuration.effectiveTranscriptionFallbackModel == nil {
            model.settings.configuration.transcriptionFallbackModel = ""
        }
    }

    private func modelChoice(_ title: String, selected: Binding<String>, recommended: [String], models: [ModelDescriptor],
                             allowsOff: Bool = false, excluding: String? = nil) -> some View {
        let options = Array(Set(recommended + [selected.wrappedValue] + models.map(\.id)))
            .filter { !$0.isEmpty && $0 != excluding?.trimmingCharacters(in: .whitespacesAndNewlines) }.sorted()
        return Picker(title, selection: selected) {
            if allowsOff { Text("关闭").tag("") }
            ForEach(options, id: \.self) { id in
                Text(models.first(where: { $0.id == id })?.name ?? id).tag(id)
            }
        }
    }
}
