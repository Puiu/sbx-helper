import SwiftUI
import SbxAppCore

/// Ports app.js's showToast (`#toast`, `.toast-error`, 3.5s auto-dismiss —
/// see ToastCenter.swift). `.overlay(alignment: .bottom)` per PLAN.md;
/// `AccessibilityNotification.Announcement` replaces the JS's
/// `role="status"`.
struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack {
            Spacer()
            if let toast = toasts.current {
                Text(toast.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius)
                            .fill(toast.isError ? Theme.danger : Theme.ink)
                    )
                    .padding(.bottom, 20)
                    .onTapGesture { toasts.dismiss() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
                    .task(id: toast.id) {
                        AccessibilityNotification.Announcement(toast.message).post()
                    }
            }
        }
        .animation(.easeOut(duration: 0.15), value: toasts.current)
        .allowsHitTesting(toasts.current != nil)
    }
}
