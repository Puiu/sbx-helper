import SwiftUI
import SbxAppCore

/// Ports app.js's template/name/clone controls (index.html:52-68,
/// populateTemplateSelect 415-439, the change handlers 1325-1351).
struct BuilderSettingsView: View {
    private static let customSentinel = "__custom__"

    @Environment(BuilderModel.self) private var environmentBuilder
    var focusedField: FocusState<BuilderField?>.Binding
    @State private var showCustomField = false
    @State private var customTemplateText = ""

    var body: some View {
        @Bindable var builder = environmentBuilder

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Template")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)

                Picker("", selection: templateSelection(for: builder)) {
                    ForEach(builder.templateOptions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                    Text("Custom…").tag(Self.customSentinel)
                }
                .labelsHidden()

                if showCustomField || builder.usesCustomTemplate {
                    TextField("custom template name", text: $customTemplateText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(12))
                        .focused(focusedField, equals: .customTemplate)
                        .onSubmit { commit(builder) }
                        .onChange(of: focusedField.wrappedValue) { old, new in
                            if old == .customTemplate, new != .customTemplate { commit(builder) }
                        }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sandbox name")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                TextField("auto", text: $builder.sandboxName)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
                    .focused(focusedField, equals: .sandboxName)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("--clone", isOn: $builder.clone)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Text("(work on an in-container clone, not a live mount)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    /// Choosing "Custom…" must not change `template` — it only reveals and
    /// focuses the custom field, seeded with the current effective value
    /// (app.js:1325-1332's `templateCustom.value = state.template`).
    /// Choosing a real option commits it immediately.
    private func templateSelection(for builder: BuilderModel) -> Binding<String> {
        Binding(
            get: { showCustomField || builder.usesCustomTemplate ? Self.customSentinel : builder.effectiveTemplate },
            set: { newValue in
                if newValue == Self.customSentinel {
                    customTemplateText = builder.effectiveTemplate
                    showCustomField = true
                    focusedField.wrappedValue = .customTemplate
                } else {
                    showCustomField = false
                    Task { await builder.commitTemplate(newValue) }
                }
            }
        )
    }

    /// The custom field commits on submit/blur — app.js's `change` listener,
    /// not `input` — never per keystroke.
    private func commit(_ builder: BuilderModel) {
        showCustomField = false
        Task { await builder.commitTemplate(customTemplateText) }
    }
}
