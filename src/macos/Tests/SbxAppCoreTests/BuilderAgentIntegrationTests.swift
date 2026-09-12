// Acceptance path for the Builder agent picker: a template pick
// auto-selects the agent, and a manual radio choice flows into the command
// preview and the launched argv. Model-level (no SwiftUI — PLAN.md forbids
// SwiftUI-importing tests); the view is a thin binding over this state.
import Testing
import Foundation
import SbxKit
import SbxServices
@testable import SbxAppCore

@MainActor
struct BuilderAgentIntegrationTests {
    @Test("template pick auto-selects the agent; manual pick reaches preview and launch argv")
    func agentAcceptancePath() async {
        let launcher = StubLauncher()
        let model = BuilderModel(
            scanner: StubScanner(),
            toasts: ToastCenter(),
            templateLister: StubTemplateLister(),
            launcher: launcher,
            clipboard: StubClipboard(),
            persistTemplate: { _ in },
            pathExists: { _ in true }
        )
        var config = defaultConfig()
        config.agent = "claude"
        config.defaultTemplate = "docker.io/library/claude-sbx-dotnet10:v4"
        model.adopt(config: config)
        model.setSelection("/root/A", .editable)

        // 1. Initial preview uses the config agent.
        guard case .ready(let claudeDisplay) = model.commandPreview else {
            Issue.record("expected a .ready preview")
            return
        }
        #expect(claudeDisplay.contains(" claude /root/A"))

        // 2. Picking an opencode template flips the radio automatically.
        await model.commitTemplate("docker.io/docker/sandbox-templates:opencode-docker")
        #expect(model.agent == "opencode")
        guard case .ready(let autoDisplay) = model.commandPreview else {
            Issue.record("expected a .ready preview")
            return
        }
        #expect(autoDisplay.contains(" opencode /root/A"))

        // 3. A manual radio choice flows into the preview and the launch.
        await model.setAgent("claude")
        guard case .ready(let manualDisplay) = model.commandPreview else {
            Issue.record("expected a .ready preview")
            return
        }
        #expect(manualDisplay.contains(" claude /root/A"))

        await model.run()
        #expect(launcher.calls.count == 1)
        #expect(launcher.calls[0] == [
            "sbx", "run", "--template",
            "docker.io/docker/sandbox-templates:opencode-docker",
            "claude", "/root/A",
        ])
    }
}
