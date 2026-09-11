import AppKit

/// Activation policy, terminate-on-last-window, config flush.
///
/// Diverges from Electron on purpose: the Electron app keeps running on
/// darwin after its last window closes (`window-all-closed` skips `quit()`),
/// but PLAN.md's Phase 3 design chooses terminate-on-last-window-close for
/// this native app instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `SbxHelperApp`'s `WindowGroup` `.task` once the models exist.
    /// Awaited before the app is allowed to actually terminate, so the
    /// config store's debounced write gets a chance to flush.
    @MainActor var onTerminate: (() async -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await self.onTerminate?()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
