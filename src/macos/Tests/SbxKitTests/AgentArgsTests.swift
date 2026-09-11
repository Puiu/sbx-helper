// Ports src/electron/test/sandbox-commands.test.mjs (defaultAgentArgs,
// tokenizeArgs, validateAgentArgs describe blocks).
import Testing
@testable import SbxKit

@Suite("defaultAgentArgs")
struct DefaultAgentArgsTests {
    @Test("claude defaults to --model opusplan")
    func claudeDefault() {
        #expect(defaultAgentArgs("claude") == ["--model", "opusplan"])
    }

    @Test("opencode has no default args")
    func opencodeDefault() {
        #expect(defaultAgentArgs("opencode") == [])
    }

    @Test("an unknown agent has no default args")
    func unknownAgentDefault() {
        #expect(defaultAgentArgs("some-future-agent") == [])
    }
}

@Suite("tokenizeArgs")
struct TokenizeArgsTests {
    @Test("splits a simple space-separated string")
    func splitsSimpleString() {
        #expect(tokenizeArgs("--model opusplan") == ["--model", "opusplan"])
    }

    @Test("honors single-quoted values")
    func honorsSingleQuoted() {
        #expect(tokenizeArgs("--message 'hello world'") == ["--message", "hello world"])
    }

    @Test("honors double-quoted values")
    func honorsDoubleQuoted() {
        #expect(tokenizeArgs("--message \"hello world\"") == ["--message", "hello world"])
    }

    @Test("empty string tokenizes to an empty array")
    func emptyString() {
        #expect(tokenizeArgs("") == [])
    }

    @Test("whitespace-only string tokenizes to an empty array")
    func whitespaceOnlyString() {
        #expect(tokenizeArgs("   \t  ") == [])
    }

    @Test("collapses repeated whitespace between tokens")
    func collapsesRepeatedWhitespace() {
        #expect(tokenizeArgs("--model    opusplan") == ["--model", "opusplan"])
    }

    @Test("round-trips through formatCommand for a simple case")
    func roundTripsSimple() {
        let argv = tokenizeArgs("--model opusplan")
        #expect(tokenizeArgs(formatCommand(argv)) == argv)
    }

    @Test("round-trips through formatCommand when a value has a space")
    func roundTripsWithSpace() {
        let argv = tokenizeArgs("--message 'hello world'")
        #expect(tokenizeArgs(formatCommand(argv)) == argv)
    }

    // Regression: quotePosix escapes an embedded single quote as the POSIX
    // '\'' idiom (close quote, escaped literal quote, reopen quote). A
    // tokenizer that only understands whole-token '...'/"..." quoting can't
    // parse that back into one token — it splits at every embedded quote,
    // silently corrupting a persisted args string on every reload.
    @Test("round-trips through formatCommand when a value has an embedded single quote")
    func roundTripsWithEmbeddedSingleQuote() {
        let argv = ["--append-system-prompt", "don't stop"]
        let display = formatCommand(argv)
        #expect(display == "--append-system-prompt 'don'\\''t stop'")
        #expect(tokenizeArgs(display) == argv)
    }

    @Test("honors a backslash-escaped space outside quotes")
    func honorsBackslashEscapedSpace() {
        #expect(tokenizeArgs("a\\ b") == ["a b"])
    }

    @Test("concatenates adjacent quoted and unquoted runs into one token")
    func concatenatesAdjacentRuns() {
        #expect(tokenizeArgs("a\"b\"c") == ["abc"])
    }

    @Test("an unterminated quote does not throw — it just consumes to end of input")
    func unterminatedQuoteDoesNotThrow() {
        #expect(tokenizeArgs("--flag 'unterminated") == ["--flag", "unterminated"])
    }
}

@Suite("validateAgentArgs")
struct ValidateAgentArgsTests {
    @Test("nil for a normal args list")
    func nilForNormalList() {
        #expect(validateAgentArgs(["--model", "opusplan"]) == nil)
    }

    @Test("nil for an empty list")
    func nilForEmptyList() {
        #expect(validateAgentArgs([]) == nil)
    }

    @Test("rejects more than maxAgentArgTokens tokens")
    func rejectsTooManyTokens() {
        let tooMany = (0...maxAgentArgTokens).map { "t\($0)" }
        #expect(validateAgentArgs(tooMany) == .tooManyAgentArgTokens(max: maxAgentArgTokens))
    }

    @Test("accepts exactly maxAgentArgTokens tokens")
    func acceptsExactlyMaxTokens() {
        let justRight = (0..<maxAgentArgTokens).map { "t\($0)" }
        #expect(validateAgentArgs(justRight) == nil)
    }

    @Test("rejects a token longer than maxAgentArgLen")
    func rejectsTooLongToken() {
        #expect(validateAgentArgs([String(repeating: "a", count: maxAgentArgLen + 1)])
            == .agentArgTokenTooLong(max: maxAgentArgLen))
    }

    @Test("rejects an empty-string element")
    func rejectsEmptyStringElement() {
        #expect(validateAgentArgs(["ok", ""]) == .emptyAgentArgToken)
    }

    @Test("rejects a newline in a token")
    func rejectsNewline() {
        #expect(validateAgentArgs(["a\nb"]) == .agentArgControlCharacter)
    }

    @Test("rejects a NUL byte in a token")
    func rejectsNulByte() {
        #expect(validateAgentArgs(["a\0b"]) == .agentArgControlCharacter)
    }

    @Test("rejects an ESC control character in a token — narrower checks used to miss this")
    func rejectsEscCharacter() {
        #expect(validateAgentArgs(["a\u{1b}b"]) == .agentArgControlCharacter)
    }
}
