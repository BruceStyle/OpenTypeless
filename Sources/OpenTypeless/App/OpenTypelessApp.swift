import AppKit
import SwiftUI

@main struct OpenTypelessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppController()
    @State private var menuShortcuts = MenuShortcutPresenter()
    #if DEBUG
    @State private var verificationColorScheme: ColorScheme?
    #endif
    var body: some Scene {
        Window("OpenTypeless", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 880, minHeight: 620)
                .onChange(of: model.shortcutLabel, initial: true) { _, shortcut in
                    menuShortcuts.shortcut = shortcut
                }
                #if DEBUG
                .preferredColorScheme(verificationColorScheme)
                #endif
        }
        .defaultSize(width: 1_050, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verification") {
                CommandMenu("菜单预览") { statusMenuContents }
                CommandMenu("开发验证") {
                    Menu("主窗口外观") {
                        Button("跟随系统") { previewMainAppearance(nil) }
                        Button("浅色") { previewMainAppearance(.light) }
                        Button("深色") { previewMainAppearance(.dark) }
                    }
                    Divider()
                    Button("检查全部浮窗外观（静态）") { model.showOverlayVisualVerification() }
                    Divider()
                    Button("预览连续进度（不调用模型）") { model.previewProcessingOverlay() }.disabled(model.isBusy)
                    if ProcessInfo.processInfo.environment["OPENTYPELESS_VERIFICATION_ROOT"] != nil {
                        Button("观察专用测试文稿（不调用模型）") { model.scheduleDictionaryVerification() }.disabled(model.isBusy)
                    }
                    Button("预览就绪浮层") { model.previewReadyOverlay() }.disabled(model.isBusy)
                    Button("预览已确认回填后收起") { model.previewReadyOverlay(delivery: .verified) }.disabled(model.isBusy)
                    Button("预览已粘贴但无法读回时收起") { model.previewReadyOverlay(delivery: .unverified) }.disabled(model.isBusy)
                    Button("验证 4 秒纯静音") { model.verifySilence() }.disabled(model.isBusy)
                    Button("选择匿名测试音频…") { model.chooseVerificationAudio() }.disabled(model.isBusy)
                    Button("对比识别模型（6 次请求）") { model.compareTranscriptionModels() }
                        .disabled(model.isBusy || !model.verificationAudioLoaded || model.comparingTranscription)
                    Button("对比 Whisper 与 GPT Mini") { model.compareTranscriptionModels(alternative: "openai/gpt-4o-mini-transcribe") }
                        .disabled(model.isBusy || !model.verificationAudioLoaded || model.comparingTranscription)
                    Button("10 秒后开始音频验证") { model.scheduleVerification() }
                        .disabled(model.isBusy || !model.verificationAudioLoaded)
                    Button("10 秒后验证失败恢复") { model.scheduleVerification(failFirst: true) }
                        .disabled(model.isBusy || !model.verificationAudioLoaded)
                }
            }
            #endif
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.goTo(.settings) }.keyboardShortcut(",")
            }
            CommandMenu("前往") {
                Button("开始") { model.goTo(.home) }.keyboardShortcut("1")
                Button("历史记录") { model.goTo(.history) }.keyboardShortcut("2")
                Button("个人词典") { model.goTo(.dictionary) }.keyboardShortcut("3")
                Button("设置") { model.goTo(.settings) }.keyboardShortcut("4")
            }
        }
        MenuBarExtra {
            statusMenuContents
        } label: {
            Label {
                Text(model.phase == .recording ? "OpenTypeless：正在录音" : "OpenTypeless")
            } icon: {
                if model.phase == .recording {
                    Image(systemName: "mic.fill")
                } else {
                    Image(nsImage: MenuBarIcon.image).renderingMode(.template)
                }
            }
            .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder private var statusMenuContents: some View {
        Button(model.phase == .recording ? "停止并整理" : "开始听写") { model.toggle() }
            .disabled(model.isBusy && model.phase != .recording)
        if model.isBusy { Button("取消听写") { model.cancel() }.disabled(model.phase == .inserting) }
        Divider()
        Button("打开 OpenTypeless") { model.goTo(.home) }
        Button("设置…") { model.goTo(.settings) }
        Divider()
        Button("退出") { model.cancel(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    #if DEBUG
    private func previewMainAppearance(_ colorScheme: ColorScheme?) {
        guard ProcessInfo.processInfo.arguments.contains("--verification") else { return }
        // A window-only review override; it never changes system or saved preferences.
        verificationColorScheme = colorScheme
    }
    #endif
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
