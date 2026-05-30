import ParsingCore

/// The Lua grammar, authored in the Swift DSL, targeting Lua 5.3/5.4 surface syntax.
///
/// Two grammars are exposed over one shared lexical core, because the framework's engines treat left
/// recursion differently. ``chunk()`` is the full structural grammar, authored free of left recursion so
/// it runs identically on the recursive-descent, GLR, and ALL(*) engines and anchors the byte-identical
/// three-engine differential. ``expressions()`` is a directly left-recursive expression ladder built with
/// the ``precedence(level:associativity:)`` combinator; it drives the ALL(*) engine's left-recursion
/// rewriter and proves precedence-climbing on a real language. Both share the lexical core: identifiers,
/// the four numeral forms, the three string forms with the full escape set, and the comment/whitespace
/// trivia.
///
/// Node-type and field names follow the Lua reference grammar and the tree-sitter `tree-sitter-lua`
/// conventions where practical, so a parsed tree reads naturally and queries are portable. Deeply nested
/// long-bracket comments and strings beyond the fixed `[[ ]]`, `[=[ ]=]`, and `[==[ ]==]` levels are out
/// of scope for this milestone and are not modelled.
public enum LuaGrammar {
    // MARK: - Lexical core

    /// A matcher for the first character of an identifier: an ASCII letter or underscore.
    private static var identifierStart: TokenMatcher {
        Match.oneOf(Match.letter, Match.lit("_"))
    }

    /// A matcher for a subsequent identifier character: an ASCII letter, digit, or underscore.
    private static var identifierContinue: TokenMatcher {
        Match.oneOf(Match.letter, Match.digit, Match.lit("_"))
    }

    /// The Lua reserved words, which an identifier may not equal.
    ///
    /// These are excluded from the identifier (`Name`) matcher so a keyword is never parsed as an
    /// identifier. That is essential for the lookahead-driven and exploratory engines, which would
    /// otherwise see a genuine ambiguity between a block-terminating keyword (such as `end`) and an
    /// identifier and either mispredict or fail.
    private static let reservedWords = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
        "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
    ]

    /// A zero-width assertion that the current position is at a word boundary: it is not followed by a
    /// further identifier-continuation character.
    ///
    /// Sequenced after a keyword literal, this turns `if` into a keyword only when it is not immediately
    /// followed by another identifier character, so `iffy` is read as a single identifier rather than the
    /// keyword `if` plus `fy`.
    private static var keywordBoundary: TokenMatcher {
        Match.notFollowedBy(identifierContinue)
    }

    /// A matcher that matches exactly one reserved word standing at a word boundary.
    ///
    /// It is the alternation of every reserved word, each followed by the ``keywordBoundary`` assertion, so
    /// it matches `and`, `break`, … only when the word is complete (not merely a prefix of a longer
    /// identifier such as `andy`). It is used as a negative lookahead in front of the identifier matcher to
    /// forbid an identifier that *is* a whole keyword while still admitting identifiers that contain or
    /// border one.
    private static var anyKeywordAtBoundary: TokenMatcher {
        .alternation(reservedWords.map { Match.seq(Match.lit($0), keywordBoundary) })
    }

    /// A matcher for a Lua identifier (`Name`): a letter or underscore then letters, digits, or underscores,
    /// excluding the reserved words.
    ///
    /// A leading negative lookahead rejects an identifier that is exactly a reserved word standing at a word
    /// boundary, so a keyword is never parsed as an identifier (which the lookahead and exploratory engines
    /// require to parse block boundaries unambiguously), while identifiers that merely contain, begin with,
    /// or end with a keyword (such as `ending`, `andy`, `_end`, or `iffy`) are still admitted. The keyword
    /// is matched as a literal in the structural positions that require it.
    private static var nameMatcher: TokenMatcher {
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

    /// A matcher for a Lua numeral: hex-float, hex-integer, decimal-float, or decimal-integer.
    ///
    /// The float forms are listed before the integer forms so the longer match (with a fractional part or
    /// exponent) is preferred by ordered choice.
    private static var numeralMatcher: TokenMatcher {
        // Hexadecimal float: 0x with hex digits and/or a hex fraction, optionally a binary exponent.
        let hexFloat = Match.seq(
            hexPrefix,
            Match.oneOf(
                // digits '.' [digits]
                Match.seq(hexDigits, Match.lit("."), Match.zeroOrMore(Match.hexDigit)),
                // '.' digits
                Match.seq(Match.lit("."), hexDigits),
                // digits (with a required binary exponent, handled below)
                hexDigits
            ),
            Match.optional(binaryExponent)
        )
        // A bare hex integer with a binary exponent is also a hex float (for example 0x1p4).
        let hexFloatExp = Match.seq(hexPrefix, hexDigits, binaryExponent)
        let hexInteger = Match.seq(hexPrefix, hexDigits)
        // Decimal float: digits '.' [digits] [exp] | '.' digits [exp] | digits exp.
        let decimalFloat = Match.oneOf(
            Match.seq(digits, Match.lit("."), Match.zeroOrMore(Match.digit), Match.optional(decimalExponent)),
            Match.seq(Match.lit("."), digits, Match.optional(decimalExponent)),
            Match.seq(digits, decimalExponent)
        )
        let decimalInteger = digits
        return Match.oneOf(hexFloatExp, hexFloat, hexInteger, decimalFloat, decimalInteger)
    }

    /// A matcher for one whitespace element a `\z` escape may skip: space, tab, newline, carriage return,
    /// form feed, or vertical tab.
    private static var skippableWhitespace: TokenMatcher {
        Match.oneOf(
            Match.lit(" "), Match.lit("\t"), Match.lit("\n"), Match.lit("\r"),
            Match.lit("\u{0C}"), Match.lit("\u{0B}"))
    }

    /// A matcher for one escape sequence inside a short (quoted) string.
    ///
    /// Covers the full Lua escape set: the single-character escapes `\a \b \f \n \r \t \v \\ \" \'`, the
    /// whitespace-skip `\z` (which consumes `z` then the run of whitespace, including newlines, that
    /// follows), a decimal escape `\ddd` (one to three digits), a hex escape `\xHH`, a Unicode escape
    /// `\u{...}`, and an escaped newline (line continuation).
    private static var escapeSequence: TokenMatcher {
        let backslash = Match.lit("\\")
        let simple = Match.oneOf(
            Match.lit("a"), Match.lit("b"), Match.lit("f"), Match.lit("n"), Match.lit("r"),
            Match.lit("t"), Match.lit("v"), Match.lit("\\"), Match.lit("\""),
            Match.lit("'"), Match.lit("\n"), Match.lit("\r")
        )
        // The `\z` whitespace-skip escape consumes `z` then zero or more following whitespace elements.
        let whitespaceSkip = Match.seq(Match.lit("z"), Match.zeroOrMore(skippableWhitespace))
        let hexEscape = Match.seq(Match.lit("x"), Match.hexDigit, Match.hexDigit)
        let unicodeEscape = Match.seq(
            Match.lit("u"), Match.lit("{"), Match.oneOrMore(Match.hexDigit), Match.lit("}"))
        // A decimal escape is one to three decimal digits.
        let decimalEscape = Match.seq(Match.digit, Match.optional(Match.digit), Match.optional(Match.digit))
        return Match.seq(
            backslash, Match.oneOf(hexEscape, unicodeEscape, whitespaceSkip, simple, decimalEscape))
    }

    /// A matcher for the body of a short string delimited by `quote`.
    ///
    /// The body is any run of escape sequences and non-delimiter, non-backslash, non-newline elements.
    /// - Parameter quote: The delimiter character (`"` or `'`).
    /// - Returns: A matcher for the run of content between the delimiters (not including them).
    private static func shortStringBody(quote: String) -> TokenMatcher {
        let ordinary = Match.not(
            Match.oneOf(Match.lit(quote), Match.lit("\\"), Match.lit("\n"), Match.lit("\r")))
        return Match.zeroOrMore(Match.oneOf(escapeSequence, ordinary))
    }

    /// A matcher for a complete short string delimited by `quote`.
    /// - Parameter quote: The delimiter character (`"` or `'`).
    /// - Returns: A matcher for the whole quoted string, including its delimiters.
    private static func shortString(quote: String) -> TokenMatcher {
        Match.seq(Match.lit(quote), shortStringBody(quote: quote), Match.lit(quote))
    }

    /// A matcher for a long-bracket string at one fixed level (`open` ... `close`).
    ///
    /// The body is any run of elements not starting the closing delimiter; long-bracket strings are raw
    /// (no escape processing).
    /// - Parameters:
    ///   - open: The opening delimiter (for example `"[[`", `"[=["`).
    ///   - close: The closing delimiter (for example `"]]"`, `"]=]"`).
    /// - Returns: A matcher for the whole long-bracket string, including its delimiters.
    private static func longBracketString(open: String, close: String) -> TokenMatcher {
        Match.seq(
            Match.lit(open),
            Match.zeroOrMore(Match.not(Match.lit(close))),
            Match.lit(close))
    }

    /// A matcher for any Lua string literal: the two short forms then the fixed long-bracket levels.
    ///
    /// The long-bracket levels are tried from the longest delimiter to the shortest so `[==[` is not
    /// mistaken for `[=[` followed by a `[`.
    private static var stringMatcher: TokenMatcher {
        Match.oneOf(
            shortString(quote: "\""),
            shortString(quote: "'"),
            longBracketString(open: "[==[", close: "]==]"),
            longBracketString(open: "[=[", close: "]=]"),
            longBracketString(open: "[[", close: "]]")
        )
    }

    /// The trivia matchers permitted between tokens: whitespace, line comments, and block comments.
    ///
    /// Block comments are listed before line comments so `--[[` is taken as a block comment rather than a
    /// line comment beginning with `--`. The block-comment levels are tried longest-delimiter first.
    private static var extras: [TokenMatcher] {
        [
            .builtin(.whitespace),
            blockComment(open: "--[==[", close: "]==]"),
            blockComment(open: "--[=[", close: "]=]"),
            blockComment(open: "--[[", close: "]]"),
            lineComment("--"),
        ]
    }

    // MARK: - Structural grammar (left-recursion-free; all three engines)

    /// Builds the full structural Lua grammar as a `Grammar` intermediate representation.
    ///
    /// The grammar is authored without left recursion: the expression layer uses the iterative
    /// `tier ((op) tier)*` style and the prefix-expression layer uses a primary followed by a repeated
    /// suffix, so it parses identically on the recursive-descent, GLR, and ALL(*) engines. The start rule
    /// is `chunk`.
    /// - Returns: The structural Lua grammar.
    public static func chunk() -> Grammar {
        Grammar(name: "lua", start: "chunk", extras: extras) {
            rule("chunk") { ref("block") }

            // A block is a run of statements followed by an optional return statement.
            rule("block") {
                seq {
                    repeat0 { ref("statement") }
                    optional { ref("return_statement") }
                }
            }

            rule("return_statement") {
                seq {
                    "return"
                    optional { ref("expression_list") }
                    optional { ";" }
                }
            }

            // Statements, ordered so keyword-led forms are tried before the assignment/call fallback.
            rule("statement") {
                choice {
                    ref("empty_statement")
                    ref("break_statement")
                    ref("goto_statement")
                    ref("label_statement")
                    ref("do_statement")
                    ref("while_statement")
                    ref("repeat_statement")
                    ref("if_statement")
                    ref("for_numeric_statement")
                    ref("for_generic_statement")
                    ref("function_declaration")
                    ref("local_function_statement")
                    ref("local_declaration")
                    ref("assignment_statement")
                    ref("call_statement")
                }
            }

            rule("empty_statement") { ";" }
            rule("break_statement") { "break" }
            rule("goto_statement") {
                seq {
                    "goto"
                    field("label") { ref("name") }
                }
            }
            rule("label_statement") {
                seq {
                    "::"
                    field("name") { ref("name") }
                    "::"
                }
            }

            rule("do_statement") {
                seq {
                    "do"
                    ref("block")
                    "end"
                }
            }

            rule("while_statement") {
                seq {
                    "while"
                    field("condition") { ref("expression") }
                    "do"
                    field("body") { ref("block") }
                    "end"
                }
            }

            rule("repeat_statement") {
                seq {
                    "repeat"
                    field("body") { ref("block") }
                    "until"
                    field("condition") { ref("expression") }
                }
            }

            rule("if_statement") {
                seq {
                    "if"
                    field("condition") { ref("expression") }
                    "then"
                    field("consequence") { ref("block") }
                    repeat0 { ref("elseif_clause") }
                    optional { ref("else_clause") }
                    "end"
                }
            }
            rule("elseif_clause") {
                seq {
                    "elseif"
                    field("condition") { ref("expression") }
                    "then"
                    field("consequence") { ref("block") }
                }
            }
            rule("else_clause") {
                seq {
                    "else"
                    field("body") { ref("block") }
                }
            }

            rule("for_numeric_statement") {
                seq {
                    "for"
                    field("name") { ref("name") }
                    "="
                    field("start") { ref("expression") }
                    ","
                    field("limit") { ref("expression") }
                    optional {
                        seq {
                            ","
                            field("step") { ref("expression") }
                        }
                    }
                    "do"
                    field("body") { ref("block") }
                    "end"
                }
            }

            rule("for_generic_statement") {
                seq {
                    "for"
                    field("names") { ref("name_list") }
                    "in"
                    field("values") { ref("expression_list") }
                    "do"
                    field("body") { ref("block") }
                    "end"
                }
            }

            rule("function_declaration") {
                seq {
                    "function"
                    field("name") { ref("function_name") }
                    field("body") { ref("function_body") }
                }
            }
            // A dotted function name with an optional trailing method (`:name`) part.
            rule("function_name") {
                seq {
                    ref("name")
                    repeat0 {
                        seq {
                            "."
                            ref("name")
                        }
                    }
                    optional {
                        seq {
                            ":"
                            ref("name")
                        }
                    }
                }
            }

            rule("local_function_statement") {
                seq {
                    "local"
                    "function"
                    field("name") { ref("name") }
                    field("body") { ref("function_body") }
                }
            }

            rule("local_declaration") {
                seq {
                    "local"
                    field("names") { ref("attributed_name_list") }
                    optional {
                        seq {
                            "="
                            field("values") { ref("expression_list") }
                        }
                    }
                }
            }
            rule("attributed_name_list") {
                seq {
                    ref("attributed_name")
                    repeat0 {
                        seq {
                            ","
                            ref("attributed_name")
                        }
                    }
                }
            }
            // A name with an optional 5.4 attribute (`<const>` or `<close>`).
            rule("attributed_name") {
                seq {
                    ref("name")
                    optional { ref("attribute") }
                }
            }
            rule("attribute") {
                seq {
                    "<"
                    field("name") { ref("name") }
                    ">"
                }
            }

            // var ( ',' var )* '=' explist
            rule("assignment_statement") {
                seq {
                    field("targets") { ref("variable_list") }
                    "="
                    field("values") { ref("expression_list") }
                }
            }
            rule("variable_list") {
                seq {
                    ref("variable")
                    repeat0 {
                        seq {
                            ","
                            ref("variable")
                        }
                    }
                }
            }

            // A function-call statement. In Lua a statement expression must be a call (a bare name is not a
            // statement), so this requires the prefix expression to end in a call or method-call. That also
            // keeps the block's statement loop from consuming a block-terminating keyword as a bare name.
            rule("call_statement") { ref("function_call") }

            // MARK: Expression layer (iterative ladder, lowest to highest precedence)

            rule("expression") { ref("or_expression") }

            rule("or_expression") {
                seq {
                    ref("and_expression")
                    repeat0 {
                        seq {
                            "or"
                            ref("and_expression")
                        }
                    }
                }
            }
            rule("and_expression") {
                seq {
                    ref("comparison_expression")
                    repeat0 {
                        seq {
                            "and"
                            ref("comparison_expression")
                        }
                    }
                }
            }
            rule("comparison_expression") {
                seq {
                    ref("bitwise_or_expression")
                    repeat0 {
                        seq {
                            choice {
                                "<="; ">="; "~="; "=="; "<"; ">"
                            }
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
                            "|"
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
                            "~"
                            ref("bitwise_and_expression")
                        }
                    }
                }
            }
            rule("bitwise_and_expression") {
                seq {
                    ref("shift_expression")
                    repeat0 {
                        seq {
                            "&"
                            ref("shift_expression")
                        }
                    }
                }
            }
            rule("shift_expression") {
                seq {
                    ref("concat_expression")
                    repeat0 {
                        seq {
                            choice {
                                "<<"; ">>"
                            }
                            ref("concat_expression")
                        }
                    }
                }
            }
            // Concatenation is right-associative in Lua; the iterative form parses the same token run and
            // round-trips identically, which is all the structural (all-engine) grammar must guarantee.
            rule("concat_expression") {
                seq {
                    ref("additive_expression")
                    repeat0 {
                        seq {
                            ".."
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
                                "+"; "-"
                            }
                            ref("multiplicative_expression")
                        }
                    }
                }
            }
            rule("multiplicative_expression") {
                seq {
                    ref("unary_expression")
                    repeat0 {
                        seq {
                            choice {
                                "//"; "*"; "/"; "%"
                            }
                            ref("unary_expression")
                        }
                    }
                }
            }
            rule("unary_expression") {
                choice {
                    seq {
                        choice {
                            "not"; "#"; "-"; "~"
                        }
                        ref("unary_expression")
                    }
                    ref("power_expression")
                }
            }
            // Power is right-associative in Lua and binds tighter than unary operators. The right operand is
            // a unary expression (which recurses into a further power), so a single optional operator gives
            // an unambiguous right-leaning chain that all three engines agree on.
            rule("power_expression") {
                seq {
                    ref("primary_expression")
                    optional {
                        seq {
                            "^"
                            ref("unary_expression")
                        }
                    }
                }
            }

            rule("primary_expression") {
                choice {
                    ref("nil")
                    ref("true")
                    ref("false")
                    ref("vararg_expression")
                    ref("number")
                    ref("string")
                    ref("function_expression")
                    ref("table_constructor")
                    ref("prefix_expression")
                }
            }

            rule("nil") { "nil" }
            rule("true") { "true" }
            rule("false") { "false" }
            rule("vararg_expression") { "..." }

            rule("function_expression") {
                seq {
                    "function"
                    ref("function_body")
                }
            }

            // A prefix expression: a primary atom (a name or a parenthesised expression) then zero or more
            // index, field, call, or method-call suffixes. This is the left-recursion-free factoring of the
            // Lua `prefixexp` / `var` / `functioncall` cluster.
            rule("prefix_expression") {
                seq {
                    ref("prefix_atom")
                    repeat0 { ref("prefix_suffix") }
                }
            }
            rule("prefix_atom") {
                choice {
                    ref("name")
                    ref("parenthesised_expression")
                }
            }
            rule("parenthesised_expression") {
                seq {
                    "("
                    ref("expression")
                    ")"
                }
            }
            rule("prefix_suffix") {
                choice {
                    ref("index_suffix")
                    ref("field_suffix")
                    ref("method_call_suffix")
                    ref("call_suffix")
                }
            }

            // A function call: an atom, optional non-call (index/field) suffixes, then one or more call
            // groups, so the whole expression provably ends in a call. The non-call suffixes are kept out of
            // the trailing-call requirement (they cannot consume a call), which keeps the form unambiguous on
            // the greedy recursive-descent engine.
            rule("function_call") {
                seq {
                    ref("prefix_atom")
                    repeat0 { ref("access_suffix") }
                    ref("call_part")
                    repeat0 {
                        seq {
                            repeat0 { ref("access_suffix") }
                            ref("call_part")
                        }
                    }
                }
            }
            rule("access_suffix") {
                choice {
                    ref("index_suffix")
                    ref("field_suffix")
                }
            }
            rule("call_part") {
                choice {
                    ref("method_call_suffix")
                    ref("call_suffix")
                }
            }

            rule("index_suffix") {
                seq {
                    "["
                    ref("expression")
                    "]"
                }
            }
            rule("field_suffix") {
                seq {
                    "."
                    field("name") { ref("name") }
                }
            }
            rule("method_call_suffix") {
                seq {
                    ":"
                    field("method") { ref("name") }
                    field("arguments") { ref("arguments") }
                }
            }
            rule("call_suffix") {
                field("arguments") { ref("arguments") }
            }

            // Call arguments: a parenthesised list, a single table constructor, or a single string.
            rule("arguments") {
                choice {
                    seq {
                        "("
                        optional { ref("expression_list") }
                        ")"
                    }
                    ref("table_constructor")
                    ref("string")
                }
            }

            // An assignment target: a name or a prefix expression ending in an index or field access.
            rule("variable") { ref("prefix_expression") }

            rule("function_body") {
                seq {
                    "("
                    optional { ref("parameter_list") }
                    ")"
                    ref("block")
                    "end"
                }
            }
            rule("parameter_list") {
                choice {
                    seq {
                        ref("name")
                        repeat0 {
                            seq {
                                ","
                                ref("name")
                            }
                        }
                        optional {
                            seq {
                                ","
                                ref("vararg_expression")
                            }
                        }
                    }
                    ref("vararg_expression")
                }
            }

            rule("name_list") {
                seq {
                    ref("name")
                    repeat0 {
                        seq {
                            ","
                            ref("name")
                        }
                    }
                }
            }
            rule("expression_list") {
                seq {
                    ref("expression")
                    repeat0 {
                        seq {
                            ","
                            ref("expression")
                        }
                    }
                }
            }

            // A table constructor: fields separated by `,` or `;`, with an optional trailing separator.
            rule("table_constructor") {
                seq {
                    "{"
                    optional {
                        seq {
                            ref("field_entry")
                            repeat0 {
                                seq {
                                    ref("field_separator")
                                    ref("field_entry")
                                }
                            }
                            optional { ref("field_separator") }
                        }
                    }
                    "}"
                }
            }
            rule("field_separator") {
                choice {
                    ","; ";"
                }
            }
            rule("field_entry") {
                choice {
                    ref("keyed_field")
                    ref("named_field")
                    ref("positional_field")
                }
            }
            // [exp] = exp
            rule("keyed_field") {
                seq {
                    "["
                    field("key") { ref("expression") }
                    "]"
                    "="
                    field("value") { ref("expression") }
                }
            }
            // Name = exp
            rule("named_field") {
                seq {
                    field("name") { ref("name") }
                    "="
                    field("value") { ref("expression") }
                }
            }
            // exp
            rule("positional_field") {
                field("value") { ref("expression") }
            }

            // Shared lexical core.
            rule("name") { token(nameMatcher) }
            rule("number") { token(numeralMatcher) }
            rule("string") { token(stringMatcher) }
        }
    }

    // MARK: - Expression grammar (directly left-recursive; ALL(*) only)

    /// Builds the directly left-recursive Lua expression grammar as a `Grammar` intermediate representation.
    ///
    /// The start rule `exp` is a directly left-recursive `.precedence`-annotated ladder over the eight Lua
    /// binary-operator tiers plus unary operators and the right-associative power tier. It is intended for
    /// the ALL(*) engine, whose left-recursion rewriter turns it into a precedence-climbing operator loop;
    /// the other engines consume the grammar as authored and would not terminate on it. Concatenation (`..`)
    /// and exponentiation (`^`) are right-associative; the other binary operators are left-associative.
    ///
    /// Precedence levels (higher binds more tightly): `or` = 1, `and` = 2, comparison = 3, bitwise-or = 4,
    /// bitwise-xor = 5, bitwise-and = 6, shift = 7, concatenation = 8, additive = 9, multiplicative = 10,
    /// unary = 11, power = 12.
    /// - Returns: The left-recursive Lua expression grammar.
    public static func expressions() -> Grammar {
        Grammar(name: "lua_expression", start: "exp", extras: extras) {
            rule("exp") {
                choice {
                    // Binary tiers, tightest precedence first so earlier alternatives bind tighter.
                    precedence(level: 12, associativity: .right) {
                        seq {
                            ref("exp"); field("operator") { "^" }; ref("exp")
                        }
                    }
                    precedence(level: 10, associativity: .left) {
                        seq {
                            ref("exp");
                            field("operator") {
                                choice {
                                    "//"; "*"; "/"; "%"
                                }
                            }; ref("exp")
                        }
                    }
                    precedence(level: 9, associativity: .left) {
                        seq {
                            ref("exp");
                            field("operator") {
                                choice {
                                    "+"; "-"
                                }
                            }; ref("exp")
                        }
                    }
                    precedence(level: 8, associativity: .right) {
                        seq {
                            ref("exp"); field("operator") { ".." }; ref("exp")
                        }
                    }
                    precedence(level: 7, associativity: .left) {
                        seq {
                            ref("exp");
                            field("operator") {
                                choice {
                                    "<<"; ">>"
                                }
                            }; ref("exp")
                        }
                    }
                    precedence(level: 6, associativity: .left) {
                        seq {
                            ref("exp"); field("operator") { "&" }; ref("exp")
                        }
                    }
                    precedence(level: 5, associativity: .left) {
                        seq {
                            ref("exp"); field("operator") { "~" }; ref("exp")
                        }
                    }
                    precedence(level: 4, associativity: .left) {
                        seq {
                            ref("exp"); field("operator") { "|" }; ref("exp")
                        }
                    }
                    precedence(level: 3, associativity: .left) {
                        seq {
                            ref("exp")
                            field("operator") {
                                choice {
                                    "<="; ">="; "~="; "=="; "<"; ">"
                                }
                            }
                            ref("exp")
                        }
                    }
                    precedence(level: 2, associativity: .left) {
                        seq {
                            ref("exp"); field("operator") { "and" }; ref("exp")
                        }
                    }
                    precedence(level: 1, associativity: .left) {
                        seq {
                            ref("exp"); field("operator") { "or" }; ref("exp")
                        }
                    }
                    // Unary operators (level 11) bind below power but above the binary tiers. The alternative
                    // is authored inline so its operand is a self-reference to `exp`; wrapping that operand to
                    // re-enter at precedence 12 makes it absorb only a tighter-binding `^` and refuse every
                    // binary operator, giving the correct `(not a) == b`, `(- a) + b`, and `-(2 ^ 2)`
                    // groupings. It does not lead with `exp`, so the rewriter keeps it as a primary.
                    seq {
                        ref("unary_operator")
                        precedence(level: 12, associativity: .none) { ref("exp") }
                    }
                    // Primary (non-recursive) atoms.
                    ref("primary_exp")
                }
            }

            rule("unary_operator") {
                field("operator") {
                    choice {
                        "not"; "#"; "-"; "~"
                    }
                }
            }

            rule("primary_exp") {
                choice {
                    ref("nil")
                    ref("true")
                    ref("false")
                    ref("number")
                    ref("string")
                    ref("name")
                    ref("paren_exp")
                }
            }
            rule("paren_exp") {
                seq {
                    "("
                    ref("exp")
                    ")"
                }
            }
            rule("nil") { "nil" }
            rule("true") { "true" }
            rule("false") { "false" }

            // Shared lexical core.
            rule("name") { token(nameMatcher) }
            rule("number") { token(numeralMatcher) }
            rule("string") { token(stringMatcher) }
        }
    }
}
