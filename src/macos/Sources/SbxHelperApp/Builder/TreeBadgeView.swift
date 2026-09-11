import SwiftUI

/// `.badge-git` / `.badge-unreadable` from styles.css — a small monospaced
/// pill. Muted by default; the `unreadable` badge tints it to `Theme.danger`.
struct TreeBadgeView: View {
    let text: String
    var tint: Color = Theme.muted

    init(_ text: String, tint: Color = Theme.muted) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(Theme.mono(10))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.badgeRadius)
                    .stroke(tint == Theme.muted ? Theme.hairlineStrong : tint, lineWidth: 1)
            )
    }
}
