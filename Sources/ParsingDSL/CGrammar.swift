import ParsingCore

/// An unambiguous subset of C, authored in the Swift DSL, targeting the C11 surface syntax.
///
/// Two grammars are exposed over one shared lexical core, because the framework's engines treat left
/// recursion differently. ``translationUnit()`` is the full structural grammar, authored free of left
/// recursion so it runs identically on the recursive-descent, GLR, and ALL(*) engines and anchors the
/// byte-identical three-engine differential. ``expressions()`` is a directly left-recursive expression
/// ladder built with the `precedence(level:associativity:)` combinator across C's full fifteen-level
/// operator hierarchy; it drives the ALL(*) engine's left-recursion rewriter and proves precedence
/// climbing on a deep, right-associative-bearing ladder. Both share the lexical core: identifiers (with a
/// lookahead-driven keyword boundary), the integer, floating, character, and string literal forms with the
/// full C escape set, and the line- and block-comment trivia.
///
/// Node-type and field names follow the C grammar in the standard and the tree-sitter `tree-sitter-c`
/// conventions where practical, so a parsed tree reads naturally and queries are portable.
///
/// ## Scope: a deliberately unambiguous C subset
///
/// This grammar parses a real, recognisable, but deliberately restricted subset of C, chosen so the
/// language is unambiguous without a symbol table:
///
/// - **Types are built-in keywords only.** A type specifier is one or more of the built-in keywords
///   `void char short int long float double signed unsigned _Bool`, optionally `const`-qualified, with
///   pointer (`*`) and array (`[]`) declarators. There are **no user `typedef` names**, and **no
///   `struct`/`union`/`enum` type definitions**. This is the single most important scope decision: it
///   removes C's notorious typedef-name-versus-identifier context sensitivity, so a cast such as `(int)x`
///   is unambiguous because the parenthesised thing is always a type keyword and never an identifier.
/// - **No preprocessor.** Directives (`#include`, `#define`, `#if`, …) are out of scope; the input is
///   already-preprocessed translation-unit text.
/// - **Statements** covered: the expression statement, declaration, compound block `{ … }`, `if`/`else`,
///   `while`, `for`, `do`/`while`, `return`, `break`, `continue`, `goto`/label, and the empty statement
///   `;`.
/// - **Functions** with parameter lists and bodies are covered, as are file-scope declarations.
///
/// ## Known limitations
///
/// - Initialiser lists use a single brace-enclosed, comma-separated expression list; designated
///   initialisers (`.field = …`, `[index] = …`) are not modelled.
/// - The `sizeof` operator is modelled in its expression form (`sizeof x`) and its parenthesised
///   type-name form (`sizeof(int)`); the parenthesised form shares the cast's type-name production.
/// - Compound literals (`(int){0}`) and `_Generic` selections are out of scope.
public enum CGrammar {
    // MARK: - Lexical core

    /// A matcher for the first character of an identifier: an ASCII letter or underscore.
    private static var identifierStart: TokenMatcher {
        Match.oneOf(Match.letter, Match.lit("_"))
    }

    /// A matcher for a subsequent identifier character: an ASCII letter, digit, or underscore.
    private static var identifierContinue: TokenMatcher {
        Match.oneOf(Match.letter, Match.digit, Match.lit("_"))
    }

    /// The C reserved words (C11), which an identifier may not equal.
    ///
    /// These are excluded from the identifier matcher so a keyword is never parsed as an identifier. That
    /// is essential for the lookahead-driven and exploratory engines, which would otherwise see a genuine
    /// ambiguity between a structural keyword (such as `return`) and an identifier and either mispredict or
    /// fail. The full reserved set is listed (not only the subset the grammar uses structurally) so an
    /// identifier never collides with any reserved word.
    private static let reservedWords = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
        "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return",
        "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
        "volatile", "while", "_Bool", "_Complex", "_Imaginary", "_Alignas", "_Alignof", "_Atomic",
        "_Generic", "_Noreturn", "_Static_assert", "_Thread_local",
    ]

    /// A zero-width assertion that the current position is at a word boundary: it is not followed by a
    /// further identifier-continuation character.
    ///
    /// Sequenced after a keyword literal, this turns `int` into a keyword only when it is not immediately
    /// followed by another identifier character, so `internal` is read as a single identifier rather than
    /// the keyword `int` plus `ernal`.
    private static var keywordBoundary: TokenMatcher {
        Match.notFollowedBy(identifierContinue)
    }

    /// A matcher that matches exactly one reserved word standing at a word boundary.
    ///
    /// It is the alternation of every reserved word, each followed by the ``keywordBoundary`` assertion, so
    /// it matches `int`, `return`, … only when the word is complete (not merely a prefix of a longer
    /// identifier such as `internal`). It is used as a negative lookahead in front of the identifier matcher
    /// to forbid an identifier that *is* a whole keyword while still admitting identifiers that contain or
    /// border one. The reserved words are sorted longest-first so a longer keyword is preferred over a
    /// shorter one that is its prefix (for example `_Bool` over a hypothetical `_B`).
    private static var anyKeywordAtBoundary: TokenMatcher {
        let sorted = reservedWords.sorted { $0.count > $1.count }
        return .alternation(sorted.map { Match.seq(Match.lit($0), keywordBoundary) })
    }

    /// A matcher for a C identifier: a letter or underscore then letters, digits, or underscores, excluding
    /// the reserved words.
    ///
    /// A leading negative lookahead rejects an identifier that is exactly a reserved word standing at a word
    /// boundary, so a keyword is never parsed as an identifier (which the lookahead and exploratory engines
    /// require to parse statement and declaration boundaries unambiguously), while identifiers that merely
    /// contain, begin with, or end with a keyword (such as `internal`, `ifdef`, `_intern`, or `returns`)
    /// are still admitted. The keyword is matched as a literal in the structural positions that require it.
    private static var identifierMatcher: TokenMatcher {
        Match.seq(
            Match.notFollowedBy(anyKeywordAtBoundary),
            identifierStart,
            Match.zeroOrMore(identifierContinue))
    }

    /// A matcher for a run of one or more ASCII decimal digits.
    private static var digits: TokenMatcher { Match.oneOrMore(Match.digit) }

    /// A matcher for a run of one or more ASCII hexadecimal digits.
    private static var hexDigits: TokenMatcher { Match.oneOrMore(Match.hexDigit) }

    /// A matcher for an optional sign (`+` or `-`).
    private static var optionalSign: TokenMatcher {
        Match.optional(Match.oneOf(Match.lit("+"), Match.lit("-")))
    }

    /// A matcher for an integer suffix: any run of the unsigned (`u`/`U`) and long (`l`/`L`) suffix letters.
    ///
    /// C admits `u`, `l`, `ll`, `ul`, `lu`, `ull`, and their case variants in any order; matching a run of
    /// the suffix letters captures every valid combination (and is the same liberal lexical rule
    /// tree-sitter uses), which is sufficient for a lossless, round-tripping token.
    private static var integerSuffix: TokenMatcher {
        Match.zeroOrMore(Match.oneOf(Match.lit("u"), Match.lit("U"), Match.lit("l"), Match.lit("L")))
    }

    /// A matcher for a floating suffix: an optional `f`/`F` or `l`/`L`.
    private static var floatSuffix: TokenMatcher {
        Match.optional(Match.oneOf(Match.lit("f"), Match.lit("F"), Match.lit("l"), Match.lit("L")))
    }

    /// A matcher for a decimal exponent suffix: `e`/`E`, an optional sign, then digits.
    private static var decimalExponent: TokenMatcher {
        Match.seq(Match.oneOf(Match.lit("e"), Match.lit("E")), optionalSign, digits)
    }

    /// A matcher for a binary (hex-float) exponent suffix: `p`/`P`, an optional sign, then digits.
    private static var binaryExponent: TokenMatcher {
        Match.seq(Match.oneOf(Match.lit("p"), Match.lit("P")), optionalSign, digits)
    }

    /// A matcher for a hexadecimal prefix (`0x` or `0X`).
    private static var hexPrefix: TokenMatcher {
        Match.seq(Match.lit("0"), Match.oneOf(Match.lit("x"), Match.lit("X")))
    }

    /// A matcher for a C integer literal: hexadecimal, octal, or decimal, with an optional integer suffix.
    ///
    /// A `0x`-prefixed run of hex digits is hexadecimal; a leading `0` followed by octal digits is octal;
    /// any other digit run is decimal. The octal form is listed before the decimal form so a leading `0` is
    /// taken as octal, and a bare `0` falls through to the decimal form. The suffix run may be empty.
    private static var integerLiteralMatcher: TokenMatcher {
        let hexInteger = Match.seq(hexPrefix, hexDigits)
        // An octal literal is a leading 0 followed by one or more octal digits (0-7).
        let octalInteger = Match.seq(Match.lit("0"), Match.oneOrMore(Match.range("0", "7")))
        let decimalInteger = digits
        return Match.seq(Match.oneOf(hexInteger, octalInteger, decimalInteger), integerSuffix)
    }

    /// A matcher for a C floating-constant literal: hexadecimal-float or decimal-float, with an optional
    /// floating suffix.
    ///
    /// The decimal forms are `digits . [digits] [exp]`, `. digits [exp]`, and `digits exp`; the
    /// hexadecimal forms require the `0x` prefix and a binary (`p`) exponent. A floating literal must carry
    /// a fractional point or an exponent, which is what distinguishes it from an integer literal; the
    /// expression grammar lists the floating form first so the longer match is preferred by ordered choice.
    private static var floatLiteralMatcher: TokenMatcher {
        let hexFloat = Match.seq(
            hexPrefix,
            Match.oneOf(
                Match.seq(hexDigits, Match.lit("."), Match.zeroOrMore(Match.hexDigit)),
                Match.seq(Match.lit("."), hexDigits),
                hexDigits),
            binaryExponent,
            floatSuffix)
        let decimalFloat = Match.seq(
            Match.oneOf(
                Match.seq(digits, Match.lit("."), Match.zeroOrMore(Match.digit), Match.optional(decimalExponent)),
                Match.seq(Match.lit("."), digits, Match.optional(decimalExponent)),
                Match.seq(digits, decimalExponent)),
            floatSuffix)
        return Match.oneOf(hexFloat, decimalFloat)
    }

    /// A matcher for one C escape sequence inside a character or string literal.
    ///
    /// Covers the simple escapes `\a \b \f \n \r \t \v \\ \" \' \?`, the null escape `\0` (handled by the
    /// octal form), a hex escape `\xHH…` (one or more hex digits), and an octal escape `\ooo` (one to three
    /// octal digits). The octal form subsumes `\0`.
    private static var escapeSequence: TokenMatcher {
        let backslash = Match.lit("\\")
        let simple = Match.oneOf(
            Match.lit("a"), Match.lit("b"), Match.lit("f"), Match.lit("n"), Match.lit("r"),
            Match.lit("t"), Match.lit("v"), Match.lit("\\"), Match.lit("\""), Match.lit("'"),
            Match.lit("?"))
        let hexEscape = Match.seq(Match.lit("x"), Match.oneOrMore(Match.hexDigit))
        // An octal escape is one to three octal digits (this subsumes `\0`).
        let octalEscape = Match.seq(
            Match.range("0", "7"), Match.optional(Match.range("0", "7")), Match.optional(Match.range("0", "7")))
        return Match.seq(backslash, Match.oneOf(hexEscape, simple, octalEscape))
    }

    /// A matcher for a C string literal: `"…"` with escapes.
    ///
    /// The body is any run of escape sequences and non-delimiter, non-backslash, non-newline elements.
    private static var stringLiteralMatcher: TokenMatcher {
        let ordinary = Match.not(
            Match.oneOf(Match.lit("\""), Match.lit("\\"), Match.lit("\n"), Match.lit("\r")))
        return Match.seq(
            Match.lit("\""),
            Match.zeroOrMore(Match.oneOf(escapeSequence, ordinary)),
            Match.lit("\""))
    }

    /// A matcher for a C character constant: `'a'`, `'\n'`, `'\x41'`, and so on.
    ///
    /// The body is one escape sequence or one non-delimiter, non-backslash, non-newline element.
    private static var charLiteralMatcher: TokenMatcher {
        let ordinary = Match.not(
            Match.oneOf(Match.lit("'"), Match.lit("\\"), Match.lit("\n"), Match.lit("\r")))
        return Match.seq(
            Match.lit("'"),
            Match.oneOf(escapeSequence, ordinary),
            Match.lit("'"))
    }

    /// The trivia matchers permitted between tokens: whitespace, line comments, and block comments.
    ///
    /// Block comments are listed before line comments so a `/* … */` comment is not mistaken for a `//`
    /// line comment (they share no prefix, but the ordering keeps the intent explicit).
    private static var extras: [TokenMatcher] {
        [
            .builtin(.whitespace),
            blockComment(open: "/*", close: "*/"),
            lineComment("//"),
        ]
    }

    /// Builds a maximal-munch-safe operator token: the literal `text`, but only when it is not immediately
    /// followed by a character that would extend it into a longer C operator.
    ///
    /// C operators obey the maximal-munch ("longest token") lexing rule: `&&` is one token, not the
    /// bitwise-and `&` followed by the address-of `&`. The grammar matches operators tier by tier as bare
    /// literals, and a shorter operator sitting at a tighter-binding tier (such as bitwise-and `&`) is
    /// reached before a longer operator at a looser tier (such as logical-and `&&`); without a boundary the
    /// greedy engines would match the `&` and mis-read the second `&` as a unary address-of. A trailing
    /// negative lookahead forbidding the operator's extension characters restores maximal munch on every
    /// engine without a separate tokenisation pass. The single-character operators that are a prefix of a
    /// longer operator carry the guard; operators that are not a prefix of any longer operator are matched
    /// as plain literals.
    /// - Parameters:
    ///   - text: The operator's exact text.
    ///   - notFollowedBy: The characters that, if they immediately followed, would form a longer operator.
    /// - Returns: A guarded anonymous-token rule expression for the operator.
    private static func op(_ text: String, notFollowedBy continuations: [String]) -> RuleExpr {
        token(
            Match.seq(
                Match.lit(text),
                Match.notFollowedBy(.alternation(continuations.map { Match.lit($0) }))))
    }

    /// Builds a word-boundary-guarded keyword token: the literal `text`, but only when it stands at a word
    /// boundary (it is not immediately followed by a further identifier character).
    ///
    /// A C keyword used in a structural position (such as the type keyword `int` or the statement keyword
    /// `return`) is a bare literal, which without a boundary would match the `int` prefix of the identifier
    /// `intx`, splitting one identifier into a keyword and a shorter name. The trailing
    /// ``keywordBoundary`` assertion restores the maximal-munch identifier rule, mirroring the negative
    /// lookahead the identifier matcher already uses to exclude whole keywords. The keyword is matched as an
    /// anonymous token so it contributes the same (absent) node as a bare literal would.
    /// - Parameter text: The keyword's exact text.
    /// - Returns: A boundary-guarded anonymous-token rule expression for the keyword.
    private static func keyword(_ text: String) -> RuleExpr {
        token(Match.seq(Match.lit(text), keywordBoundary))
    }

    // MARK: - Structural grammar (left-recursion-free; all three engines)

    /// Builds the full structural C grammar as a `Grammar` intermediate representation.
    ///
    /// The grammar is authored without left recursion: the expression layer uses the iterative
    /// `tier ((op) tier)*` style for the left-associative tiers and right recursion for the
    /// right-associative assignment and conditional tiers, and the postfix layer uses a primary followed by
    /// a repeated suffix, so it parses identically on the recursive-descent, GLR, and ALL(*) engines. The
    /// start rule is `translation_unit`.
    /// - Returns: The structural C grammar.
    public static func translationUnit() -> Grammar {
        Grammar(name: "c", start: "translation_unit", extras: extras) {
            // A translation unit is a run of top-level declarations and function definitions.
            rule("translation_unit") {
                repeat0 { ref("top_level_item") }
            }
            rule("top_level_item") {
                choice {
                    ref("function_definition")
                    ref("declaration")
                }
            }

            // A function definition: a type, a declarator with a parameter list, then a compound body.
            rule("function_definition") {
                seq {
                    field("type") { ref("type_specifier") }
                    field("declarator") { ref("function_declarator") }
                    field("body") { ref("compound_statement") }
                }
            }
            // A function declarator: an optional pointer, a name, then a parenthesised parameter list.
            rule("function_declarator") {
                seq {
                    repeat0 { ref("pointer") }
                    field("name") { ref("identifier") }
                    "("
                    optional { field("parameters") { ref("parameter_list") } }
                    ")"
                }
            }
            rule("parameter_list") {
                choice {
                    // A lone `void` parameter list (an explicitly empty list), guarded to a word boundary.
                    keyword("void")
                    seq {
                        ref("parameter_declaration")
                        repeat0 {
                            seq {
                                ","
                                ref("parameter_declaration")
                            }
                        }
                    }
                }
            }
            rule("parameter_declaration") {
                seq {
                    field("type") { ref("type_specifier") }
                    optional { field("declarator") { ref("declarator") } }
                }
            }

            // A type specifier: optional `const`, one or more built-in type keywords, optional `const`.
            rule("type_specifier") {
                seq {
                    optional { keyword("const") }
                    repeat1 { ref("type_keyword") }
                    optional { keyword("const") }
                }
            }
            rule("type_keyword") {
                choice {
                    // Each type keyword stands at a word boundary so it does not match the prefix of a
                    // longer identifier (for example the `int` of `intx`).
                    keyword("void"); keyword("char"); keyword("short"); keyword("int"); keyword("long")
                    keyword("float"); keyword("double"); keyword("signed"); keyword("unsigned")
                    keyword("_Bool")
                }
            }

            // A pointer declarator part: `*` with an optional `const` qualifier.
            rule("pointer") {
                seq {
                    "*"
                    optional { keyword("const") }
                }
            }

            // A declarator: optional pointers, a name, then optional array dimensions.
            rule("declarator") {
                seq {
                    repeat0 { ref("pointer") }
                    field("name") { ref("identifier") }
                    repeat0 { ref("array_dimension") }
                }
            }
            rule("array_dimension") {
                seq {
                    "["
                    optional { field("size") { ref("expression") } }
                    "]"
                }
            }

            // MARK: Statements

            rule("statement") {
                choice {
                    ref("compound_statement")
                    ref("if_statement")
                    ref("while_statement")
                    ref("do_while_statement")
                    ref("for_statement")
                    ref("return_statement")
                    ref("break_statement")
                    ref("continue_statement")
                    ref("goto_statement")
                    ref("labeled_statement")
                    ref("empty_statement")
                    ref("declaration")
                    ref("expression_statement")
                }
            }

            rule("compound_statement") {
                seq {
                    "{"
                    repeat0 { ref("statement") }
                    "}"
                }
            }

            // A declaration: a type, a comma-separated init-declarator list, then `;`.
            rule("declaration") {
                seq {
                    field("type") { ref("type_specifier") }
                    ref("init_declarator")
                    repeat0 {
                        seq {
                            ","
                            ref("init_declarator")
                        }
                    }
                    ";"
                }
            }
            rule("init_declarator") {
                seq {
                    field("declarator") { ref("declarator") }
                    optional {
                        seq {
                            "="
                            field("value") { ref("initialiser") }
                        }
                    }
                }
            }
            // An initialiser: a single assignment-level expression or a brace-enclosed expression list.
            rule("initialiser") {
                choice {
                    ref("initialiser_list")
                    ref("assignment_expression")
                }
            }
            rule("initialiser_list") {
                seq {
                    "{"
                    optional {
                        seq {
                            ref("initialiser")
                            repeat0 {
                                seq {
                                    ","
                                    ref("initialiser")
                                }
                            }
                            optional { "," }
                        }
                    }
                    "}"
                }
            }

            rule("if_statement") {
                seq {
                    keyword("if")
                    "("
                    field("condition") { ref("expression") }
                    ")"
                    field("consequence") { ref("statement") }
                    optional { ref("else_clause") }
                }
            }
            rule("else_clause") {
                seq {
                    keyword("else")
                    field("alternative") { ref("statement") }
                }
            }

            rule("while_statement") {
                seq {
                    keyword("while")
                    "("
                    field("condition") { ref("expression") }
                    ")"
                    field("body") { ref("statement") }
                }
            }

            rule("do_while_statement") {
                seq {
                    keyword("do")
                    field("body") { ref("statement") }
                    keyword("while")
                    "("
                    field("condition") { ref("expression") }
                    ")"
                    ";"
                }
            }

            // A for statement: the three clauses may each be empty; the initialiser may be a declaration.
            rule("for_statement") {
                seq {
                    keyword("for")
                    "("
                    optional { field("initialiser") { ref("for_initialiser") } }
                    ";"
                    optional { field("condition") { ref("expression") } }
                    ";"
                    optional { field("update") { ref("expression") } }
                    ")"
                    field("body") { ref("statement") }
                }
            }
            // The for-initialiser is either a (semicolon-less) declaration head or an expression; the
            // declaration form reuses the type, init-declarator list (no trailing `;`, which the `for`
            // production supplies).
            rule("for_initialiser") {
                choice {
                    ref("for_declaration")
                    ref("expression")
                }
            }
            rule("for_declaration") {
                seq {
                    field("type") { ref("type_specifier") }
                    ref("init_declarator")
                    repeat0 {
                        seq {
                            ","
                            ref("init_declarator")
                        }
                    }
                }
            }

            rule("return_statement") {
                seq {
                    keyword("return")
                    optional { field("value") { ref("expression") } }
                    ";"
                }
            }
            rule("break_statement") {
                seq {
                    keyword("break")
                    ";"
                }
            }
            rule("continue_statement") {
                seq {
                    keyword("continue")
                    ";"
                }
            }
            rule("goto_statement") {
                seq {
                    keyword("goto")
                    field("label") { ref("identifier") }
                    ";"
                }
            }
            // A labelled statement: a name, a colon, then the statement it labels.
            rule("labeled_statement") {
                seq {
                    field("label") { ref("identifier") }
                    ":"
                    field("statement") { ref("statement") }
                }
            }
            rule("empty_statement") { ";" }
            rule("expression_statement") {
                seq {
                    field("expression") { ref("expression") }
                    ";"
                }
            }

            // MARK: Expression layer (iterative ladder, lowest to highest precedence)

            // The full expression, including the comma operator (the lowest-binding level).
            rule("expression") {
                seq {
                    ref("assignment_expression")
                    repeat0 {
                        seq {
                            ","
                            ref("assignment_expression")
                        }
                    }
                }
            }

            // Assignment is right-associative: the right operand is itself an assignment expression.
            rule("assignment_expression") {
                choice {
                    seq {
                        field("left") { ref("unary_expression") }
                        field("operator") { ref("assignment_operator") }
                        field("right") { ref("assignment_expression") }
                    }
                    ref("conditional_expression")
                }
            }
            rule("assignment_operator") {
                choice {
                    "<<="; ">>="; "+="; "-="; "*="; "/="; "%="; "&="; "^="; "|="
                    // A bare `=` must not be the first character of `==` (equality), so it is guarded.
                    op("=", notFollowedBy: ["="])
                }
            }

            // The conditional (ternary) operator is right-associative: both branches re-enter at the
            // assignment level on the right, giving `a ? b : c ? d : e` the grouping `a ? b : (c ? d : e)`.
            rule("conditional_expression") {
                seq {
                    ref("logical_or_expression")
                    optional {
                        seq {
                            "?"
                            field("consequence") { ref("expression") }
                            ":"
                            field("alternative") { ref("conditional_expression") }
                        }
                    }
                }
            }

            rule("logical_or_expression") {
                seq {
                    ref("logical_and_expression")
                    repeat0 {
                        seq {
                            "||"
                            ref("logical_and_expression")
                        }
                    }
                }
            }
            rule("logical_and_expression") {
                seq {
                    ref("bitwise_or_expression")
                    repeat0 {
                        seq {
                            "&&"
                            ref("bitwise_or_expression")
                        }
                    }
                }
            }
            rule("bitwise_or_expression") {
                seq {
                    ref("bitwise_xor_expression")
                    repeat0 {
                        seq {
                            // A bare `|` must not begin `||` (logical-or) or `|=` (compound assignment).
                            op("|", notFollowedBy: ["|", "="])
                            ref("bitwise_xor_expression")
                        }
                    }
                }
            }
            rule("bitwise_xor_expression") {
                seq {
                    ref("bitwise_and_expression")
                    repeat0 {
                        seq {
                            // A bare `^` must not begin `^=` (compound assignment).
                            op("^", notFollowedBy: ["="])
                            ref("bitwise_and_expression")
                        }
                    }
                }
            }
            rule("bitwise_and_expression") {
                seq {
                    ref("equality_expression")
                    repeat0 {
                        seq {
                            // A bare `&` must not begin `&&` (logical-and) or `&=` (compound assignment).
                            op("&", notFollowedBy: ["&", "="])
                            ref("equality_expression")
                        }
                    }
                }
            }
            rule("equality_expression") {
                seq {
                    ref("relational_expression")
                    repeat0 {
                        seq {
                            choice {
                                "=="; "!="
                            }
                            ref("relational_expression")
                        }
                    }
                }
            }
            rule("relational_expression") {
                seq {
                    ref("shift_expression")
                    repeat0 {
                        seq {
                            choice {
                                "<="; ">="
                                // Bare `<`/`>` must not begin `<<`/`>>` (shift) or `<=`/`>=` (relational).
                                op("<", notFollowedBy: ["<", "="])
                                op(">", notFollowedBy: [">", "="])
                            }
                            ref("shift_expression")
                        }
                    }
                }
            }
            rule("shift_expression") {
                seq {
                    ref("additive_expression")
                    repeat0 {
                        seq {
                            choice {
                                // Bare `<<`/`>>` must not begin `<<=`/`>>=` (compound assignment).
                                op("<<", notFollowedBy: ["="])
                                op(">>", notFollowedBy: ["="])
                            }
                            ref("additive_expression")
                        }
                    }
                }
            }
            rule("additive_expression") {
                seq {
                    ref("multiplicative_expression")
                    repeat0 {
                        seq {
                            choice {
                                // Bare `+`/`-` must not begin `++`/`--`, `+=`/`-=`, or `->`.
                                op("+", notFollowedBy: ["+", "="])
                                op("-", notFollowedBy: ["-", "=", ">"])
                            }
                            ref("multiplicative_expression")
                        }
                    }
                }
            }
            rule("multiplicative_expression") {
                seq {
                    ref("cast_expression")
                    repeat0 {
                        seq {
                            choice {
                                // Bare `*`/`/`/`%` must not begin `*=`/`/=`/`%=` (compound assignment).
                                op("*", notFollowedBy: ["="])
                                op("/", notFollowedBy: ["="])
                                op("%", notFollowedBy: ["="])
                            }
                            ref("cast_expression")
                        }
                    }
                }
            }
            // A cast: a parenthesised type name then a further cast expression (right-associative), or a
            // unary expression. The parenthesised thing is always a type keyword (never an identifier),
            // which is what makes the cast unambiguous in this subset.
            rule("cast_expression") {
                choice {
                    seq {
                        "("
                        field("type") { ref("type_name") }
                        ")"
                        field("operand") { ref("cast_expression") }
                    }
                    ref("unary_expression")
                }
            }
            // A type name: a type specifier with optional pointer and array declarator parts (an abstract
            // declarator), used by casts and the `sizeof(type)` form.
            rule("type_name") {
                seq {
                    field("type") { ref("type_specifier") }
                    repeat0 { ref("pointer") }
                    repeat0 { ref("array_dimension") }
                }
            }

            // Prefix/unary operators bind tighter than every binary operator but looser than postfix.
            rule("unary_expression") {
                choice {
                    seq {
                        field("operator") { ref("prefix_operator") }
                        field("operand") { ref("cast_expression") }
                    }
                    ref("sizeof_expression")
                    ref("postfix_expression")
                }
            }
            rule("prefix_operator") {
                choice {
                    "++"; "--"; "~"
                    // Each bare single-character prefix operator must not begin a longer operator, so the
                    // greedy engines do not split `++x` into `+ (+x)` or read `&x` as the start of `&&`.
                    op("+", notFollowedBy: ["+", "="])
                    op("-", notFollowedBy: ["-", "=", ">"])
                    op("!", notFollowedBy: ["="])
                    op("*", notFollowedBy: ["="])
                    op("&", notFollowedBy: ["&", "="])
                }
            }
            // `sizeof` applies to a parenthesised type name or to a unary expression.
            rule("sizeof_expression") {
                seq {
                    keyword("sizeof")
                    choice {
                        seq {
                            "("
                            field("type") { ref("type_name") }
                            ")"
                        }
                        field("operand") { ref("unary_expression") }
                    }
                }
            }

            // A postfix expression: a primary atom then zero or more postfix suffixes (call, subscript,
            // member access, increment, decrement). This is the left-recursion-free factoring of the
            // postfix tier.
            rule("postfix_expression") {
                seq {
                    ref("primary_expression")
                    repeat0 { ref("postfix_suffix") }
                }
            }
            rule("postfix_suffix") {
                choice {
                    ref("call_suffix")
                    ref("subscript_suffix")
                    ref("member_suffix")
                    ref("increment_suffix")
                }
            }
            rule("call_suffix") {
                seq {
                    "("
                    optional { field("arguments") { ref("argument_list") } }
                    ")"
                }
            }
            rule("argument_list") {
                seq {
                    ref("assignment_expression")
                    repeat0 {
                        seq {
                            ","
                            ref("assignment_expression")
                        }
                    }
                }
            }
            rule("subscript_suffix") {
                seq {
                    "["
                    field("index") { ref("expression") }
                    "]"
                }
            }
            rule("member_suffix") {
                seq {
                    field("operator") {
                        choice {
                            "."; "->"
                        }
                    }
                    field("name") { ref("identifier") }
                }
            }
            rule("increment_suffix") {
                field("operator") {
                    choice {
                        "++"; "--"
                    }
                }
            }

            rule("primary_expression") {
                choice {
                    ref("parenthesised_expression")
                    ref("identifier")
                    ref("float_literal")
                    ref("integer_literal")
                    ref("char_literal")
                    ref("string_literal")
                }
            }
            rule("parenthesised_expression") {
                seq {
                    "("
                    ref("expression")
                    ")"
                }
            }

            // Shared lexical core.
            rule("identifier") { token(identifierMatcher) }
            rule("integer_literal") { token(integerLiteralMatcher) }
            rule("float_literal") { token(floatLiteralMatcher) }
            rule("char_literal") { token(charLiteralMatcher) }
            rule("string_literal") { token(stringLiteralMatcher) }
        }
    }

    // MARK: - Expression grammar (directly left-recursive; ALL(*) only)

    /// Builds the directly left-recursive C expression grammar as a `Grammar` intermediate representation.
    ///
    /// The start rule `expr` is a directly left-recursive `.precedence`-annotated ladder over the full
    /// fifteen-level C operator hierarchy: postfix, unary/prefix and cast, then the eleven binary tiers,
    /// the right-associative conditional and assignment tiers, and the comma operator. It is intended for
    /// the ALL(*) engine, whose left-recursion rewriter turns it into a precedence-climbing operator loop;
    /// the other engines consume the grammar as authored and would not terminate on it.
    ///
    /// Precedence levels (higher binds more tightly), matching the C standard: comma `,` = 1 (left);
    /// assignment `= += …` = 2 (right); conditional `?:` = 3 (right); logical-or `||` = 4 (left);
    /// logical-and `&&` = 5 (left); bitwise-or `|` = 6 (left); bitwise-xor `^` = 7 (left); bitwise-and `&`
    /// = 8 (left); equality `== !=` = 9 (left); relational `< <= > >=` = 10 (left); shift `<< >>` = 11
    /// (left); additive `+ -` = 12 (left); multiplicative `* / %` = 13 (left); unary/prefix and cast = 14
    /// (right, re-entering at the unary level); postfix `() [] . -> ++ --` = 15 (left).
    /// - Returns: The left-recursive C expression grammar.
    public static func expressions() -> Grammar {
        Grammar(name: "c_expression", start: "expr", extras: extras) {
            rule("expr") {
                choice {
                    // Postfix operators (level 15) bind tightest. Each is an `expr op` form (no trailing
                    // self-reference), which the rewriter keeps as a left-associative postfix loop.
                    precedence(level: 15, associativity: .left) {
                        seq {
                            ref("expr")
                            "("
                            optional { field("arguments") { ref("argument_list") } }
                            ")"
                        }
                    }
                    precedence(level: 15, associativity: .left) {
                        seq {
                            ref("expr"); "["; field("index") { ref("expr") }; "]"
                        }
                    }
                    precedence(level: 15, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") {
                                choice {
                                    "."; "->"
                                }
                            }
                            field("name") { ref("identifier") }
                        }
                    }
                    precedence(level: 15, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") {
                                choice {
                                    "++"; "--"
                                }
                            }
                        }
                    }
                    // Binary tiers, tightest precedence first so earlier alternatives bind tighter. Each
                    // single-character operator that is a prefix of a longer C operator carries a maximal-
                    // munch boundary so `a * b` is not confused with `a *= b`, nor `a & b` with `a && b`.
                    precedence(level: 13, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") {
                                choice {
                                    op("*", notFollowedBy: ["="])
                                    op("/", notFollowedBy: ["="])
                                    op("%", notFollowedBy: ["="])
                                }
                            }
                            ref("expr")
                        }
                    }
                    precedence(level: 12, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") {
                                choice {
                                    op("+", notFollowedBy: ["+", "="])
                                    op("-", notFollowedBy: ["-", "=", ">"])
                                }
                            }
                            ref("expr")
                        }
                    }
                    precedence(level: 11, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") {
                                choice {
                                    op("<<", notFollowedBy: ["="])
                                    op(">>", notFollowedBy: ["="])
                                }
                            }
                            ref("expr")
                        }
                    }
                    precedence(level: 10, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") {
                                choice {
                                    "<="; ">="
                                    op("<", notFollowedBy: ["<", "="])
                                    op(">", notFollowedBy: [">", "="])
                                }
                            }
                            ref("expr")
                        }
                    }
                    precedence(level: 9, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") {
                                choice {
                                    "=="; "!="
                                }
                            }
                            ref("expr")
                        }
                    }
                    precedence(level: 8, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") { op("&", notFollowedBy: ["&", "="]) }
                            ref("expr")
                        }
                    }
                    precedence(level: 7, associativity: .left) {
                        seq {
                            ref("expr"); field("operator") { op("^", notFollowedBy: ["="]) }; ref("expr")
                        }
                    }
                    precedence(level: 6, associativity: .left) {
                        seq {
                            ref("expr")
                            field("operator") { op("|", notFollowedBy: ["|", "="]) }
                            ref("expr")
                        }
                    }
                    precedence(level: 5, associativity: .left) {
                        seq {
                            ref("expr"); field("operator") { "&&" }; ref("expr")
                        }
                    }
                    precedence(level: 4, associativity: .left) {
                        seq {
                            ref("expr"); field("operator") { "||" }; ref("expr")
                        }
                    }
                    // The conditional (ternary) operator (level 3) is right-associative. Its trailing
                    // self-reference (the else branch) is the right operand the rewriter re-enters at the
                    // same level, giving `a ? b : c ? d : e` the grouping `a ? b : (c ? d : e)`.
                    precedence(level: 3, associativity: .right) {
                        seq {
                            ref("expr")
                            "?"
                            field("consequence") { ref("expr") }
                            ":"
                            ref("expr")
                        }
                    }
                    // Assignment (level 2) is right-associative, so `a = b = c` groups as `a = (b = c)`.
                    precedence(level: 2, associativity: .right) {
                        seq {
                            ref("expr")
                            field("operator") {
                                choice {
                                    "<<="; ">>="; "+="; "-="; "*="; "/="; "%="; "&="; "^="; "|="
                                    // A bare `=` must not begin `==` (equality).
                                    op("=", notFollowedBy: ["="])
                                }
                            }
                            ref("expr")
                        }
                    }
                    // The comma operator (level 1) binds loosest and is left-associative.
                    precedence(level: 1, associativity: .left) {
                        seq {
                            ref("expr"); field("operator") { "," }; ref("expr")
                        }
                    }
                    // Prefix/unary operators (level 14) bind below postfix but above the binary tiers. The
                    // operand re-enters at the unary level so it absorbs only a tighter-binding postfix and
                    // refuses every binary operator, giving the correct `(-a) + b` and `*(p++)` groupings.
                    // The alternative does not lead with `expr`, so the rewriter keeps it as a primary.
                    seq {
                        field("operator") { ref("prefix_operator") }
                        precedence(level: 14, associativity: .right) { ref("expr") }
                    }
                    // A cast (level 14) is right-associative and re-enters at the unary level on its
                    // operand. The parenthesised thing is always a type keyword, never an identifier, which
                    // is what keeps the cast unambiguous against a parenthesised expression in this subset.
                    seq {
                        "("
                        field("type") { ref("type_name") }
                        ")"
                        precedence(level: 14, associativity: .right) { ref("expr") }
                    }
                    // `sizeof` of a parenthesised type name or of a unary-level operand.
                    seq {
                        keyword("sizeof")
                        choice {
                            seq {
                                "("
                                field("type") { ref("type_name") }
                                ")"
                            }
                            precedence(level: 14, associativity: .right) { ref("expr") }
                        }
                    }
                    // Primary (non-recursive) atoms.
                    ref("primary_expr")
                }
            }

            rule("prefix_operator") {
                choice {
                    "++"; "--"; "~"
                    // Each bare single-character prefix operator carries a maximal-munch boundary so the
                    // shared lexer does not split `++x` into `+ (+x)` or read `&x` as the start of `&&`.
                    op("+", notFollowedBy: ["+", "="])
                    op("-", notFollowedBy: ["-", "=", ">"])
                    op("!", notFollowedBy: ["="])
                    op("*", notFollowedBy: ["="])
                    op("&", notFollowedBy: ["&", "="])
                }
            }

            // A type name (used by casts and `sizeof`): a type specifier with optional pointer parts.
            rule("type_name") {
                seq {
                    field("type") { ref("type_specifier") }
                    repeat0 { ref("pointer") }
                }
            }
            rule("type_specifier") {
                seq {
                    optional { keyword("const") }
                    repeat1 { ref("type_keyword") }
                    optional { keyword("const") }
                }
            }
            rule("type_keyword") {
                choice {
                    // Each type keyword stands at a word boundary so it does not match the prefix of a
                    // longer identifier (for example the `int` of `intx`).
                    keyword("void"); keyword("char"); keyword("short"); keyword("int"); keyword("long")
                    keyword("float"); keyword("double"); keyword("signed"); keyword("unsigned")
                    keyword("_Bool")
                }
            }
            rule("pointer") {
                seq {
                    "*"
                    optional { keyword("const") }
                }
            }

            rule("argument_list") {
                seq {
                    ref("expr_no_comma")
                    repeat0 {
                        seq {
                            ","
                            ref("expr_no_comma")
                        }
                    }
                }
            }
            // A call argument is an assignment-level expression (the comma is the argument separator, not
            // the comma operator), so it re-enters the ladder at the assignment level.
            rule("expr_no_comma") {
                precedence(level: 2, associativity: .right) { ref("expr") }
            }

            rule("primary_expr") {
                choice {
                    ref("identifier")
                    ref("float_literal")
                    ref("integer_literal")
                    ref("char_literal")
                    ref("string_literal")
                    ref("paren_expr")
                }
            }
            rule("paren_expr") {
                seq {
                    "("
                    ref("expr")
                    ")"
                }
            }

            // Shared lexical core.
            rule("identifier") { token(identifierMatcher) }
            rule("integer_literal") { token(integerLiteralMatcher) }
            rule("float_literal") { token(floatLiteralMatcher) }
            rule("char_literal") { token(charLiteralMatcher) }
            rule("string_literal") { token(stringLiteralMatcher) }
        }
    }
}
