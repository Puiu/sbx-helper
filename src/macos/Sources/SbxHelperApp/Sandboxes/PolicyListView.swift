import SwiftUI
import SbxKit
import SbxAppCore

/// The selected sandbox's network policy section — ports index.html:114-126's
/// `#policySection` and app.js:977-1038's `renderPolicies` plus the add row
/// (`doPolicyAdd`/`doPolicyRemove`). Sandbox-scoped rules arrive first (that
/// ordering is `parseNetworkRules`'s, not the view's) and only `removable`
/// rules get a remove button; kit/global rows render dimmed with none.
struct PolicyListView: View {
    @Environment(SandboxesModel.self) private var environmentSandboxes

    var body: some View {
        @Bindable var sandboxes = environmentSandboxes

        VStack(alignment: .leading, spacing: 8) {
            Text("Network policy")
                .font(.system(size: 13, weight: .semibold))

            Text(sandboxes.policySummaryText)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)

            ForEach(sandboxes.policyRules) { rule in
                PolicyRowView(rule: rule, isBusy: sandboxes.isPolicyBusy) {
                    Task { await sandboxes.removePolicy(rule) }
                }
            }

            HStack(spacing: 6) {
                Picker("Decision", selection: $sandboxes.policyDecision) {
                    Text("Allow").tag(Decision.allow)
                    Text("Deny").tag(Decision.deny)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                TextField(
                    "example.com, *.example.com",
                    text: $sandboxes.policyInput
                )
                .font(Theme.mono(12))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await sandboxes.addPolicy() } }

                Button("Add") { Task { await sandboxes.addPolicy() } }
                    .disabled(sandboxes.isPolicyBusy)
            }

            if let error = sandboxes.policyError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
            }
        }
        // Fires on appearance and on every selection change, cancelling the
        // previous fetch — the native analogue of app.js's
        // `selectSandbox` → `fetchPolicies`. The model's generation guard
        // discards anything cancellation doesn't catch.
        .task(id: sandboxes.selectedName) {
            await sandboxes.fetchPolicies()
        }
    }
}

/// One policy rule — ports app.js:997-1037's `renderPolicies` row: a
/// bordered box (dimmed for non-sandbox rules), a decision badge (amber
/// for allow, red for deny), the scope label, the × button only when
/// `removable`, and the resource chips below.
private struct PolicyRowView: View {
    let rule: PolicyRule
    let isBusy: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(rule.decision)
                    .font(Theme.mono(10))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(rule.decision == "deny" ? Theme.danger : Theme.writeStrong)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.badgeRadius)
                            .stroke(rule.decision == "deny" ? Theme.danger : Theme.write, lineWidth: 1)
                    )

                Text(rule.scopeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)

                Spacer(minLength: 6)

                if rule.removable {
                    Button(action: onRemove) {
                        Text("×")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help("Remove this rule")
                    .accessibilityLabel("Remove rule for \(rule.resources.joined(separator: ", "))")
                }
            }

            FlowLayout(spacing: 4) {
                ForEach(rule.resources, id: \.self) { resource in
                    Text(resource)
                        .font(Theme.mono(10.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.paper)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.badgeRadius)
                                .stroke(Theme.hairlineStrong, lineWidth: 1)
                        )
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .opacity(rule.sandboxScoped ? 1 : 0.6)
    }
}

/// Minimal left-aligned wrapping layout for the resource chips — the native
/// analogue of `display: flex; flex-wrap: wrap` on `.policy-resources`.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposalWidth: proposal.width ?? .infinity, subviews: subviews)
        let rowsHeight: CGFloat = rows.reduce(0) { partial, row in partial + row.height }
        let height = rowsHeight + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(proposalWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(proposalWidth width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current: [Item] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        func flush() {
            if !current.isEmpty { rows.append(Row(items: current, height: currentHeight)) }
            current = []
            currentWidth = 0
            currentHeight = 0
        }
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.isEmpty, currentWidth + size.width > width { flush() }
            current.append(Item(index: index, size: size))
            currentWidth += size.width + spacing
            currentHeight = max(currentHeight, size.height)
        }
        flush()
        return rows
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        let items: [Item]
        let height: CGFloat
    }
}
