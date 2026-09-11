import SwiftUI
import SbxAppCore

/// Ports app.js's manifestRow (302-338): star, path, note, remove — in that
/// order. The star is kept in the layout even when empty (fixed width) so
/// read-only rows align with editable ones, matching the JS's
/// `visibility: hidden` rather than removing the element.
struct ManifestRowView: View {
    let entry: ManifestEntry
    let onSetPrimary: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSetPrimary) {
                Text(entry.star)
                    .font(.system(size: 12))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .disabled(!entry.canBePrimary)
            .help(entry.canBePrimary ? "Set as primary workspace" : "")

            Text(entry.displayPath)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.ink)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
            }

            Button(action: onRemove) {
                Text("×")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.path)")
        }
        .padding(.vertical, 4)
    }
}
