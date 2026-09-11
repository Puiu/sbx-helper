import SwiftUI
import SbxAppCore

/// The –/edit/ro control from `app.js`'s `segButton` (177-189, wired at
/// 274-276). Mouse clicks are NOT toggles — tapping an already-active
/// button re-issues the same selection (a no-op); only the `e`/`r`
/// keyboard shortcuts toggle (BuilderView). `–` is never disabled, even
/// when `isLocked` — a covered row must still be clearable.
struct SegmentedTriStateView: View {
    let selection: SelectionKind?
    let isLocked: Bool
    let onChange: (SelectionKind?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(label: "–", isActive: selection == nil, isDisabled: false) {
                onChange(nil)
            }
            .accessibilityLabel("off")

            segment(label: "edit", isActive: selection == .editable, isDisabled: isLocked) {
                onChange(.editable)
            }
            .accessibilityLabel("editable")

            segment(label: "ro", isActive: selection == .readOnly, isDisabled: isLocked) {
                onChange(.readOnly)
            }
            .accessibilityLabel("read-only")
        }
    }

    private func segment(label: String, isActive: Bool, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(11))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .fill(isActive ? Theme.hairlineStrong : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}
