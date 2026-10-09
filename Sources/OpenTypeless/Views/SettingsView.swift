import AppKit
import AVFoundation
import SwiftUI
import OpenTypelessCore

struct SettingsView: View {
    @Bindable var model: AppController
    @State private var keyInput = ""
    @State private var keyMessage = ""
    @State private var keyFailed = false
    @State private var changingKey = false
    @State private var verifying = false
    @State private var showRemoveKey = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分类", selection: $model.settingsPane) {
                ForEach(SettingsPane.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Form {
                switch model.settingsPane {
                case .general:
                    GeneralSettingsSections(model: model)
                case .appearance:
                    OverlayAppearanceSettings(settings: model.settings)
                case .models:
                    connectionSection
                    ModelSettingsSections(model: model)
                case .privacy:
                    PrivacySettingsSections(model: model)
                }
                if let error = model.settings.storageError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .id(model.settingsPane)
        }
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
        .navigationTitle("设置")
        .onAppear { model.inputDevices.refresh() }
        .confirmationDialog("从本机钥匙串移除 API Key？", isPresented: $showRemoveKey) {
            Button("移除", role: .destructive) {
                do {
                    try model.settings.removeKey(); changingKey = false; keyInput = ""
                    keyFailed = false; keyMessage = "密钥已移除。"
                } catch { keyFailed = true; keyMessage = error.localizedDescription }
            }
        }
    }

    private var connectionSection: some View {
        Section("模型账户") {
            SettingsItem(spacing: 12) { connectionContent }
        }
    }

    @ViewBuilder private var connectionContent: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("OpenRouter").font(.headline)
                Text(model.settings.hasKey ? "密钥已保存在本机钥匙串" : "连接你自己的模型账户")
                    .foregroundStyle(.secondary).font(.caption)
            }
            Spacer()
            Link("获取 API Key ↗", destination: URL(string: "https://openrouter.ai/settings/keys")!)
        }
        if !model.settings.hasKey || changingKey {
            LabeledContent("API Key") {
                SecureField("粘贴 OpenRouter API Key", text: $keyInput)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .accessibilityLabel("OpenRouter API Key")
                    .disabled(verifying || model.isBusy)
            }
            if changingKey {
                Text("新密钥连接成功后才会替换已保存的密钥。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(verifying ? "正在连接…" : "保存并连接") { Task { await saveAndConnect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy || verifying)
                if changingKey {
                    Button("取消更换") { changingKey = false; keyInput = ""; keyMessage = "" }
                        .disabled(verifying)
                }
            }
        } else {
            LabeledContent("API Key") {
                HStack(spacing: 10) {
                    Text("••••••••••••").font(.body.monospaced()).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Label("已保存", systemImage: "checkmark.shield.fill").foregroundStyle(Color.accentColor)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("密钥已保存，内容已隐藏")
            }
            HStack {
                Button(verifying ? "正在检查…" : "检查连接") { Task { await verify() } }
                Button("更换密钥") { changingKey = true; keyInput = ""; keyMessage = "" }
                Spacer()
                Button("移除密钥", role: .destructive) { showRemoveKey = true }
            }.disabled(model.isBusy || verifying)
        }
        if !keyMessage.isEmpty {
            Label(keyMessage, systemImage: keyFailed ? "exclamationmark.circle" : "checkmark.circle.fill")
                .font(.caption).foregroundStyle(keyFailed ? Color.orange : .accentColor).textSelection(.enabled)
        }
        Text("录音发送给 OpenRouter 的识别模型；原稿与词典发送给整理模型。检查连接只验证密钥，不发送录音。")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func saveAndConnect() async {
        guard !verifying else { return }
        verifying = true; keyFailed = false; keyMessage = ""
        defer { verifying = false }
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await model.client.verifyKey(key)
            try model.settings.saveKey(key)
            keyInput = ""; changingKey = false
            keyMessage = "连接成功，密钥已保存。之后无需重复填写。"
        } catch {
            keyFailed = true
            keyMessage = "\(error.localizedDescription) 输入内容已保留，请修改后重试。"
        }
    }
    private func verify() async {
        guard !verifying else { return }
        verifying = true; keyFailed = false; keyMessage = ""
        defer { verifying = false }
        do {
            guard let key = try KeychainStore.read(), !key.isEmpty else {
                model.settings.refreshKeyStatus()
                throw AppError.message("未找到已保存的密钥，请重新填写。")
            }
            try await model.client.verifyKey(key)
            keyMessage = "连接成功。可以在下方测试文字整理，或回到“开始”录音。"
        } catch { keyFailed = true; keyMessage = error.localizedDescription }
    }
}
