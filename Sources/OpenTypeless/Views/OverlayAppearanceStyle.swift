import AppKit
import SwiftUI
import OpenTypelessCore

extension OverlayAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

private struct OverlayAppearanceStyle: ViewModifier {
    let appearance: OverlayAppearance
    @Environment(\.colorScheme) private var inheritedScheme

    func body(content: Content) -> some View {
        // A local environment override also works for the settings preview.
        // preferredColorScheme would propagate up and recolor its whole window.
        content.environment(\.colorScheme, appearance.colorScheme ?? inheritedScheme)
    }
}

extension View {
    func overlayAppearance(_ appearance: OverlayAppearance) -> some View {
        modifier(OverlayAppearanceStyle(appearance: appearance))
    }
}
