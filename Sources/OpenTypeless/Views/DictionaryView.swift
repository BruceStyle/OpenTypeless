import SwiftUI
import OpenTypelessCore

struct DictionaryView: View {
    let model: AppController
    @Bindable var settings: SettingsStore
    @Bindable var learned: LearnedDictionaryStore
    @State private var editing: LearnedWord?
    @State private var editedTerm = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    SettingsItem {
                        SettingsToggle("自动学习词语", isOn: Binding(
                            get: { settings.configuration.learnFromCorrections },
                            set: { model.setDictionaryLearning($0) }
                        ))
                            .help("关闭后停止学习，已保存的词条仍可使用。")
                        Text("改正回填中的词语，停稳 3 秒后自动记住。")
                            .font(.caption).foregroundStyle(.secondary)
                        if settings.configuration.learnFromCorrections, !model.dictionaryLearningMessage.isEmpty {
                            Text(model.dictionaryLearningMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(5)
                }
                HStack {
                    Text("词条").font(.headline)
                    Spacer()
                    Text("\(learned.active.count) 个词条").font(.caption).foregroundStyle(.secondary)
                }
                if learned.active.isEmpty {
                    ContentUnavailableView("还没有记住词语", systemImage: "character.book.closed",
                        description: Text("改正回填中的词语后，会自动出现在这里。"))
                        .frame(minHeight: 170)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(learned.active) { word in
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(word.term).font(.body.weight(.medium)).textSelection(.enabled)
                                    Text(word.variants.isEmpty ? "已有词条" : "原写法：\(word.variants.joined(separator: "、"))")
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button("编辑") { editedTerm = word.term; editing = word }
                                    .accessibilityLabel("编辑 \(word.term)")
                                Button("移除") { model.removeLearnedWord(word.id) }
                                    .accessibilityLabel("移除 \(word.term)")
                            }.padding(14)
                            Divider()
                        }
                    }.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                if let error = settings.storageError { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                if let error = learned.storageError { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }.padding(28).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }
        .navigationTitle("个人词典")
        .sheet(item: $editing) { word in
            VStack(alignment: .leading, spacing: 18) {
                Text("编辑正确写法").font(.headline)
                if !word.variants.isEmpty {
                    Text("原写法：\(word.variants.joined(separator: "、"))").foregroundStyle(.secondary)
                }
                TextField("正确词语", text: $editedTerm).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("正确词语")
                Text("请输入 2–100 字的词语。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { editing = nil }.keyboardShortcut(.cancelAction)
                    Button("保存") { if learned.edit(word.id, term: editedTerm) { editing = nil } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!CorrectionClassifier.validTerm(editedTerm.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                if let error = learned.storageError { Text(error).foregroundStyle(.orange) }
            }.padding(24).frame(width: 400)
        }
    }
}
