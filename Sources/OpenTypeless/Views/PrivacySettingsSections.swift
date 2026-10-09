import AppKit
import AVFoundation
import SwiftUI
import OpenTypelessCore

struct PrivacySettingsSections: View {
    @Bindable var model: AppController

    var body: some View {
        @Bindable var settings = model.settings
        Group {
            Section("系统权限") {
                HStack {
                    Label("麦克风", systemImage: "mic")
                    Spacer()
                    Text(model.microphoneReady ? "已允许" : "尚未允许").foregroundStyle(model.microphoneReady ? Color.accentColor : .secondary)
                    Button(model.microphoneReady ? "系统设置" : "允许麦克风") { requestMicrophone() }
                }
                SettingsItem {
                    HStack {
                        Label("辅助功能", systemImage: "cursorarrow.and.square.on.square.dashed")
                        Spacer()
                        Text(model.accessibilityReady ? "已允许" : "尚未允许").foregroundStyle(model.accessibilityReady ? Color.accentColor : .secondary)
                        Button("打开权限设置") {
                            TextInsertionService.requestPermission()
                            model.watchPermissionChanges()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    Text("辅助功能用于 Fn 快捷键、确认光标位置并粘贴结果。开启词语学习后，会短时比对原输入框内本次回填文字的修改。允许后回到应用，状态会自动更新。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("重新检查权限") { model.refreshPermissions(); model.watchPermissionChanges() }
                        if !model.accessibilityReady {
                            Button("在 Finder 中显示应用") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        }
                    }
                    if !model.accessibilityReady {
                        Text("如果系统开关已打开但这里仍未允许，请将 OpenTypeless 的开关关闭后重新打开。仍无效时，从系统列表移除旧条目，再添加当前应用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("本地数据") {
                SettingsItem {
                    SettingsToggle("保存文字历史", isOn: $settings.configuration.saveHistory)
                    Picker("保留期限", selection: $settings.configuration.historyDays) {
                        Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90)
                    }.onChange(of: model.settings.configuration.historyDays) { _, days in model.history.prune(days: days) }
                    Text("文字历史仅保存在这台 Mac 上。关闭后停止新增，已有记录仍按所选期限保留。完成听写后清理临时录音，未完成的录音保留 24 小时以便恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingsItem {
                    SettingsToggle("临时保留原音以便核对", isOn: Binding(
                        get: { settings.configuration.keepsDiagnosticAudio },
                        set: { settings.configuration.diagnosticAudioUntil = $0 ? Date().addingTimeInterval(86_400) : nil }
                    )).disabled(!settings.configuration.saveHistory || model.isBusy)
                    Text("默认关闭。开启后 24 小时内的新听写会在本机保留完整原音与识别片段，可从历史记录打开。最多 10 条，每条保留 24 小时，过期后在下次使用时清理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("在 Finder 中打开数据目录") {
                    try? LocalFiles.prepare(LocalFiles.root)
                    NSWorkspace.shared.open(LocalFiles.root)
                }
            }
        }
    }
    private func requestMicrophone() {
        if AudioRecorder.permission == .notDetermined {
            Task { _ = await AudioRecorder.requestPermission(); model.refreshPermissions() }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
}
