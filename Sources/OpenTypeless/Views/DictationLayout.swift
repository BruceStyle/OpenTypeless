import SwiftUI

/// Shared geometry for the floating panel, every state and both preview surfaces.
enum DictationLayout {
    static let contentSize = CGSize(width: 160, height: 48)
    static let materialInset: CGFloat = 10
    static let visibleInset: CGFloat = 12
    // A flat text/progress block needs more clearance from the capsule's
    // curved end than a concentric circular control does.
    static let progressLeadingInset: CGFloat = 20
    static let spacing: CGFloat = 8
    static let inlineSpacing: CGFloat = 4
    static let buttonSize: CGFloat = 28
    static let buttonTargetSize: CGFloat = 32
    static let statusIconSize: CGFloat = 14

    // Align circular controls by their 28 pt visible edge. Their larger
    // pointer targets extend beyond it without changing the optical inset.
    static var buttonHitOutset: CGFloat { (buttonTargetSize - buttonSize) / 2 }
    static var horizontalInset: CGFloat { visibleInset - buttonHitOutset }
    static var progressLeadingPadding: CGFloat { progressLeadingInset - horizontalInset }
    static var waveformWidth: CGFloat {
        contentSize.width - horizontalInset * 2 - buttonTargetSize * 2 - spacing * 2
    }

    static var panelSize: CGSize {
        CGSize(width: contentSize.width + materialInset * 2,
               height: contentSize.height + materialInset * 2)
    }
}
