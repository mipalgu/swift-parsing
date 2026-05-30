import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR

/// The shared C corpora and parsing helpers for the `CTests` suite.
///
/// The corpus is split by which acceptance gate each input feeds. ``structural`` inputs drive all three
/// engines through ``CGrammar/translationUnit()`` and must agree by byte-identical S-expression and
/// round-trip losslessly. ``expression`` inputs drive the ALL(*) engine through ``CGrammar/expressions()``
/// and prove precedence and associativity across C's fifteen-level operator ladder. ``multibyte`` inputs
/// additionally exercise granularity agreement.
enum Corpus {
    /// Structural C inputs every engine must agree on, exercising the full declaration, statement, and
    /// expression grammar.
    static let structural: [String] = [
        // Empty and trivial translation units.
        "",
        "  ",
        "\n\t\n",
        // File-scope declarations.
        "int x;",
        "int x = 1;",
        "const int x = 42;",
        "int a, b, c;",
        "int x = 1, y = 2;",
        "unsigned long long big = 0;",
        "signed char ch = 0;",
        "double pi = 3.14159;",
        // Pointers and arrays.
        "int *p;",
        "int **pp;",
        "int *const p = 0;",
        "char *s = \"text\";",
        "int arr[10];",
        "int matrix[3][4];",
        "int xs[] = {1, 2, 3};",
        "int nested[] = {1, {2, 3}, 4};",
        // Type-specifier combinations (built-in keywords only).
        "unsigned int u;",
        "long long ll;",
        "long double ld;",
        "short int si;",
        "const unsigned char cuc = 0;",
        // Function definitions.
        "int main(void) { return 0; }",
        "int add(int a, int b) { return a + b; }",
        "void noop(void) {}",
        "int *getp(int *q) { return q; }",
        // Void-typed pointer parameters (a lone `void` parses as one unnamed parameter declaration).
        "void f(void *p) { }",
        "void f(void **pp) { }",
        "void g(int x, void *p) { return; }",
        "double scale(double x, double factor) { return x * factor; }",
        // Statements inside bodies.
        "void f(void) { int x = 1; x = x + 2; }",
        "int f(void) { if (x) return 1; else return 2; }",
        "int f(void) { if (a) { if (b) return 1; } return 0; }",
        "void f(void) { while (n > 0) n = n - 1; }",
        "void f(void) { for (int i = 0; i < 10; i = i + 1) sum = sum + i; }",
        "void f(void) { for (;;) break; }",
        "void f(void) { do { x = x + 1; } while (x < 10); }",
        "int f(void) { return; }",
        "void f(void) { ; }",
        "void f(void) { goto done; done: return; }",
        "void f(void) { start: x = x + 1; goto start; }",
        "void f(void) { while (1) { if (x) break; else continue; } }",
        // Nested blocks three deep.
        "void f(void) { { { int x = 1; } } }",
        // Casts (unambiguous: the parenthesised thing is always a type keyword).
        "int f(void) { return (int)y; }",
        "void f(void) { p = (char *)q; }",
        "int f(void) { return (unsigned long)x + 1; }",
        // sizeof in both forms.
        "int f(void) { return sizeof(int); }",
        "int f(void) { return sizeof x; }",
        "int f(void) { return sizeof(int *); }",
        // Conditional and assignment operators.
        "int f(void) { return a ? b : c; }",
        "void f(void) { x = a = b; }",
        "void f(void) { x += 1; y -= 2; z *= 3; }",
        "void f(void) { x <<= 1; y >>= 2; m %= 3; }",
        "void f(void) { a &= b; a ^= c; a |= d; }",
        // Postfix forms.
        "void f(void) { p->next = q; }",
        "void f(void) { arr[i] = obj.field; }",
        "int f(void) { return g(1, 2, 3); }",
        "int f(void) { return *p++; }",
        "void f(void) { x++; --y; }",
        "int f(void) { return a.b.c->d; }",
        "int f(void) { return f(g(h(x))); }",
        // Operators across tiers.
        "int f(void) { return 1 + 2 * 3 - 4 / 5 % 6; }",
        "int f(void) { return a << b >> c; }",
        "int f(void) { return a < b && c > d; }",
        "int f(void) { return a == b || c != d; }",
        "int f(void) { return x | y & z ^ w; }",
        "int f(void) { return !a && ~b; }",
        "int f(void) { return -x + +y; }",
        "int f(void) { return a, b, c; }",
        // Integer literal forms.
        "int dec = 255; int hex = 0xFF; int oct = 0377;",
        "unsigned u = 100u; long l = 100L; unsigned long ul = 0xFFUL;",
        // Floating literal forms.
        "double d = 3.14; double e = 1e10; float f = 1.5f;",
        "double h = 0x1.8p3; double n = .5; double m = 1E-3;",
        // Character constants and escapes.
        "char a = 'x'; char b = '\\n'; char c = '\\0';",
        "char h = '\\x41'; char o = '\\101';",
        // String literals and escapes.
        "char *s = \"hello\\tworld\\n\";",
        "char *e = \"q\\\"q\\\\q\";",
        "char *x = \"\\x41\\102\";",
        // Trivia: comments before, between, and after tokens.
        "// a line comment\nint x = 1;",
        "int x = 1; // trailing comment",
        "int x = /* inline */ 1;",
        "/* leading */ int x = 1;",
        "// one\n// two\nint x = 1;",
        // Unicode payloads in strings and comments (mirrors the JSON/Lua multibyte rows).
        "char *s = \"café\";",
        "char *s = \"🇦🇺\";",
        "// café comment\nint x = 1;",
    ]

    /// Structural inputs carrying multibyte payloads, used for cross-granularity agreement checks.
    static let multibyte: [String] = [
        "char *s = \"café\";",
        "char *s = \"🇦🇺\";",
        "char *t = \"naïve café\";",
        "// 🇦🇺 comment\nint x = 1;",
        "int x = 1; /* café */ int y = 2;",
    ]

    /// Expression inputs that drive the ALL(*) precedence ladder in ``CGrammar/expressions()``.
    static let expression: [String] = [
        "a",
        "a + b * c",
        "a * b + c",
        "a << b + c",
        "a && b || c",
        "a | b ^ c & d",
        "a == b != c",
        "a < b <= c",
        "a = b = c",
        "a ? b : c ? d : e",
        "a = b ? c : d",
        "*p++",
        "-a + b",
        "!a && b",
        "~x | y",
        "a, b, c",
        "(int)x + 1",
        "sizeof(int)",
        "sizeof x",
        "a.b.c->d",
        "f(g(x), h(y))",
        "arr[i][j]",
        "a += b *= c",
        "1 + 2 + 3 + 4",
    ]

    // MARK: - Parsing helpers

    /// Parses C source with the recursive-descent reference engine over the structural grammar.
    /// - Parameter text: The C source.
    /// - Returns: The parse result.
    /// - Throws: A grammar error if engine construction fails.
    static func parseReference(_ text: String) throws -> ParseResult {
        try UTF8Parser(grammar: CGrammar.translationUnit()).parse(Source(text))
    }

    /// Parses C source with the GLR engine over the structural grammar.
    /// - Parameter text: The C source.
    /// - Returns: The parse result.
    /// - Throws: A grammar error if engine construction fails.
    static func parseGLR(_ text: String) throws -> ParseResult {
        try UTF8GLRParser(grammar: CGrammar.translationUnit()).parse(Source(text))
    }

    /// Parses C source with the ALL(*) engine over the structural grammar.
    /// - Parameter text: The C source.
    /// - Returns: The parse result.
    /// - Throws: A grammar error if engine construction fails.
    static func parseAllStar(_ text: String) throws -> ParseResult {
        try ALLStarUTF8Parser(grammar: CGrammar.translationUnit()).parse(Source(text))
    }

    /// Parses a C expression with the ALL(*) engine over the left-recursive expression grammar.
    /// - Parameter text: The C expression source.
    /// - Returns: The parse result.
    /// - Throws: A grammar error if engine construction fails.
    static func parseExpression(_ text: String) throws -> ParseResult {
        try ALLStarUTF8Parser(grammar: CGrammar.expressions()).parse(Source(text))
    }
}
