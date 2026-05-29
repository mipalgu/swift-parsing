import Testing

import ParsingCore
@testable import Parsing

@Suite("Regex -> matcher lowering")
struct RegexToMatcherTests {
    @Test("Adjacent characters fold into one literal")
    func literal() {
        #expect(RegexLowering.matcher(fromRegex: "true") == .literal("true"))
    }

    @Test("Character classes and ranges")
    func classes() {
        #expect(RegexLowering.matcher(fromRegex: "[0-9]") == .scalarRange(0x30 ... 0x39))
        #expect(RegexLowering.matcher(fromRegex: "[^\"]") == .negated(.literal("\"")))
        #expect(RegexLowering.matcher(fromRegex: #"\d"#) == .builtin(.digit))
        #expect(RegexLowering.matcher(fromRegex: #"\s"#) == .builtin(.whitespace))
    }

    @Test("Alternation and grouping")
    func alternation() {
        #expect(RegexLowering.matcher(fromRegex: "a|b") == .alternation([.literal("a"), .literal("b")]))
        #expect(RegexLowering.matcher(fromRegex: "(?:ab)") == .literal("ab"))
    }

    @Test("Quantifiers")
    func quantifiers() {
        #expect(RegexLowering.matcher(fromRegex: "a*") == .repeated(min: 0, max: nil, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a+") == .repeated(min: 1, max: nil, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a?") == .repeated(min: 0, max: 1, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a{2,3}") == .repeated(min: 2, max: 3, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a{2,}") == .repeated(min: 2, max: nil, .literal("a")))
    }

    @Test("Unparseable input falls back to a literal")
    func fallback() {
        #expect(RegexLowering.matcher(fromRegex: "(") == .literal("("))
    }
}

@Suite("Matcher -> regex rendering")
struct MatcherToRegexTests {
    @Test("Leaves render to a regex string")
    func leaves() {
        #expect(RegexLowering.regexString(from: .literal("a.b")) == "a\\.b")
        #expect(RegexLowering.regexString(from: .scalarRange(0x30 ... 0x39)) == "[0-9]")
        #expect(RegexLowering.regexString(from: .builtin(.digit)) == "\\d")
        #expect(RegexLowering.regexString(from: .negated(.literal("\""))) == "[^\"]")
    }
}

@Suite("Regex round-trip")
struct RegexRoundTripTests {
    @Test("Supported matchers survive matcher -> regex -> matcher", arguments: [
        TokenMatcher.literal("true"),
        .scalarRange(0x31 ... 0x39),
        .builtin(.digit),
        .negated(.literal("\"")),
        .repeated(min: 1, max: nil, .negated(.literal("\""))),
        .alternation([.literal("e"), .literal("E")]),
        .repeated(min: 0, max: 1, .literal("-")),
    ])
    func roundTrip(_ matcher: TokenMatcher) {
        let regex = RegexLowering.regexString(from: matcher)
        #expect(RegexLowering.matcher(fromRegex: regex) == matcher)
    }
}
