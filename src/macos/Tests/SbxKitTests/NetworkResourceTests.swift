// Ports src/electron/test/sandbox-commands.test.mjs (isValidNetworkResource,
// parseResourceList describe blocks) — plus formatPort, which lives on Port
// (see SbxModelsTests.swift for that; sandbox-commands.test.mjs's formatPort
// tests are ported there instead, alongside the rest of Port).
import Testing
@testable import SbxKit

@Suite("isValidNetworkResource")
struct IsValidNetworkResourceTests {
    @Test(
        "accepts valid resource strings",
        arguments: [
            "example.com", "*.example.com", "**.example.com", "**", "example.com:443", "api.example.com:8080",
            "crl*.digicert.com:80", // real sbx daemon data: a wildcard embedded mid-label, not just leading
        ]
    )
    func acceptsValid(_ s: String) {
        #expect(isValidNetworkResource(s))
    }

    @Test(
        "rejects invalid resource strings",
        arguments: [
            "a b", "a;b", "--flag", "", "   ", "a\nb", "a\tb",
            "example.com:0", "example.com:99999", // out of the valid TCP port range
        ]
    )
    func rejectsInvalid(_ s: String) {
        #expect(!isValidNetworkResource(s))
    }

    @Test("accepts the port range boundaries 1 and 65535")
    func acceptsPortRangeBoundaries() {
        #expect(isValidNetworkResource("example.com:1"))
        #expect(isValidNetworkResource("example.com:65535"))
    }
}

@Suite("parseResourceList")
struct ParseResourceListTests {
    @Test("splits on commas")
    func splitsOnCommas() {
        #expect(parseResourceList("a.com,b.com") == ["a.com", "b.com"])
    }

    @Test("splits on whitespace")
    func splitsOnWhitespace() {
        #expect(parseResourceList("a.com b.com") == ["a.com", "b.com"])
    }

    @Test("trims and drops empty entries")
    func trimsAndDropsEmpty() {
        #expect(parseResourceList(" a.com , , b.com ") == ["a.com", "b.com"])
    }

    @Test("empty string yields an empty array")
    func emptyStringYieldsEmpty() {
        #expect(parseResourceList("") == [])
    }
}

@Suite("maxResourcesPerRequest")
struct MaxResourcesPerRequestTests {
    @Test("is a positive number both call sites can share")
    func isPositive() {
        #expect(maxResourcesPerRequest > 0)
    }
}
