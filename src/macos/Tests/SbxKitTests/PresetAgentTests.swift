import Testing
import Foundation
@testable import SbxKit

@Suite("preset agent")
struct PresetAgentTests {
    @Test("buildPreset stores the agent")
    func buildPresetStoresAgent() throws {
        let preset = try buildPreset(
            name: "p", rootPath: "/root", template: "tpl", defaultTemplate: "tpl",
            sandboxName: nil, clone: false, editable: ["/root/A"], readOnly: [],
            agent: "opencode"
        )
        #expect(preset.agent == "opencode")
    }

    @Test("a preset decoded from old JSON without the agent field gets empty string")
    func oldJSONWithoutAgentDecodesToEmpty() throws {
        let json = """
            {"name":"p","rootPath":"/root","template":"tpl","clone":false,"editable":["A"],"readOnly":[]}
            """
        let preset = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(preset.agent == "")
    }

    @Test("agent round-trips through JSON")
    func agentRoundTripsThroughJSON() throws {
        let preset = try buildPreset(
            name: "p", rootPath: "/root", template: "tpl", defaultTemplate: "tpl",
            sandboxName: nil, clone: false, editable: ["/root/A"], readOnly: [],
            agent: "opencode"
        )
        let restored = try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(preset))
        #expect(restored.agent == "opencode")
    }

    @Test("buildPreset trims the agent")
    func buildPresetTrimsAgent() throws {
        let preset = try buildPreset(
            name: "p", rootPath: "/root", template: "tpl", defaultTemplate: "tpl",
            sandboxName: nil, clone: false, editable: ["/root/A"], readOnly: [],
            agent: "  opencode  "
        )
        #expect(preset.agent == "opencode")
    }

    @Test("buildPreset normalizes a whitespace-only agent to empty")
    func buildPresetNormalizesBlankAgentToEmpty() throws {
        let preset = try buildPreset(
            name: "p", rootPath: "/root", template: "tpl", defaultTemplate: "tpl",
            sandboxName: nil, clone: false, editable: ["/root/A"], readOnly: [],
            agent: "   "
        )
        #expect(preset.agent == "")
    }
}
