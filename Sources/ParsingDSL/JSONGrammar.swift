import ParsingCore

/// The JSON grammar, authored in the Swift DSL.
///
/// Rule and node-type names deliberately mirror the tree-sitter `tree-sitter-json` grammar
/// (`document`, `object`, `pair`, `array`, `string`, `string_content`, `number`, `true`,
/// `false`, `null`) so that the native engine and the tree-sitter backend can be compared by
/// exact S-expression equality in differential tests. For the first milestone, strings are
/// modelled without escape sequences (a documented simplification); inputs in the differential
/// corpus avoid escapes accordingly.
public enum JSONGrammar {
    /// Builds the JSON grammar as a `Grammar` intermediate representation.
    /// - Returns: The JSON grammar.
    public static func grammar() -> Grammar {
        Grammar(name: "json", start: "document") {
            rule("document") { ref("_value") }

            // `_value` is hidden (leading underscore): it splices the chosen value into its parent
            // rather than introducing a `(value ...)` wrapper node.
            rule("_value") {
                choice {
                    ref("object")
                    ref("array")
                    ref("string")
                    ref("number")
                    ref("true")
                    ref("false")
                    ref("null")
                }
            }

            rule("object") {
                seq {
                    "{"
                    optional {
                        seq {
                            ref("pair")
                            repeat0 {
                                seq {
                                    ","; ref("pair")
                                }
                            }
                        }
                    }
                    "}"
                }
            }

            rule("pair") {
                seq {
                    field("key") {
                        choice {
                            ref("string"); ref("number")
                        }
                    }
                    ":"
                    field("value") { ref("_value") }
                }
            }

            rule("array") {
                seq {
                    "["
                    optional {
                        seq {
                            ref("_value")
                            repeat0 {
                                seq {
                                    ","; ref("_value")
                                }
                            }
                        }
                    }
                    "]"
                }
            }

            rule("string") {
                seq {
                    "\""
                    optional { ref("string_content") }
                    "\""
                }
            }

            // No escape sequences in the first milestone: content is any run of non-quote elements.
            // The token is anonymous; the named `string_content` node comes from this rule's reference.
            rule("string_content") { token(Match.oneOrMore(Match.not(Match.lit("\"")))) }

            // number = -?(0 | [1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?  — expressed with matchers, no regex.
            rule("number") {
                token(
                    Match.seq(
                        Match.optional(Match.lit("-")),
                        Match.oneOf(Match.lit("0"), Match.seq(Match.range("1", "9"), Match.zeroOrMore(Match.digit))),
                        Match.optional(Match.seq(Match.lit("."), Match.oneOrMore(Match.digit))),
                        Match.optional(
                            Match.seq(
                                Match.oneOf(Match.lit("e"), Match.lit("E")),
                                Match.optional(Match.oneOf(Match.lit("+"), Match.lit("-"))),
                                Match.oneOrMore(Match.digit)
                            ))
                    ))
            }

            rule("true") { "true" }
            rule("false") { "false" }
            rule("null") { "null" }
        }
    }
}
