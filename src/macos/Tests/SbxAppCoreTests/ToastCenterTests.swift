// Ports src/electron/public/app.js's showToast (one #toast element, one
// setTimeout, cleared and reset per call) as a shared, testable object so
// both BuilderModel (Phase 4) and SandboxesModel (Phase 6) can raise toasts
// without either owning the other's presentation.
import Testing
@testable import SbxAppCore

@MainActor
struct ToastCenterTests {
    @Test
    func showPresentsAToastImmediately() {
        let center = ToastCenter()
        center.show("Copied to clipboard.")
        #expect(center.current?.message == "Copied to clipboard.")
    }

    @Test
    func showMarksAnErrorToastAsError() {
        let center = ToastCenter()
        center.show("Something went wrong.", isError: true)
        #expect(center.current?.isError == true)
    }

    @Test
    func aSecondShowReplacesTheFirstAndGetsANewIdentity() {
        let center = ToastCenter()
        center.show("First.")
        let firstID = center.current?.id
        center.show("Second.")
        #expect(center.current?.message == "Second.")
        #expect(center.current?.id != firstID)
    }

    @Test
    func dismissClearsTheCurrentToast() {
        let center = ToastCenter()
        center.show("Copied to clipboard.")
        center.dismiss()
        #expect(center.current == nil)
    }

    @Test
    func theToastAutoDismissesAfterItsInterval() async {
        let center = ToastCenter(dismissAfter: .milliseconds(10))
        center.show("Copied to clipboard.")
        await center.quiesce()
        #expect(center.current == nil)
    }

    @Test
    func aReplacementToastCancelsTheEarlierDismissal() {
        // Deterministic by construction, not by timing margin: the
        // `current?.id == id` guard inside show()'s own dismissal timer
        // already makes a stale, uncancelled timer harmless to observe from
        // `current` alone, so a wall-clock race on that value can't tell
        // "cancelled" apart from "still running but guarded" — see
        // `dismissalTaskForTesting`'s doc comment. Capturing the actual
        // `Task` before it's superseded and asserting `isCancelled` can.
        let center = ToastCenter(dismissAfter: .seconds(60))
        center.show("First.")
        let firstDismissalTask = center.dismissalTaskForTesting

        center.show("Second.")

        #expect(firstDismissalTask?.isCancelled == true)
    }
}
