import SwiftUI
import SbxAppCore
import SbxKit
import SbxServices

/// Live "sbx commands" debug section for the Sandboxes tab — every `sbx`
/// spawn the tab issues (command, exit status, stdout/stderr), newest-last.
/// Collapsed by default so it never steals list space; the log refreshes
/// after every model operation, including failed ones, so a parse failure
/// still shows the exact response that failed to parse.
struct SandboxDebugLogView: View {
    @Environment(SandboxesModel.self) private var environmentSandboxes
    @State private var expanded = false

    var body: some View {
        let sandboxes = environmentSandboxes

        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Button("Reload sandboxes") { Task { await sandboxes.fetch() } }

                if sandboxes.debugLog.isEmpty {
                    Text("No sbx commands recorded yet — they appear here as the tab issues them.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                } else {
                    ForEach(sandboxes.debugLog) { entry in
                        entryView(entry)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("sbx commands (\(sandboxes.debugLog.count))")
                .font(.system(size: 11.5))
        }
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
                .stroke(Theme.hairline, lineWidth: 1)
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
