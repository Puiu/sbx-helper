// Cross-checks buildCommand against golden output from the real
// src/electron/public/shared/command.mjs (see Support/ParityCorpus.swift).
import Testing
@testable import SbxKit

@Suite("buildCommand parity with the Electron app")
struct ParityCorpusTests {
    @Test("matches the real command.mjs byte-for-byte", arguments: ParityCorpus.commandCases)
    func matchesElectronOutput(_ c: ParityCase) throws {
        let (args, display) = try buildCommand(c.selection)
        #expect(args == c.expectedArgs)
        #expect(display == c.expectedDisplay)
    }
}
