import Foundation
import Testing
import SbxKit
import SbxServices
@testable import SbxAppCore

@MainActor
struct AppModelTests {
    @Test
    func loadReadsTheConfigStoresCurrentConfig() async {
        let dir = TempDirectory()
        let store = ConfigStore(path: dir.joined("sbx-helper.json"))
        let model = AppModel(configStore: store)

        await model.load()

        #expect(model.config == (await store.current()))
    }

    @Test
    func loadOfAHealthyConfigLeavesTheBannerNil() async {
        let dir = TempDirectory()
        let store = ConfigStore(path: dir.joined("sbx-helper.json"))
        let model = AppModel(configStore: store)

        await model.load()

        #expect(model.configBanner == nil)
    }

    @Test
    func loadOfAMalformedConfigFileYieldsDefaultsAndABanner() async {
        let dir = TempDirectory()
        let path = dir.makeFile("sbx-helper.json", contents: "{ not valid json")
        let store = ConfigStore(path: path)
        let model = AppModel(configStore: store)

        await model.load()

        #expect(model.config.rootPath == defaultConfig().rootPath)
        #expect(model.configBanner != nil)
    }

    @Test
    func activeTabDefaultsToBuilderAndCanBeChanged() {
        let dir = TempDirectory()
        let store = ConfigStore(path: dir.joined("sbx-helper.json"))
        let model = AppModel(configStore: store)

        #expect(model.activeTab == .builder)
        model.activeTab = .sandboxes
        #expect(model.activeTab == .sandboxes)
    }

    @Test
    func updateMutatesTheStoredConfig() async {
        let dir = TempDirectory()
        let store = ConfigStore(path: dir.joined("sbx-helper.json"))
        let model = AppModel(configStore: store)
        await model.load()

        await model.update { $0.defaultTemplate = "custom:v1" }

        #expect((await store.current()).defaultTemplate == "custom:v1")
    }

    @Test
    func updateRefreshesThePublishedConfig() async {
        let dir = TempDirectory()
        let store = ConfigStore(path: dir.joined("sbx-helper.json"))
        let model = AppModel(configStore: store)
        await model.load()

        await model.update { $0.defaultTemplate = "custom:v1" }

        #expect(model.config.defaultTemplate == "custom:v1")
    }
}
