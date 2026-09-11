import Testing
@testable import SbxAppCore

struct AppTabTests {
    @Test
    func hasBuilderAndSandboxesCases() {
        #expect(AppTab.allCases == [.builder, .sandboxes])
    }

    @Test
    func titlesMatchTabBarLabels() {
        // Matches src/electron/public/index.html's tab button labels.
        #expect(AppTab.builder.title == "Builder")
        #expect(AppTab.sandboxes.title == "Sandboxes")
    }

    @Test
    func idIsStableForSwiftUIIdentity() {
        #expect(AppTab.builder.id == AppTab.builder.rawValue)
    }
}
