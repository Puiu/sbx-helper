import Foundation
import Testing
import SbxKit
import SbxServices
@testable import SbxAppCore

/// Phase 8's "sbx not found" banner state: `AppModel` tracks whether the
/// `sbx` binary resolves, independently of the config-health banner, so the
/// UI can point at Settings instead of rendering an empty template list.
@MainActor
struct SbxAvailabilityTests {
    private actor Probe {
        var value: Bool
        init(_ value: Bool) { self.value = value }
        func set(_ newValue: Bool) { value = newValue }
    }

    private static func model(probe: Probe, in dir: TempDirectory) -> AppModel {
        let store = ConfigStore(path: dir.joined("sbx-helper.json"))
        return AppModel(configStore: store, sbxProbe: { await probe.value })
    }

    @Test
    func availabilityStartsUnknownWithNoBanner() {
        let dir = TempDirectory()
        let model = Self.model(probe: Probe(true), in: dir)

        #expect(model.sbxAvailable == nil)
        #expect(model.sbxBanner == nil)
    }

    @Test
    func failingProbeYieldsTheSettingsBanner() async {
        let dir = TempDirectory()
        let model = Self.model(probe: Probe(false), in: dir)

        await model.checkSbxAvailability()

        #expect(model.sbxAvailable == false)
        #expect(model.sbxBanner == "sbx not found — set its location in Settings.")
    }

    @Test
    func passingProbeLeavesNoBanner() async {
        let dir = TempDirectory()
        let model = Self.model(probe: Probe(true), in: dir)

        await model.checkSbxAvailability()

        #expect(model.sbxAvailable == true)
        #expect(model.sbxBanner == nil)
    }

    @Test
    func recheckPicksUpAChangedProbe() async {
        let dir = TempDirectory()
        let probe = Probe(false)
        let model = Self.model(probe: probe, in: dir)
        await model.checkSbxAvailability()
        #expect(model.sbxBanner != nil)

        await probe.set(true)
        await model.checkSbxAvailability()

        #expect(model.sbxAvailable == true)
        #expect(model.sbxBanner == nil)
    }
}
