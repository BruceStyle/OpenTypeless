import SwiftUI
import OpenTypelessCore

struct OverlayAppearanceSettings: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Section("浮窗外观") {
            SettingsItem(spacing: 12) {
                Picker("浮窗外观", selection: $settings.configuration.overlayAppearance) {
                    ForEach(OverlayAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("仅改变听写浮窗。主窗口始终跟随系统外观，选择后自动保存。")
                    .font(.caption).foregroundStyle(.secondary)
                OverlayAppearancePreview(appearance: settings.configuration.overlayAppearance)
            }
        }
    }
}

private struct OverlayAppearancePreview: View {
    let appearance: OverlayAppearance

    private static let progress: DictationProgress = {
        var progress = DictationProgress()
        progress.begin(at: 0, audioSeconds: 10, totalChunks: 1, completedChunks: 0, includesRewrite: true)
        progress.tick(at: 5)
        return progress
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("即时预览").font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { samples }
                VStack(spacing: 12) { samples }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var samples: some View {
        sample(title: "浅色背景", background: Color(white: 0.97))
        sample(title: "深色背景", background: Color(white: 0.12))
    }

    private func sample(title: String, background: Color) -> some View {
        let size = DictationLayout.contentSize
        return VStack(alignment: .leading, spacing: 7) {
            DictationProcessingContent(progress: Self.progress)
                .frame(width: size.width, height: size.height)
                .dictationSurface(appearance: appearance, preview: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                // These fixed colors are sample backdrops, not the app theme.
                .background(background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.15)))
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title)上的\(appearance.title)浮窗预览")
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
