import Observation

/// Ports src/electron/public/app.js's showToast — one visible toast at a
/// time, auto-dismissed after an interval, replaced (not queued) by a
/// second call. A separate object rather than state on `AppModel` because
/// both BuilderModel (Phase 4) and SandboxesModel (Phase 6) need to raise
/// toasts and neither should own the other's presentation.
public struct Toast: Sendable, Equatable, Identifiable {
    public let id: Int
    public let message: String
    public let isError: Bool
}

@MainActor
@Observable
public final class ToastCenter {
    private let dismissAfter: Duration
    private var nextID = 0
    private var dismissalTask: Task<Void, Never>?

    public private(set) var current: Toast?

    public init(dismissAfter: Duration = .milliseconds(3500)) {
        self.dismissAfter = dismissAfter
    }

    public func show(_ message: String, isError: Bool = false) {
        dismissalTask?.cancel()

        let id = nextID
        nextID += 1
        current = Toast(id: id, message: message, isError: isError)

        let delay = dismissAfter
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.current = nil
        }
    }

    public func dismiss() {
        dismissalTask?.cancel()
        dismissalTask = nil
        current = nil
    }

    /// Test-only: awaits the current dismissal timer, if any.
    public func quiesce() async {
        await dismissalTask?.value
    }

    /// Test-only: the pending dismissal `Task`, so a test can hold a
    /// reference across a later `show()`/`dismiss()` call and assert it was
    /// actually cancelled. The `current?.id == id` guard in `show()`'s timer
    /// already makes a *stale, uncancelled* timer harmless from the
    /// outside — indistinguishable from a cancelled one by observing
    /// `current` alone — so verifying cancellation itself requires this.
    var dismissalTaskForTesting: Task<Void, Never>? { dismissalTask }
}
