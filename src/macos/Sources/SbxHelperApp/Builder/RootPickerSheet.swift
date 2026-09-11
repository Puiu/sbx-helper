import SwiftUI
import SbxKit
import SbxAppCore

/// Ports src/electron/public/app.js's root dialog (517-634): with nothing
/// typed the list shows `recentRoots`; editing the field switches to live
/// filesystem suggestions (PathCompleter, 120ms debounce). Clicking a
/// suggestion fills the field; ↓/↑ move the highlight, Enter accepts the
/// highlight or confirms, Esc cancels. Confirm validates through
/// `BuilderModel.changeRoot` and shows the failure inline (app.js's
/// `rootError`) rather than toasting.
struct RootPickerSheet: View {
    @Environment(BuilderModel.self) private var builder
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var suggestions: [String] = []
    @State private var highlight = -1
    @State private var error: String?
    @FocusState private var inputFocused: Bool
    @State private var suggestTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change root folder")
                .font(.headline)

            TextField("/absolute/path", text: $input)
                .font(Theme.mono(12))
                .focused($inputFocused)
                .disableAutocorrection(true)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onChange(of: input) { _, _ in scheduleSuggest() }

            Text(input.trimmingCharacters(in: .whitespaces).isEmpty ? "Recent roots" : "Suggestions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, path in
                        Button {
                            acceptSuggestion(path)
                        } label: {
                            Text(path)
                                .font(Theme.mono(12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(index == highlight ? Theme.readBg : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 220)

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // No `.defaultAction` here deliberately: Enter in the field
                // already reaches `confirm()` through `.onSubmit`, and a
                // default button would fire it a second time (double
                // scan + double config write).
                Button("Change") { confirm() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .onAppear {
            input = app.config.rootPath
            suggestions = app.config.recentRoots
            inputFocused = true
        }
        .onDisappear { suggestTask?.cancel() }
    }

    /// app.js's `updatePathSuggestions`, debounced at 120ms
    /// (suggestionDebounce). A blank field falls back to recent roots —
    /// app.js's `renderRecentRoots` branch of the same function.
    private func scheduleSuggest() {
        suggestTask?.cancel()
        suggestTask = Task { [input] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            if input.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestions = app.config.recentRoots
            } else {
                let completer = PathCompleter(ignoreFolders: Set(app.config.ignoreFolders))
                suggestions = completer.completePath(input)
            }
            highlight = -1
        }
    }

    /// app.js's `acceptSuggestion` — fills the field (with a trailing slash
    /// so the next keystroke completes inside it) and refreshes immediately
    /// rather than waiting out the debounce.
    private func acceptSuggestion(_ path: String) {
        suggestTask?.cancel()
        input = path.hasSuffix("/") ? path : path + "/"
        suggestions = PathCompleter(ignoreFolders: Set(app.config.ignoreFolders)).completePath(input)
        highlight = -1
        inputFocused = true
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        // app.js: ArrowDown clamps to [0, len-1] from -1; ArrowUp clamps to
        // [-1, len-1] — -1 means "no highlight", i.e. Enter confirms.
        highlight = min(suggestions.count - 1, max(-1, highlight + delta))
        return .handled
    }

    private func submit() {
        if highlight >= 0 {
            acceptSuggestion(suggestions[highlight])
        } else {
            confirm()
        }
    }

    private func confirm() {
        Task {
            let message = await builder.changeRoot(
                to: input,
                maxDepth: app.config.maxDepth,
                ignoreFolders: Set(app.config.ignoreFolders)
            )
            if let message {
                error = message
            } else {
                dismiss()
            }
        }
    }
}
