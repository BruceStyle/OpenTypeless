import AppKit
import SwiftUI
import OpenTypelessCore

struct HistoryView: View {
    @Bindable var model: AppController
    @SceneStorage("history.search") private var search = ""
    @SceneStorage("history.selectedID") private var selectedID = ""
    @State private var showOriginal = false
    @State private var clearConfirmation = false
    @State private var deleteConfirmation = false
    @State private var entryToDelete: UUID?

    private var entries: [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.history.entries.filter {
            query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.rawText.localizedCaseInsensitiveContains(query)
        }
    }
    private var selected: HistoryEntry? { entries.first { $0.id.uuidString == selectedID } }
    private var selection: Binding<UUID?> {
        Binding(get: { UUID(uuidString: selectedID) }, set: { selectedID = $0?.uuidString ?? "" })
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "还没有听写记录" : "没有找到记录", systemImage: "clock")
                } description: {
                    Text(search.isEmpty ? "完成听写后，在这里查找、查看和复制文字。" : "试试其他关键词，或清除搜索条件。")
                } actions: {
                    if search.isEmpty { Button("前往开始") { model.goTo(.home) } }
                    else { Button("清除搜索") { search = "" } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyBrowser
            }
            Divider()
            HStack(spacing: 12) {
                Text(search.isEmpty ? "\(entries.count) 条本地记录" : "找到 \(entries.count) 条记录")
                Spacer(minLength: 8)
                Text(costDescription)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
            if let error = model.history.storageError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).padding(12)
            }
        }
        .navigationTitle("历史记录")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                HistorySearchField(text: $search).frame(width: 260)
                Menu {
                    Button("删除所选记录", role: .destructive) {
                        if let selected { requestDelete(selected.id) }
                    }.disabled(selected == nil)
                    Divider()
                    Button("清空历史记录…", role: .destructive) { clearConfirmation = true }
                        .disabled(model.history.entries.isEmpty)
                } label: { Label("历史记录操作", systemImage: "ellipsis") }
                .help("历史记录操作")
            }
        }
        .onChange(of: entries.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0.uuidString == selectedID }) {
                selectedID = ids.first?.uuidString ?? ""
            }
        }
        .onChange(of: selectedID) { _, _ in showOriginal = false }
        .confirmationDialog("删除这条听写记录？", isPresented: $deleteConfirmation) {
            Button("删除记录", role: .destructive) {
                if let entryToDelete { model.history.delete(entryToDelete) }
                entryToDelete = nil
            }
        } message: { Text("最终文字、识别原稿和保留的原音将从本机删除，无法恢复。") }
        .confirmationDialog("清空这台 Mac 上的文字历史？", isPresented: $clearConfirmation) {
            Button("清空历史", role: .destructive) { model.history.clear(); selectedID = "" }
        } message: { Text("所有文字记录和保留的原音将被删除，无法恢复。") }
    }

    private var historyBrowser: some View {
        GeometryReader { geometry in
            // Constrain AppKit's split view to this pane; its remembered column
            // widths must not enlarge the surrounding navigation split view.
            HSplitView {
                List(entries, selection: selection) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entry.text.isEmpty ? entry.rawText : entry.text)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                            Spacer(minLength: 4)
                            Text(entry.mode.title)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .tag(entry.id)
                    .contextMenu {
                        Button("复制最终文字") { model.copy(entry.text) }
                        Button("删除记录", role: .destructive) { requestDelete(entry.id) }
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 340)
                if let selected {
                    HistoryDetailView(entry: selected, showOriginal: $showOriginal,
                                      audioFolder: model.history.audioFolder(for: selected.id),
                                      copy: model.copy)
                        .id(selected.id)
                        .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("选择一条记录", systemImage: "text.alignleft")
                        .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func requestDelete(_ id: UUID) { entryToDelete = id; deleteConfirmation = true }
    private var costDescription: String {
        let known = model.history.entries.compactMap(\.cost).reduce(0, +)
        let unknown = model.history.entries.filter { $0.cost == nil }.count
        return String(format: "全部历史已知费用 $%.4f", known) + (unknown > 0 ? " · \(unknown) 条费用未知" : "")
    }
}
