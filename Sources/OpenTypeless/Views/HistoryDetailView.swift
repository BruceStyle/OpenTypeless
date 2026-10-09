import AppKit
import SwiftUI
import OpenTypelessCore

struct HistoryDetailView: View {
    let entry: HistoryEntry
    @Binding var showOriginal: Bool
    var audioFolder: URL?
    let copy: (String) -> Void
    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                        .font(.title3.weight(.semibold))
                    Text("\(entry.mode.title) · 录音 \(Int(entry.seconds)) 秒")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("显示文字", selection: $showOriginal) {
                        Text("最终文字").tag(false)
                        Text("识别原稿").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    Spacer(minLength: 8)
                    Button { copy(visibleText) } label: { Label("复制", systemImage: "doc.on.doc") }
                        .help(showOriginal ? "复制当前识别原稿" : "复制当前最终文字")
                        .disabled(visibleText.isEmpty)
                }

                Text(visibleText)
                    .textSelection(.enabled).lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
                DisclosureGroup("录音与处理信息", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        metadataRow("调用费用", value: entry.cost.map { String(format: "$%.5f", $0) } ?? "费用未返回")
                        metadataRow("交付状态", value: entry.delivery)
                        metadataRow("语音识别", value: entry.transcriptionModel, valueFont: .caption.monospaced())
                        if let count = entry.recognition?.modelFallbackRequests, count > 0 {
                            metadataRow("超时备用", value: "调用 \(count) 次 · 上方显示最终采用的识别模型")
                        }
                        if let rewriteModel = entry.rewriteModel {
                            metadataRow("文字整理", value: rewriteModel, valueFont: .caption.monospaced())
                        }
                        if let timing = entry.timings {
                            metadataRow("停止后等待", value: String(format: "%.1f 秒", timing.total))
                            if let ready = timing.textReady {
                                metadataRow("文字就绪", value: String(format: "停止后 %.1f 秒", ready))
                            }
                            if let posted = timing.pastePosted {
                                metadataRow("发出回填", value: String(format: "停止后 %.1f 秒", posted))
                            }
                            Text(String(format: "识别 %.1f 秒 · 整理 %.1f 秒 · 回填 %.1f 秒",
                                        timing.recognition, timing.rewriting, timing.insertion))
                                .foregroundStyle(.secondary)
                        }
                        if let audioFolder {
                            Button("查看本地原音分段") { NSWorkspace.shared.open(audioFolder) }
                            Text("提交给识别模型的原音可能含分段重叠。每条最多保留 24 小时，过期后在下次使用时清理。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var visibleText: String { showOriginal ? entry.rawText : entry.text }

    private func metadataRow(_ title: String, value: String, valueFont: Font = .caption) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).font(valueFont).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
                .help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
