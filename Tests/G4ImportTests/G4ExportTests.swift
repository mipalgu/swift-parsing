import G4Import
import ParsingCore
import RecursiveDescent
import Testing

/// Round-trip property tests for the `.g4` exporter.
///
/// The governing property is `import → export → import` identity: importing `.g4` text yields a grammar
/// IR, exporting that IR yields `.g4` text, and importing that text yields a grammar IR equal to the
/// first. Equality is structural (`Grammar` is `Hashable`), so a single passing case pins the node kinds,
/// fields, precedence tiers, character-set lowering, and trivia exactly. The corpus exercises every
/// construct the importer supports: references, string literals, character sets and ranges, the dot
/// wildcard, `~` negation, the `?`/`*`/`+` quantifiers, parenthesised and nested groups, element-label
/// fields, directly left-recursive precedence ladders with `<assoc=right>`, lexer rules, and `-> skip`
/// trivia.
@Suite("G4 export round-trip")
struct G4ExportTests {
    /// The grammars whose import → export → import identity must hold, by descriptive name.
    static let grammars: [(name: String, source: String)] = [
        ("json", G4Grammar.jsonGrammar),
        (
            "arithmetic precedence",
            """
            grammar Arith;
            e :<assoc=right> e '^' e | e '*' e | e '+' e | INT ;
            INT : [0-9]+ ;
            """
        ),
        (
            "power and minus",
            """
            grammar PM;
            e :<assoc=right> e '^' e | e '-' e | INT ;
            INT : [0-9]+ ;
            """
        ),
        (
            "antlr documented example",
            """
            grammar G;
            e : e '*' e | e '+' e |<assoc=right> e '?' e ':' e |<assoc=right> e '=' e | INT ;
            INT : [0-9]+ ;
            """
        ),
        (
            "fields and groups",
            """
            grammar Fields;
            call : name=ID '(' args=( expr ( ',' expr )* )? ')' ;
            expr : ID | NUMBER ;
            ID : [a-zA-Z_] [a-zA-Z0-9_]* ;
            NUMBER : [0-9]+ ;
            """
        ),
        (
            "inline sets, dot and negation",
            """
            grammar Inline;
            atom : [a-z]+ | . | ~'x' | ~[0-9] ;
            """
        ),
        (
            "skip trivia and comments",
            """
            grammar Trivia;
            program : stmt* ;
            stmt : ID ';' ;
            ID : [a-zA-Z]+ ;
            WS : [ \\t\\r\\n]+ -> skip ;
            LINE_COMMENT : '//' ~[\\r\\n]* -> skip ;
            """
        ),
        (
            "optional and nested repetition",
            """
            grammar Nested;
            list : '[' ( item ( ',' item )* )? ']' ;
            item : sign? NUMBER ;
            NUMBER : [0-9]+ ;
            sign : '+' | '-' ;
            """
        ),
    ]

    @Test("import, export and re-import yields an equal grammar", arguments: grammars.map(\.name))
    func roundTripIsIdentity(_ name: String) throws {
        let source = try #require(Self.grammars.first { $0.name == name }).source
        let imported = try G4Grammar.grammar(fromString: source)
        let exported = G4Grammar.export(imported)
        let reimported = try G4Grammar.grammar(fromString: exported)
        #expect(
            reimported == imported,
            """
            round-trip changed the grammar for \(name).
            exported .g4:
            \(exported)
            """)
    }

    @Test("export is idempotent across a second round-trip", arguments: grammars.map(\.name))
    func exportIsIdempotent(_ name: String) throws {
        let source = try #require(Self.grammars.first { $0.name == name }).source
        let imported = try G4Grammar.grammar(fromString: source)
        let firstExport = G4Grammar.export(imported)
        let secondExport = G4Grammar.export(try G4Grammar.grammar(fromString: firstExport))
        #expect(firstExport == secondExport, "export of \(name) was not stable across a round-trip")
    }

    @Test("a re-imported grammar parses identically to the original")
    func reimportedGrammarParsesIdentically() throws {
        let original = try G4Grammar.grammar(fromString: G4Grammar.jsonGrammar)
        let reimported = try G4Grammar.grammar(fromString: G4Grammar.export(original))
        for input in [#"{ "a": 1 }"#, "[1, true, null]", #"{"nested": [false, "x"]}"#, "garbage"] {
            let before = try UTF8Parser(grammar: original).parse(Source(input))
            let after = try UTF8Parser(grammar: reimported).parse(Source(input))
            #expect(before.sExpression() == after.sExpression(), "parse diverged for: \(input)")
            #expect(after.tree.green.reconstructedText == input)
        }
    }
}
