import SwiftUI
import SbxAppCore
import SbxKit
import SbxServices

/// Live "sbx commands" debug section for the Sandboxes tab — every `sbx`
/// spawn the tab issues (command, exit status, stdout/stderr), newest-first.
/// Collapsed by default so it never steals list space; the log refreshes
/// after every model operation, including failed ones, so a parse failure
/// still shows the exact response that failed to parse.
struct SandboxDebugLogView: View {
    @Environment(SandboxesModel.self) private var environmentSandboxes
    @State private var expanded = false

    var body: some View {
        let sandboxes = environmentSandboxes

        // Hand-rolled disclosure instead of `DisclosureGroup`: the latter
        // sizes its content to its ideal height, so inside a short
        // `VSplitView` pane the body overflowed and was centered, pushing
        // the header and the top of the log out of view. A plain VStack
        // pins the header on top and gives the log exactly the remainder.
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text("sbx commands (\(sandboxes.debugLog.count))")
                        .font(.system(size: 11.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Button("Reload sandboxes") { Task { await sandboxes.fetch() } }

                // Scrolls inside the `VSplitView` allocation from
                // `SandboxesView`, so a long log never grows the pane —
                // the divider controls the height, overflow scrolls here.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if sandboxes.debugLog.isEmpty {
                            Text("No sbx commands recorded yet — they appear here as the tab issues them.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.muted)
                        } else {
                            ForEach(sandboxes.debugLog.reversed()) { entry in
                                entryView(entry)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // Inset so the first/last cards never sit flush at the
                    // scroll edge, where the ScrollView's clipping would cut
                    // the outer half of a centered stroke.
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func entryView(_ entry: SbxInvocation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.command)
                    .font(Theme.mono(11))
                    .textSelection(.enabled)
                Spacer()
                Text(entry.statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(entry.ok ? Theme.muted : Theme.danger)
            }

            Button("Copy output") {
                _ = SystemServices.copyToClipboard(copyText(for: entry))
            }
            .font(.system(size: 11))

            if !entry.stdout.isEmpty {
                outputBlock(title: "stdout", text: entry.stdout)
            }
            if !entry.stderr.isEmpty {
                outputBlock(title: "stderr", text: entry.stderr, isError: true)
            }
        }
        .padding(8)
        .background(Theme.paper)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private func outputBlock(title: String, text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(isError ? Theme.danger : Theme.muted)
            ScrollView {
                Text(text)
                    .font(Theme.mono(10.5))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160, alignment: .topLeading)
        }
    }

    /// The response body worth pasting into a bug report — stdout, or
    /// stderr when the command produced no stdout at all.
    private func copyText(for entry: SbxInvocation) -> String {
        "\(entry.command)\n\(entry.statusText)\n\(entry.stdout.isEmpty ? entry.stderr : entry.stdout)"
    }
}
