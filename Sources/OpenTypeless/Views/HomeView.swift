import SwiftUI
import OpenTypelessCore

struct HomeView: View {
    @Bindable var model: AppController
    @State private var showOriginal = false
    @SceneStorage("home.showRecoveries") private var showRecoveries = false
    @State private var discardConfirmation = false
    @State private var recoveryToDiscard: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !model.settings.hasKey || !model.microphoneReady || !model.accessibilityReady {
                    setupSection
                }
                dictationSection
                if !model.message.isEmpty || model.isBusy || model.showingCompletion {
                    progressSection
                }
                resultSection
                if !model.recoveries.pending.isEmpty {
                    recoverySection
                }
            }
            .padding(28)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("开始")
        .onChange(of: model.phase, initial: true) { _, phase in
            if phase == .failed { showRecoveries = true }
        }
        .confirmationDialog("丢弃这段尚未完成的听写？", isPresented: $discardConfirmation) {
            Button("丢弃", role: .destructive) {
                if let id = recoveryToDiscard { model.discardRecovery(id) }
                recoveryToDiscard = nil
            }
        } message: {
            Text("这段录音将从本机删除，无法恢复。")
        }
    }

    private var dictationSection: some View {
        @Bindable var settings = model.settings
        return GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("把想法说出来").font(.title2.weight(.semibold))
                            Text("按 \(model.shortcutLabel) 开始，说完再按一次结束。")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { model.toggle() } label: {
                            Label(model.phase == .recording ? "结束听写" : "开始听写",
                                  systemImage: model.phase == .recording ? "stop.fill" : "mic.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled((model.isBusy && model.phase != .recording) || model.isTesting)
                    }
                    Text("在这里录音可预览结果。回填到其他应用时，请先将光标放在目标输入框，再使用快捷键。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("文字处理").font(.subheadline.weight(.medium))
                    Picker("文字处理", selection: $settings.configuration.mode) {
                        ForEach(WritingMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.isBusy)
                    Text(settings.configuration.mode.detail)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(16)
        }
    }

    private var progressSection: some View {
        GroupBox {
            HStack(spacing: 16) {
                if model.isProcessing || model.showingCompletion {
                    DictationProgressView(progress: model.processingProgress)
                } else {
                    Image(systemName: model.phase == .recording ? "waveform" : model.phase == .failed ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(model.phase == .failed ? Color.orange : .accentColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.isBusy ? model.phaseTitle : model.message)
                        if model.phase == .recording {
                            Text("\(Int(model.seconds)) 秒 · Esc 取消 · 单次最多 10 分钟")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if model.isBusy { Button("取消") { model.cancel() }.disabled(model.phase == .inserting) }
            }.padding(12)
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.resultMayBeIncomplete && hasResult ? "部分原稿" : "本次结果").font(.headline)
                Spacer()
                if hasResult {
                    Picker("显示文字", selection: $showOriginal) {
                        Text("最终文字").tag(false)
                        Text("识别原稿").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    Button { model.copy(visibleText) } label: { Label("复制", systemImage: "doc.on.doc") }
                        .disabled(visibleText.isEmpty)
                }
            }
            if model.resultMayBeIncomplete && hasResult {
                Text(model.isBusy ? "以下为目前已识别的文字，可能不完整。" : "以下文字可能不完整，请核对录音或恢复后再使用。")
                    .font(.caption).foregroundStyle(.orange)
            }
            GroupBox {
                if hasResult {
                    Text(visibleText.isEmpty ? "暂无识别原稿" : visibleText)
                        .textSelection(.enabled).lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "text.alignleft").font(.title2).foregroundStyle(.tertiary)
                        Text(model.isBusy ? "完成后，文字会显示在这里" : "听写完成后，在这里查看和复制文字")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 28)
                }
            }
        }
    }

    private var recoverySection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showRecoveries) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("未完成的录音保留 24 小时。恢复时会重新调用模型；丢弃后无法恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recoveries.pending) { draft in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.created, format: .dateTime.month().day().hour().minute())
                                Text("\(draft.seconds.formatted(.number.precision(.fractionLength(1)))) 秒")
                                    .font(.caption).foregroundStyle(.secondary)
                                if draft.failureStage == "rewriting" {
                                    Text("文字整理未完成，识别原稿已保留。")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if let failure = draft.lastFailure {
                                    Text(failure.localizedDescription).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if !draft.rawText.isEmpty {
                                Button(draft.completeTranscript ? "复制原稿" : "复制部分原稿") { model.copy(draft.rawText) }
                            }
                            Button("恢复并重试") { model.retry(draft.id) }
                            Button("丢弃", role: .destructive) {
                                recoveryToDiscard = draft.id; discardConfirmation = true
                            }
                        }.disabled(model.isBusy || model.isTesting)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            } label: {
                HStack(spacing: 10) {
                    Label("未完成的听写", systemImage: "clock.arrow.circlepath").font(.headline)
                    Text("\(model.recoveries.pending.count) 条").foregroundStyle(.secondary)
                    Spacer()
                    Text("可稍后恢复").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12)
        }
    }

    private var setupSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("完成设置即可开始").font(.headline)
                HStack(spacing: 12) {
                    setupAction("连接模型账户", ready: model.settings.hasKey, pane: .models)
                    setupAction("麦克风权限", ready: model.microphoneReady, pane: .privacy)
                    setupAction("Fn 与回填权限", ready: model.accessibilityReady, pane: .privacy)
                }
                Text("录音与文字由所选云端模型处理，密钥保存在本机钥匙串。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }

    private func setupAction(_ title: String, ready: Bool, pane: SettingsPane) -> some View {
        Button {
            model.settingsPane = pane
            model.goTo(.settings)
        } label: {
            Label(title, systemImage: ready ? "checkmark.circle" : "circle")
        }
        .foregroundStyle(ready ? Color.secondary : .accentColor)
    }

    private var hasResult: Bool { !model.resultText.isEmpty || !model.rawText.isEmpty }
    private var visibleText: String { showOriginal ? model.rawText : model.resultText.isEmpty ? model.rawText : model.resultText }
}
