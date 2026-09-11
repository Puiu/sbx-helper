import SwiftUI
import SbxKit

/// One Sandboxes list row — ports app.js:867-901's `renderSandboxList` row:
/// status dot, name, agent, formatted ports, workspaces.
struct SandboxRowView: View {
    let sandbox: Sandbox

    var body: some View {
        HStack(spacing: 8) {
            statusDot
                .help(sandbox.status)

            Text(sandbox.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Text(sandbox.agent)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(sandbox.ports.map(\.formatted).joined(separator: ", ").nilIfEmpty ?? "—")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)

            Text(sandbox.workspaces.joined(separator: ", "))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(sandbox.workspaces.joined(separator: ", "))
        }
        .padding(.vertical, Theme.rowVerticalPadding)
    }

    /// Ports styles.css:670-672 — running is a filled focus dot, stopped is
    /// hollow, anything else is a filled danger dot.
    @ViewBuilder
    private var statusDot: some View {
        switch sandbox.status {
        case "running":
            Circle().fill(Theme.focus).frame(width: 8, height: 8)
        case "stopped":
            Circle().strokeBorder(Theme.hairlineStrong, lineWidth: 1).frame(width: 8, height: 8)
        default:
            Circle().fill(Theme.danger).frame(width: 8, height: 8)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
