import SwiftUI

struct ContentView: View {
    @Bindable var model: AppController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                Section("OpenTypeless") {
                    ForEach(AppPage.allCases) { page in
                        Label(page.title, systemImage: page.symbol)
                            .listItemTint(.preferred(.accentColor)).tag(page)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.isBusy ? model.phaseTitle : "准备听写", systemImage: model.isBusy ? "waveform" : "mic")
                        .foregroundStyle(model.isBusy ? Color.accentColor : .secondary)
                    Text("\(model.shortcutLabel) 开始或结束 · Esc 取消").foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            Group {
                switch model.page ?? .home {
                case .home: HomeView(model: model)
                case .history: HistoryView(model: model)
                case .dictionary: DictionaryView(model: model, settings: model.settings, learned: model.learnedDictionary)
                case .settings: SettingsView(model: model)
                }
            }
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            model.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
}
