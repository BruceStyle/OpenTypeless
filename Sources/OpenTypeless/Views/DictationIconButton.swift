import SwiftUI

struct DictationIconButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 13 : 11, weight: .semibold))
                .frame(width: DictationLayout.buttonSize, height: DictationLayout.buttonSize)
        }
        .buttonStyle(OverlayButtonStyle(prominent: prominent))
        .help(title).accessibilityLabel(title)
    }
}

private struct OverlayButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(prominent ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.065), in: Circle())
            .frame(width: DictationLayout.buttonTargetSize, height: DictationLayout.buttonTargetSize)
            // Keep the pointer target larger than the visible button.
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
    }
}
