import SwiftUI

/// Configuration validation belongs beside model selection, outside daily dictation.
struct RewriteTestSection: View {
    @Bindable var model: AppController
    @SceneStorage("settings.rewriteTestInput") private var input = "帮我做个登录页，嗯，用 React。先不用接后端。哦，框架改成 SwiftUI，其他要求不变。不要改公共组件，做完先让我预览。"
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup("测试文字整理", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("将示例发送给所选整理模型，检查改口与约束是否保留。会产生一次 API 调用费用，不会录音或回填到其他应用。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $input)
                        .font(.body).frame(minHeight: 90)
                        .accessibilityLabel("文字整理测试输入")
                    Button(model.isTesting ? "正在整理…" : "运行测试") {
                        Task { await model.testRewrite(input) }
                    }
                    .disabled(!model.settings.hasKey || model.isTesting || model.isBusy ||
                              input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !model.testResult.isEmpty {
                        Text(model.testResult).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        } header: {
            Text("连接验证")
        } footer: {
            Text("更换整理模型后，可用同一段文字比较效果。日常听写请前往“开始”。")
        }
    }
}
