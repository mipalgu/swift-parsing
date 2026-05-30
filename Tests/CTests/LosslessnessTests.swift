import ParsingCore
import ParsingDSL
import RecursiveDescent
import Testing

/// Losslessness, trivia, and escape-decoding coverage for the structural C grammar.
///
/// These prove that comment-bearing and whitespace-heavy inputs round-trip exactly, that comments are
/// captured as trivia rather than structural nodes (so a comment does not change the S-expression), and
/// that every literal form and escape sequence is preserved verbatim in the tree's source reconstruction.
@Suite("C losslessness and trivia")
struct CLosslessnessTests {
    /// A reusable recursive-descent engine over the structural grammar.
    private static let engine: UTF8Parser = {
        try! UTF8Parser(grammar: CGrammar.translationUnit())
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

    /// The first node of a given kind in a parse result, if any.
    private func firstNode(_ kind: String, in result: ParseResult) -> String? {
        func search(_ node: Syntax) -> String? {
            if node.kind.name == kind { return text(node) }
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
            "// a line comment\nint x = 1;\n",
            "int x = 1; // trailing\n",
            "int x = /* inline */ 1;",
            "/* leading */ int x = 1;",
            "  \t int   x   =   1 ;  \n\n",
            "/* multi\n   line\n   comment */\nint x = 1;",
            "// one\n// two\n// three\nint x = 1;",
            "int f(void) {\n    // body comment\n    return 0;\n}",
        ])
    func commentsRoundTrip(_ input: String) {
        let result = parse(input)
        #expect(result.tree.green.reconstructedText == input)
        #expect(!result.hasErrors, "should parse: \(input.debugDescription)")
    }

    @Test("A line comment is trivia: it does not change the S-expression")
    func lineCommentIsTrivia() {
        let withComment = parse("//c\nint x = 1;")
        let withoutComment = parse("int x = 1;")
        #expect(withComment.sExpression() == withoutComment.sExpression())
        #expect(withComment.tree.green.reconstructedText == "//c\nint x = 1;")
    }

    @Test("A block comment is trivia: it does not change the S-expression")
    func blockCommentIsTrivia() {
        let withComment = parse("int x = /* b */ 1;")
        let withoutComment = parse("int x = 1;")
        #expect(withComment.sExpression() == withoutComment.sExpression())
        #expect(withComment.tree.green.reconstructedText == "int x = /* b */ 1;")
    }

    @Test("Whitespace runs are trivia: they do not change the S-expression")
    func whitespaceIsTrivia() {
        let spaced = parse("int   x   =   1 ;")
        let tight = parse("int x=1;")
        #expect(spaced.sExpression() == tight.sExpression())
    }

    @Test(
        "Every string-literal escape sequence round-trips verbatim in the string node",
        arguments: [
            #"char *s = "a\tb\n";"#,
            #"char *s = "q\"q\\q";"#,
            #"char *s = "\x41\102";"#,
            #"char *s = "\a\b\f\v\r\0";"#,
            #"char *s = "tab\there";"#,
            #"char *s = "café \x21";"#,
        ])
    func stringEscapesRoundTrip(_ input: String) {
        let result = parse(input)
        #expect(!result.hasErrors, "should parse: \(input.debugDescription)")
        #expect(result.tree.green.reconstructedText == input)
        // The string node preserves the literal exactly, including its delimiters and escapes.
        let literal = String(input.dropFirst("char *s = ".count).dropLast())
        #expect(firstNode("string_literal", in: result) == literal, "string node for: \(input.debugDescription)")
    }

    @Test(
        "Every character-constant escape round-trips verbatim in the char node",
        arguments: [
            "char c = 'a';", "char c = '\\n';", "char c = '\\0';", "char c = '\\t';",
            "char c = '\\x41';", "char c = '\\101';", "char c = '\\\\';", "char c = '\\'';",
        ])
    func charEscapesRoundTrip(_ input: String) {
        let result = parse(input)
        #expect(!result.hasErrors, "should parse: \(input.debugDescription)")
        #expect(result.tree.green.reconstructedText == input)
        let literal = String(input.dropFirst("char c = ".count).dropLast())
        #expect(firstNode("char_literal", in: result) == literal, "char node for: \(input.debugDescription)")
    }

    @Test(
        "Integer literals of every form parse and round-trip",
        arguments: [
            "int n = 255;", "int n = 0xFF;", "int n = 0377;", "unsigned n = 100u;",
            "long n = 100L;", "unsigned long n = 0xFFUL;", "long long n = 1ll;", "int n = 0;",
        ])
    func integerLiteralsRoundTrip(_ input: String) {
        let result = parse(input)
        #expect(!result.hasErrors, "should parse: \(input.debugDescription)")
        #expect(result.tree.green.reconstructedText == input)
    }

    @Test(
        "Floating literals of every form parse and round-trip",
        arguments: [
            "double d = 3.14;", "double d = 1e10;", "float d = 1.5f;", "double d = .5;",
            "double d = 1E-3;", "double d = 0x1.8p3;", "double d = 2.;", "long double d = 1.0L;",
        ])
    func floatLiteralsRoundTrip(_ input: String) {
        let result = parse(input)
        #expect(!result.hasErrors, "should parse: \(input.debugDescription)")
        #expect(result.tree.green.reconstructedText == input)
    }
}
