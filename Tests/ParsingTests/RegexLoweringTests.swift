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

    @Test("Lookahead assertions lower to the lookahead matcher")
    func lookahead() {
        #expect(RegexLowering.matcher(fromRegex: "(?=ab)") == .lookahead(negate: false, .literal("ab")))
        #expect(RegexLowering.matcher(fromRegex: #"(?!\d)"#) == .lookahead(negate: true, .builtin(.digit)))
    }

    @Test("Quantifiers")
    func quantifiers() {
        #expect(RegexLowering.matcher(fromRegex: "a*") == .repeated(min: 0, max: nil, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a+") == .repeated(min: 1, max: nil, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a?") == .repeated(min: 0, max: 1, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a{2,3}") == .repeated(min: 2, max: 3, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a{2,}") == .repeated(min: 2, max: nil, .literal("a")))
    }

    @Test("Brace quantifiers")
    func braceQuantifiers() {
        #expect(RegexLowering.matcher(fromRegex: "a{3}") == .repeated(min: 3, max: 3, .literal("a")))
        #expect(RegexLowering.matcher(fromRegex: "a{2,}") == .repeated(min: 2, max: nil, .literal("a")))
    }

    @Test("Multi-member and negated character classes")
    func characterClasses() {
        #expect(RegexLowering.matcher(fromRegex: "[abc]")
            == .alternation([.literal("a"), .literal("b"), .literal("c")]))
        #expect(RegexLowering.matcher(fromRegex: "[^ab]")
            == .negated(.alternation([.literal("a"), .literal("b")])))
    }

    @Test("Escaped metacharacter becomes a literal")
    func escapedLiteral() {
        #expect(RegexLowering.matcher(fromRegex: #"\."#) == .literal("."))
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
        #expect(RegexLowering.regexString(from: .anyElement) == ".")
        #expect(RegexLowering.regexString(from: .scalarRange(0x30 ... 0x39)) == "[0-9]")
        #expect(RegexLowering.regexString(from: .builtin(.digit)) == "\\d")
        #expect(RegexLowering.regexString(from: .builtin(.whitespace)) == "\\s")
        #expect(RegexLowering.regexString(from: .builtin(.hexDigit)) == "[0-9A-Fa-f]")
        #expect(RegexLowering.regexString(from: .builtin(.letter)) == "[A-Za-z]")
        #expect(RegexLowering.regexString(from: .negated(.literal("\""))) == "[^\"]")
        #expect(RegexLowering.regexString(from: .negated(.scalarRange(0x30 ... 0x39))) == "[^0-9]")
        #expect(RegexLowering.regexString(from: .negated(.alternation([.literal("a"), .literal("b")]))) == "[^ab]")
    }

    @Test("Composite matchers render with grouping and quantifiers")
    func composites() {
        #expect(RegexLowering.regexString(from: .sequence([.literal("a"), .literal("b")])) == "ab")
        #expect(RegexLowering.regexString(from: .alternation([.literal("a"), .literal("b")])) == "(?:a|b)")
        #expect(RegexLowering.regexString(from: .repeated(min: 2, max: 3, .literal("a"))) == "a{2,3}")
        #expect(RegexLowering.regexString(from: .repeated(min: 2, max: nil, .literal("a"))) == "a{2,}")
        #expect(RegexLowering.regexString(from: .repeated(min: 3, max: 3, .literal("a"))) == "a{3}")
        // A multi-character literal under a quantifier is grouped.
        #expect(RegexLowering.regexString(from: .repeated(min: 0, max: nil, .literal("ab"))) == "(?:ab)*")
    }

    @Test("Zero-width lookahead renders as a regex assertion")
    func lookahead() {
        #expect(RegexLowering.regexString(from: .lookahead(negate: false, .literal("a"))) == "(?=a)")
        #expect(RegexLowering.regexString(from: .lookahead(negate: true, .builtin(.letter))) == "(?![A-Za-z])")
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
        .lookahead(negate: false, .literal("a")),
        .lookahead(negate: true, .builtin(.digit)),
        .sequence([.lookahead(negate: true, .builtin(.digit)), .literal("x")]),
    ])
    func roundTrip(_ matcher: TokenMatcher) {
        let regex = RegexLowering.regexString(from: matcher)
        #expect(RegexLowering.matcher(fromRegex: regex) == matcher)
    }
}
