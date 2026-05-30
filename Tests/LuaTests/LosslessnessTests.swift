import ParsingCore
import ParsingDSL
import RecursiveDescent
import Testing

/// Losslessness, trivia, and escape-decoding coverage for the structural Lua grammar.
///
/// These prove that comment-bearing and whitespace-heavy inputs round-trip exactly, that comments are
/// captured as trivia rather than structural nodes (so a comment does not change the S-expression), and
/// that every string form and escape sequence is preserved verbatim in the tree's source reconstruction.
@Suite("Lua losslessness and trivia")
struct LuaLosslessnessTests {
    /// A reusable recursive-descent engine over the structural grammar.
    private static let engine: UTF8Parser = {
        try! UTF8Parser(grammar: LuaGrammar.chunk())
    }()

    /// Parses an input and returns the result.
    private func parse(_ input: String) -> ParseResult { Self.engine.parse(Source(input)) }

    /// The content text (token text, excluding trivia) of a node.
    private func text(_ node: Syntax) -> String {
        var out = ""
        func walk(_ syntax: Syntax) {
            switch syntax.green.payload {
            case .token(let value, _, _): out += value
            case .node(let children): for child in children { walk(Syntax(child.node)) }
            }
        }
        walk(node)
        return out
    }

    /// The first `string` node's content text (no trivia) in a parse result, if any.
    private func firstString(_ result: ParseResult) -> String? {
        func search(_ node: Syntax) -> String? {
            if node.kind.name == "string" { return text(node) }
            for child in node.children {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(result.tree)
    }

    @Test(
        "Comment-bearing and whitespace-heavy inputs round-trip exactly",
        arguments: [
            "-- a line comment\nx = 1\n",
            "x = 1 -- trailing\n",
            "x = --[[ inline ]] 1",
            "--[[ leading ]] x = 1",
            "  \t local   x   =   1  \n\n",
            "--[==[ level two ]==]\nx = 1",
            "-- one\n-- two\n-- three\nx = 1",
        ])
    func commentsRoundTrip(_ input: String) {
        let result = parse(input)
        #expect(result.tree.green.reconstructedText == input)
        #expect(!result.hasErrors, "should parse: \(input.debugDescription)")
    }

    @Test("A line comment is trivia: it does not change the S-expression")
    func lineCommentIsTrivia() {
        let withComment = parse("--c\nx = 1")
        let withoutComment = parse("x = 1")
        #expect(withComment.sExpression() == withoutComment.sExpression())
        #expect(withComment.tree.green.reconstructedText == "--c\nx = 1")
    }

    @Test("A block comment is trivia: it does not change the S-expression")
    func blockCommentIsTrivia() {
        let withComment = parse("x = --[[ b ]] 1")
        let withoutComment = parse("x = 1")
        #expect(withComment.sExpression() == withoutComment.sExpression())
        #expect(withComment.tree.green.reconstructedText == "x = --[[ b ]] 1")
    }

    @Test("Whitespace runs are trivia: they do not change the S-expression")
    func whitespaceIsTrivia() {
        let spaced = parse("  x   =   1  ")
        let tight = parse("x=1")
        #expect(spaced.sExpression() == tight.sExpression())
    }

    @Test(
        "Every string form and escape sequence round-trips verbatim in the string node",
        arguments: [
            #"local s = "a\tb\n""#,
            #"local s = '\u{1F1E6}'"#,
            #"local s = "\x41\65""#,
            #"local s = "\a\b\f\v\r\\\"\'""#,
            #"local s = "line\zcontinued""#,
            "local s = [[raw\\nnot-escaped]]",
            "local s = [=[ level one ]=]",
            "local s = [==[ level two ]==]",
            #"local s = "café \u{2764}""#,
        ])
    func stringEscapesRoundTrip(_ input: String) {
        let result = parse(input)
        #expect(!result.hasErrors, "should parse: \(input.debugDescription)")
        #expect(result.tree.green.reconstructedText == input)
        // The string node preserves the literal exactly, including its delimiters and escapes.
        let literal = String(input.dropFirst("local s = ".count))
        #expect(firstString(result) == literal, "string node text for: \(input.debugDescription)")
    }

    @Test(
        "Numerals of every form parse and round-trip",
        arguments: [
            "local n = 100", "local n = 0xFF", "local n = 3.14", "local n = 1e10",
            "local n = 0x1p4", "local n = 0x1.8p1", "local n = .5", "local n = 1E-3",
        ])
    func numeralsRoundTrip(_ input: String) {
        let result = parse(input)
        #expect(!result.hasErrors, "should parse: \(input.debugDescription)")
        #expect(result.tree.green.reconstructedText == input)
    }
}
