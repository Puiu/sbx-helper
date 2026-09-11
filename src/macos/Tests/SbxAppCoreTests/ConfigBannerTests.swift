import Testing
@testable import SbxAppCore

struct ConfigBannerTests {
    @Test
    func healthyConfigHasNoBanner() {
        let message = configBannerMessage(
            loadError: nil, droppedPresets: 0, hadUnrecoverableFieldShape: false
        )
        #expect(message == nil)
    }

    @Test
    func loadErrorOnlyProducesAMessageMentioningIt() {
        let message = configBannerMessage(
            loadError: "not valid JSON", droppedPresets: 0, hadUnrecoverableFieldShape: false
        )
        #expect(message?.contains("not valid JSON") == true)
    }

    @Test
    func droppedPresetsOnlyProducesAMessageMentioningTheCount() {
        let message = configBannerMessage(
            loadError: nil, droppedPresets: 3, hadUnrecoverableFieldShape: false
        )
        #expect(message?.contains("3") == true)
    }

    @Test
    func bothLoadErrorAndDroppedPresetsProduceOneCombinedMessage() {
        let message = configBannerMessage(
            loadError: "not valid JSON", droppedPresets: 2, hadUnrecoverableFieldShape: false
        )
        #expect(message?.contains("not valid JSON") == true)
        #expect(message?.contains("2") == true)
    }

    @Test
    func unrecoverableFieldShapeAloneProducesAMessage() {
        let message = configBannerMessage(
            loadError: nil, droppedPresets: 0, hadUnrecoverableFieldShape: true
        )
        #expect(message != nil)
    }

    @Test
    func exactlyOneDroppedPresetAgreesInNumber() {
        let message = configBannerMessage(
            loadError: nil, droppedPresets: 1, hadUnrecoverableFieldShape: false
        )
        #expect(message == "1 preset was dropped as malformed.")
    }
}
