import Testing
import Foundation
@testable import SbxServices
import SbxKit

@Suite("ConfigStore")
struct ConfigStoreTests {
    func tempConfigPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sbx-helper-config-test-\(UUID().uuidString).json").path
    }

    @Test("creates and loads defaults when the file doesn't exist yet")
    func createsDefaultsWhenMissing() async {
        let path = tempConfigPath()
        let store = ConfigStore(path: path)
        let config = await store.current()
        #expect(config.agent == "claude")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("update() is reflected by current() immediately, before any disk write")
    func updateIsImmediatelyVisible() async {
        let store = ConfigStore(path: tempConfigPath())
        await store.update { $0.defaultTemplate = "changed:v1" }
        let config = await store.current()
        #expect(config.defaultTemplate == "changed:v1")
    }

    @Test("rapid updates are coalesced into a single debounced disk write")
    func debouncesRapidUpdates() async throws {
        let path = tempConfigPath()
        let store = ConfigStore(path: path, debounceInterval: .milliseconds(150))
        await store.update { $0.agent = "one" }
        await store.update { $0.agent = "two" }
        await store.update { $0.agent = "three" }

        // Well within the debounce window, "three" should NOT be on disk yet
        // — proving the three updates were coalesced into one delayed write,
        // not applied synchronously per update(). A test that only polls for
        // the eventual final value (below) would pass identically even if
        // debouncing were removed entirely and every update() wrote at once.
        try await Task.sleep(for: .milliseconds(30))
        #expect(loadConfig(path).config.agent != "three")

        // Poll with a generous bound instead of a single fixed sleep — under
        // heavy parallel test-suite load, a scheduler delay can easily push
        // the debounced write past any one fixed wait, which isn't a real
        // bug, just wall-clock contention.
        var onDisk = loadConfig(path).config
        for _ in 0..<40 where onDisk.agent != "three" {
            try await Task.sleep(for: .milliseconds(50))
            onDisk = loadConfig(path).config
        }
        #expect(onDisk.agent == "three")
    }

    @Test("flush() writes immediately without waiting for the debounce interval")
    func flushWritesImmediately() async {
        let path = tempConfigPath()
        let store = ConfigStore(path: path, debounceInterval: .seconds(30))
        await store.update { $0.agent = "flushed" }
        await store.flush()
        let onDisk = loadConfig(path).config
        #expect(onDisk.agent == "flushed")
    }

    @Test("surfaces loadError from a malformed existing file")
    func surfacesLoadDiagnostics() async throws {
        let path = tempConfigPath()
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path)
        let error = await store.loadError
        #expect(error != nil)
        #expect(await store.isDegraded == true)
    }

    @Test("surfaces hadUnrecoverableFieldShape when a field's raw JSON shape can't even be attempted")
    func surfacesUnrecoverableFieldShape() async throws {
        let path = tempConfigPath()
        // "presets" as a string (not null, not an array) — countDroppedPresets
        // can't even attempt an element-level decode against this shape.
        try #"{"presets": "oops"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path)
        #expect(await store.hadUnrecoverableFieldShape == true)
        #expect(await store.isDegraded == true)
    }

    @Test("isDegraded is false for a clean, freshly-created config")
    func isDegradedFalseWhenClean() async throws {
        let store = ConfigStore(path: tempConfigPath())
        #expect(await store.isDegraded == false)
    }
}
