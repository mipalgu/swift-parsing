import Testing

@testable import ParsingCore

@Suite("SourceSpan")
struct SourceSpanTests {
    @Test("Basic geometry")
    func geometry() {
        let span = SourceSpan(start: 3, length: 4)
        #expect(span.start == 3)
        #expect(span.length == 4)
        #expect(span.end == 7)
        #expect(span.range == 3 ..< 7)
        #expect(!span.isEmpty)
        #expect(span.description == "[3..<7)")
    }

    @Test("Empty span")
    func empty() {
        let span = SourceSpan.empty(at: 5)
        #expect(span.isEmpty)
        #expect(span.start == 5)
        #expect(span.end == 5)
    }

    @Test("Union spans the extremes")
    func union() {
        let a = SourceSpan(start: 2, length: 3) // [2, 5)
        let b = SourceSpan(start: 8, length: 2) // [8, 10)
        let u = a.union(b)
        #expect(u.start == 2)
        #expect(u.end == 10)
        #expect(b.union(a) == u)
    }

    @Test("Equality and hashing")
    func equalityHashing() {
        let a = SourceSpan(start: 1, length: 2)
        #expect(a == SourceSpan(start: 1, length: 2))
        #expect(a != SourceSpan(start: 1, length: 3))
        #expect(Set([a, SourceSpan(start: 1, length: 2)]).count == 1)
    }
}

@Suite("Source")
struct SourceTests {
    @Test("UTF-8 bytes and slicing")
    func bytesAndSlicing() {
        let source = Source("héllo")
        // 'é' is two UTF-8 bytes, so byte count exceeds character count.
        #expect(source.count == 6)
        #expect(source.text == "héllo")
        let span = SourceSpan(start: 0, length: 3) // "hé"
        #expect(source.text(of: span) == "hé")
    }

    @Test("Empty span yields empty text")
    func emptySpan() {
        let source = Source("abc")
        #expect(source.text(of: .empty(at: 1)) == "")
    }

    @Test("count, equality and hashing")
    func countEqualityHashing() {
        let a = Source("abc")
        #expect(a.count == 3)
        #expect(a == Source("abc"))
        #expect(a != Source("abd"))
        #expect(Set([a, Source("abc")]).count == 1)
    }
}

@Suite("Diagnostic")
struct DiagnosticTests {
    @Test("Error convenience")
    func errorConvenience() {
        let span = SourceSpan(start: 0, length: 1)
        let diag = Diagnostic.error("unexpected token", at: span)
        #expect(diag.severity == .error)
        #expect(diag.message == "unexpected token")
        #expect(diag.span == span)
        #expect(diag.description.contains("unexpected token"))
    }

    @Test("Severities are distinct")
    func severities() {
        let span = SourceSpan.empty(at: 0)
        let warn = Diagnostic(severity: .warning, message: "w", span: span)
        let info = Diagnostic(severity: .info, message: "i", span: span)
        #expect(warn.severity != info.severity)
    }
}

@Suite("Green and red tree")
struct TreeTests {
    /// Builds: (object (pair key: (string) value: (number)))  for  `{ "a": 1 }`.
    private func sampleTree() -> GreenNode {
        let openBrace = GreenNode.token(SyntaxKind("{", isNamed: false), text: "{", trailingTrivia: " ")
        let key = GreenNode.node(SyntaxKind("string"), children: [
            .init(node: .token(SyntaxKind("\"", isNamed: false), text: "\"")),
            .init(node: .token(SyntaxKind("string_content"), text: "a")),
            .init(node: .token(SyntaxKind("\"", isNamed: false), text: "\"")),
        ])
        let colon = GreenNode.token(SyntaxKind(":", isNamed: false), text: ":", trailingTrivia: " ")
        // `number` is a named leaf node wrapping an anonymous digit token, so it renders as `(number)`.
        let value = GreenNode.node(SyntaxKind("number"), children: [
            .init(node: .token(SyntaxKind("1", isNamed: false), text: "1", trailingTrivia: " ")),
        ])
        let pair = GreenNode.node(SyntaxKind("pair"), children: [
            .init(field: "key", node: key),
            .init(node: colon),
            .init(field: "value", node: value),
        ])
        let closeBrace = GreenNode.token(SyntaxKind("}", isNamed: false), text: "}")
        return GreenNode.node(SyntaxKind("object"), children: [
            .init(node: openBrace),
            .init(node: pair),
            .init(node: closeBrace),
        ])
    }

    @Test("Token width includes trivia")
    func tokenWidth() {
        let tok = GreenNode.token(SyntaxKind("x"), text: "ab", leadingTrivia: " ", trailingTrivia: "  ")
        #expect(tok.byteWidth == 5)
        #expect(tok.tokenText == "ab")
        #expect(tok.isToken)
        #expect(tok.children.isEmpty)
    }

    @Test("Node width sums children")
    func nodeWidth() {
        let green = sampleTree()
        #expect(!green.isToken)
        // "{ " + "\"a\"" + ": " + "1 " + "}" = 2 + 3 + 2 + 2 + 1 = 10
        #expect(green.byteWidth == 10)
    }

    @Test("Missing token is zero-width and flagged")
    func missing() {
        let m = GreenNode.missingToken(SyntaxKind("}", isNamed: false))
        #expect(m.isMissing)
        #expect(m.byteWidth == 0)
        #expect(Syntax(m).sExpression() == "") // anonymous, omitted
        let namedMissing = GreenNode.missingToken(SyntaxKind("value"))
        #expect(Syntax(namedMissing).sExpression() == "(MISSING value)")
    }

    @Test("Red layer computes absolute offsets")
    func redOffsets() {
        let root = Syntax(sampleTree())
        #expect(root.offset == 0)
        #expect(root.span == SourceSpan(start: 0, length: 10))
        // First named descendant is the pair, after "{ " (2 bytes).
        let pair = root.children.first { $0.kind.name == "pair" }
        #expect(pair?.offset == 2)
        let value = pair?.children.first { $0.field == "value" }
        #expect(value?.field == "value")
    }

    @Test("Canonical S-expression omits anonymous tokens and shows fields")
    func sExpression() {
        let root = Syntax(sampleTree())
        #expect(root.sExpression() == "(object (pair key: (string (string_content)) value: (number)))")
    }

    @Test("Error node carries error kind")
    func errorNode() {
        let err = GreenNode.errorNode(children: [
            .init(node: .token(SyntaxKind("junk"), text: "?")),
        ])
        #expect(err.kind == .error)
        // The ERROR node shows its named children (here a named `junk` token).
        #expect(Syntax(err).sExpression() == "(ERROR (junk))")
    }
}

@Suite("Grammar IR")
struct GrammarIRTests {
    @Test("Literal helper builds anonymous token rule")
    func literalHelper() {
        let rule = Rule.literal("{")
        guard case let .token(name, matcher, isNamed) = rule else {
            Issue.record("expected token rule")
            return
        }
        #expect(name == "{")
        #expect(matcher == .literal("{"))
        #expect(!isNamed)
    }

    @Test("Grammar stores rules and default extras")
    func grammar() {
        let g = Grammar(
            name: "tiny",
            startRule: "s",
            rules: ["s": .reference("a"), "a": .literal("a")]
        )
        #expect(g.name == "tiny")
        #expect(g.startRule == "s")
        #expect(g.rules.count == 2)
        #expect(g.extras == [.builtin(.whitespace)])
    }
}

@Suite("Lookahead matcher")
struct LookaheadMatcherTests {
    @Test("Polarity is recorded on the case")
    func polarity() {
        let positive = TokenMatcher.lookahead(negate: false, .literal("x"))
        let negative = TokenMatcher.lookahead(negate: true, .literal("x"))
        guard case let .lookahead(positiveNegate, positiveInner) = positive else {
            Issue.record("expected a lookahead matcher")
            return
        }
        #expect(!positiveNegate)
        #expect(positiveInner == .literal("x"))
        guard case let .lookahead(negativeNegate, _) = negative else {
            Issue.record("expected a lookahead matcher")
            return
        }
        #expect(negativeNegate)
    }

    @Test("Equality and hashing distinguish polarity and inner matcher")
    func equalityHashing() {
        let a = TokenMatcher.lookahead(negate: true, .builtin(.letter))
        #expect(a == .lookahead(negate: true, .builtin(.letter)))
        #expect(a != .lookahead(negate: false, .builtin(.letter)))
        #expect(a != .lookahead(negate: true, .builtin(.digit)))
        #expect(Set([a, .lookahead(negate: true, .builtin(.letter))]).count == 1)
    }

    @Test("Lookahead nests other matchers, including itself")
    func nesting() {
        let nested = TokenMatcher.lookahead(
            negate: false, .sequence([.literal("a"), .lookahead(negate: true, .literal("b"))]))
        guard case .lookahead(false, .sequence(let parts)) = nested, parts.count == 2 else {
            Issue.record("expected a nested lookahead structure")
            return
        }
        #expect(parts[1] == .lookahead(negate: true, .literal("b")))
    }
}

@Suite("Engine capabilities")
struct CapabilityTests {
    @Test("Option set composition")
    func optionSet() {
        let caps: EngineCapabilities = [.lossless, .errorRecovering]
        #expect(caps.contains(.lossless))
        #expect(caps.contains(.errorRecovering))
        #expect(!caps.contains(.incremental))
    }
}

@Suite("ParserElement")
struct ParserElementTests {
    @Test("UTF-8 code units: scalar value, width and ASCII classes")
    func bytes() {
        let zero: UInt8 = 0x30, f: UInt8 = 0x66, space: UInt8 = 0x20, z: UInt8 = 0x7A
        #expect(zero.scalarValue == 0x30)
        #expect(zero.utf8Width == 1)
        #expect(zero.isASCIIDigit)
        #expect(space.isASCIIWhitespace)
        #expect(f.isASCIIHexDigit)
        #expect(z.isASCIILetter)
        #expect(!z.isASCIIDigit)
        #expect(!(0x2B as UInt8).isASCIIHexDigit) // '+'
    }

    @Test("Unicode scalars: width by code-point range and classification")
    func scalars() {
        #expect(Unicode.Scalar("a").utf8Width == 1)
        #expect(Unicode.Scalar("é").utf8Width == 2)
        #expect(Unicode.Scalar("€").utf8Width == 3)
        #expect(Unicode.Scalar("𝄞").utf8Width == 4)
        #expect(Unicode.Scalar("7").isASCIIDigit)
        #expect(Unicode.Scalar("\t").isASCIIWhitespace)
        #expect(Unicode.Scalar("A").isASCIIHexDigit)
        #expect(!Unicode.Scalar("é").isASCIILetter) // non-ASCII letter is not an ASCII letter
    }

    @Test("Characters: first-scalar value and total UTF-8 width")
    func characters() {
        #expect(Character("a").scalarValue == 0x61)
        #expect(Character("a").utf8Width == 1)
        #expect(Character("é").utf8Width == 2)
        // A regional-indicator flag is one grapheme of two 4-byte scalars.
        #expect(Character("🇦🇺").utf8Width == 8)
        #expect(Character("5").isASCIIDigit)
    }
}

@Suite("ParserInput")
struct ParserInputTests {
    @Test("Granularity names")
    func names() {
        #expect(Substring.UTF8View.granularityName == "utf8")
        #expect(Substring.UnicodeScalarView.granularityName == "scalar")
        #expect(Substring.granularityName == "grapheme")
    }

    @Test("UTF-8 view: make, elements and text")
    func utf8View() {
        let input = Substring.UTF8View.make(from: "ab")
        #expect(Array(input) == [0x61, 0x62])
        #expect(Substring.UTF8View.elements(of: "é") == Array("é".utf8))
        #expect(Substring.UTF8View.text(of: input) == "ab")
    }

    @Test("Scalar view: make, elements and text")
    func scalarView() {
        let input = Substring.UnicodeScalarView.make(from: "aé")
        #expect(Substring.UnicodeScalarView.elements(of: "aé") == Array("aé".unicodeScalars))
        #expect(Substring.UnicodeScalarView.text(of: input) == "aé")
    }

    @Test("Grapheme view: make, elements and text")
    func graphemeView() {
        let input = Substring.make(from: "a🇦🇺")
        #expect(Substring.elements(of: "a🇦🇺") == Array("a🇦🇺"))
        #expect(Substring.text(of: input) == "a🇦🇺")
    }
}

@Suite("Accessors")
struct AccessorTests {
    @Test("tokenText is nil for internal nodes")
    func tokenTextNil() {
        let node = GreenNode.node(SyntaxKind("n"), children: [])
        #expect(node.tokenText == nil)
        let tok = GreenNode.token(SyntaxKind("t"), text: "x")
        #expect(tok.tokenText == "x")
    }

    @Test("Syntax forwards isMissing, isToken and kind")
    func syntaxForwarding() {
        let missing = Syntax(.missingToken(SyntaxKind("v")))
        #expect(missing.isMissing)
        #expect(missing.isToken)
        #expect(missing.kind == SyntaxKind("v"))
        let node = Syntax(.node(SyntaxKind("n"), children: []))
        #expect(!node.isToken)
        #expect(!node.isMissing)
    }

    @Test("SyntaxKind description is its name")
    func kindDescription() {
        #expect(SyntaxKind("object").description == "object")
        #expect(SyntaxKind.error.description == "ERROR")
    }
}
