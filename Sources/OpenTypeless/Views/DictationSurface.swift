import AppKit
import SwiftUI
import OpenTypelessCore

/// One surface for every dictation state and its settings preview.
private struct DictationSurface: ViewModifier {
    let preview: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(Color(nsColor: .windowBackgroundColor), in: Capsule())
            } else if #available(macOS 26.0, *) {
                // A non-key dictation panel needs an always-active native
                // backdrop for text contrast. Clear glass adds the system's
                // optical edge without Regular's inactive gray replacement.
                // Native tint preserves a charcoal tone over bright pages.
                let glass: Glass = colorScheme == .dark
                    ? .clear.tint(.black.opacity(0.18)) : .clear
                content.glassEffect(glass, in: Capsule())
                    .background { backdrop }
                    .materialActiveAppearance(.active)
            } else {
                content.background { backdrop }
            }
        }
        .overlay {
            if reduceTransparency || contrast == .increased {
                Capsule().strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1)
            }
        }
        .foregroundStyle(foreground)
        .environment(\.appearsActive, true)
    }

    private var backdrop: some View {
        HUDMaterial(material: .menu, blendingMode: preview ? .withinWindow : .behindWindow)
            .clipShape(Capsule())
    }

    private var foreground: Color {
        // The foreground must follow the selected appearance, rather than
        // flipping with an arbitrary app or document behind the floating HUD.
        Color(white: colorScheme == .dark ? 0.95 : 0.12)
    }
}

private struct HUDMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
}

extension View {
    func dictationSurface(appearance: OverlayAppearance = .system, preview: Bool = false) -> some View {
        modifier(DictationSurface(preview: preview))
            .overlayAppearance(appearance)
    }
}
