import SwiftUI
import OpenTypelessCore

struct GeneralSettingsSections: View {
    @Bindable var model: AppController

    var body: some View {
        @Bindable var settings = model.settings
        Group {
            Section("听写") {
                SettingsItem {
                    Picker("开始 / 停止快捷键", selection: $settings.configuration.shortcut) {
                        ForEach(HotkeyService.shortcuts, id: \.self) { Text(HotkeyService.label($0)).tag($0) }
                    }.onChange(of: model.settings.configuration.shortcut) { _, _ in model.registerShortcut() }
                    if !model.shortcutReady {
                        Text(model.settings.configuration.shortcut == "fn"
                             ? (model.accessibilityReady
                                ? "辅助功能已允许，但 Fn 监听尚未启动。请重新检查权限或重启应用。"
                                : "Fn 尚未就绪，请允许辅助功能后点击“重新检查权限”。")
                             : "快捷键注册失败，请换一个组合。")
                            .font(.caption).foregroundStyle(.orange)
                    } else if model.settings.configuration.shortcut == "fn" {
                        Label("Fn 已就绪", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Color.accentColor)
                    }
                    Text("按一次开始，再按一次结束。录音和处理时按 Esc 取消。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.settings.configuration.shortcut == "fn" {
                        DisclosureGroup("Fn 使用帮助") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("轻按并松开 Fn 开始，看到录音状态后再说话；说完再轻按并松开 Fn 结束。Fn 组合键不会触发录音。试用时请先退出 Typeless，避免同时响应。")
                                Text("如果 Fn 同时弹出表情面板，请在系统设置 → 键盘，将“按下 🌐 键时”（或“按下 Fn 键时”）改为“不执行任何操作”。这会关闭系统的 Fn 单键动作，仍可从“编辑 → 表情与符号”打开表情面板。")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }.font(.callout)
                    }
                }
            }.disabled(model.isBusy)

            Section("文字与回填") {
                SettingsItem {
                    Picker("默认文字处理", selection: $settings.configuration.mode) {
                        ForEach(WritingMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(model.settings.configuration.mode.detail).font(.caption).foregroundStyle(.secondary)
                }
                SettingsItem {
                    SettingsToggle("处理完成后回填原输入框", isOn: $settings.configuration.autoPaste)
                    Text("录音前请将光标放在目标输入框。完成后回填同一输入框；切换输入框或改动原文时会保留结果供复制。不会自动发送消息。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.isBusy)

            Section("麦克风") {
                SettingsItem {
                    Picker("输入设备", selection: Binding(
                        get: { settings.configuration.microphoneUID ?? "" },
                        set: { settings.configuration.microphoneUID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("跟随系统默认").tag("")
                        ForEach(model.inputDevices.devices) { device in Text(device.name).tag(device.id) }
                        if let selected = settings.configuration.microphoneUID,
                           !model.inputDevices.devices.contains(where: { $0.id == selected }) {
                            Text("已选设备（未连接）").tag(selected)
                        }
                    }
                    HStack {
                        Text(settings.configuration.microphoneUID == nil
                             ? "当前使用：\(model.inputDevices.defaultName)"
                             : "录音将使用所选麦克风，重新启动后仍会记住选择。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("刷新设备") { model.inputDevices.refresh() }.controlSize(.small)
                    }
                    if let selected = settings.configuration.microphoneUID,
                       !model.inputDevices.devices.contains(where: { $0.id == selected }) {
                        Text("所选麦克风已断开，请重新连接或选择其他设备。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("MacBook、蓝牙耳机和 iPhone 麦克风会在系统识别为可用输入设备后显示。这里只改变 OpenTypeless 的录音设备。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.isBusy)
        }
    }
}
