import SwiftUI
import SbxAppCore

/// The View menu: ⌘1/⌘2 tab switching (PLAN.md: this **replaces** the
/// Electron app's ARIA ←/→-on-tab-button idiom, which isn't the native
/// convention) plus ⌘R "Rescan Folders" — a native addition beyond the
/// Electron app, added in Phase 3 (it predates Phase 5's root picker and remains
/// the only way to re-run the scan without changing roots).
struct AppCommands: Commands {
    let app: AppModel
    let builder: BuilderModel
    let sandboxes: SandboxesModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("View") {
            Button("Builder") { app.activeTab = .builder }
                .keyboardShortcut("1", modifiers: .command)
            Button("Sandboxes") { app.activeTab = .sandboxes }
                .keyboardShortcut("2", modifiers: .command)

            Divider()

            Button("Rescan Folders", action: rescan)
                .keyboardShortcut("r", modifiers: .command)
        }

        // A menu command rather than a view-level key handler: ⌘↩ must work
        // while focus sits in the sandbox-name field (app.js evaluates it
        // before its own typing guard for exactly that reason), and a menu
        // command is focus-independent. "Copy Command" deliberately carries
        // no shortcut — the JS has none, and ⌘C would shadow ordinary
        // text-field copy in the name/custom-template fields.
        //
        // Both ⌘↩ items share one shortcut, so each is gated on its tab
        // being active — the native analogue of app.js's
        // `onGlobalKeydown` dispatching to the active tab's handler.
        // Without the gate, whichever menu item the system preferred would
        // fire on the wrong tab whenever both models happened to be runnable.
        CommandMenu("Builder") {
            Button("Run in iTerm") { Task { await builder.run() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!builder.canRun || app.activeTab != .builder)

            Button("Copy Command") { builder.copyCommand() }
                .disabled(!builder.canCopy)
        }

        CommandMenu("Sandboxes") {
            Button("Run Selected Sandbox") { Task { await sandboxes.run() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!sandboxes.canRun || app.activeTab != .sandboxes)
        }
    }

    private func rescan() {
        builder.scan(
            root: app.config.rootPath,
            maxDepth: app.config.maxDepth,
            ignoreFolders: Set(app.config.ignoreFolders)
        )
    }
}
