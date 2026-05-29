import Foundation
import Testing

import ParsingCore
import ParsingDSL
import RecursiveDescent
@testable import GrammarImport

@Suite("grammar.json round-trip")
struct RoundTripTests {
    @Test("JSON grammar survives export -> import and still parses identically")
    func jsonGrammarRoundTrip() throws {
        // Anonymous token names are not part of the tree-sitter encoding, so an exact IR round-trip is
        // not expected; instead the re-imported grammar must be *semantically* equivalent: it parses
        // the same inputs to the same trees.
        let original = JSONGrammar.grammar()
        let exported = try TreeSitterGrammarJSON.export(original)
        let reimported = try TreeSitterGrammarJSON.grammar(from: exported, startRule: original.startRule)
        for input in [#"{ "a": 1 }"#, #"[1, "x", true, null]"#, "-2.5e10", "{}"] {
            let before = try UTF8Parser(grammar: original).parse(Source(input)).sExpression()
            let after = try UTF8Parser(grammar: reimported).parse(Source(input)).sExpression()
            #expect(before == after, "mismatch for \(input)")
        }
    }

    @Test("A grammar of structural rules and literal tokens round-trips exactly")
    func allFormsRoundTrip() throws {
        // Literal tokens, structural rules and round-trippable matchers (built-in classes) preserve
        // their IR exactly through grammar.json.
        let rules: [String: Rule] = [
            "s": .sequence([
                .reference("kw"),
                .optional(.literal("?")),
                .repeatZeroOrMore(.literal("x")),
                .repeatOneOrMore(.literal("y")),
                .field("f", .reference("kw")),
                .choice([.literal("a"), .literal("b")]),
                .precedence(level: 2, associativity: .left, .literal("l")),
                .precedence(level: 3, associativity: .right, .literal("r")),
                .precedence(level: 1, associativity: .none, .literal("n")),
            ]),
            "kw": .literal("kw"),
        ]
        let g = Grammar(name: "all", startRule: "s", rules: rules, extras: [.builtin(.whitespace), .literal("//")])
        let exported = try TreeSitterGrammarJSON.export(g)
        let reimported = try TreeSitterGrammarJSON.grammar(from: exported, startRule: "s")
        #expect(reimported == g)
    }
}

@Suite("grammar.json import")
struct ImportTests {
    @Test("Imports the tree-sitter rule vocabulary, including optional and aliases")
    func vocabulary() throws {
        let json = """
        {
          "name": "demo",
          "rules": {
            "s": { "type": "SEQ", "members": [
              { "type": "SYMBOL", "name": "kw" },
              { "type": "CHOICE", "members": [ { "type": "STRING", "value": "x" }, { "type": "BLANK" } ] },
              { "type": "REPEAT", "content": { "type": "STRING", "value": "r" } },
              { "type": "REPEAT1", "content": { "type": "STRING", "value": "o" } },
              { "type": "FIELD", "name": "f", "content": { "type": "PATTERN", "value": "[a-z]+" } },
              { "type": "PREC_DYNAMIC", "value": 5, "content": { "type": "STRING", "value": "d" } },
              { "type": "TOKEN", "content": { "type": "STRING", "value": "t" } },
              { "type": "IMMEDIATE_TOKEN", "content": { "type": "STRING", "value": "i" } },
              { "type": "ALIAS", "named": true, "value": "renamed", "content": { "type": "SYMBOL", "name": "kw" } },
              { "type": "BLANK" }
            ] },
            "kw": { "type": "STRING", "value": "kw" }
          },
          "extras": [ { "type": "PATTERN", "value": "\\\\s+" }, { "type": "SYMBOL", "name": "comment" } ]
        }
        """
        let g = try TreeSitterGrammarJSON.grammar(fromString: json, startRule: "s")
        #expect(g.name == "demo")
        #expect(g.startRule == "s")
        // The SYMBOL extra (comment) is dropped; the PATTERN extra is kept and lowered to a matcher.
        #expect(g.extras == [.repeated(min: 1, max: nil, .builtin(.whitespace))])

        guard case let .sequence(parts) = g.rules["s"] else {
            Issue.record("s should be a sequence")
            return
        }
        #expect(parts[0] == .reference("kw"))
        #expect(parts[1] == .optional(.literal("x")))         // CHOICE[x, BLANK] -> optional
        #expect(parts[2] == .repeatZeroOrMore(.literal("r")))
        #expect(parts[3] == .repeatOneOrMore(.literal("o")))
        #expect(parts[5] == .precedence(level: 5, associativity: .none, .literal("d"))) // PREC_DYNAMIC
        #expect(parts[6] == .literal("t"))                    // TOKEN unwraps to content
        #expect(parts[7] == .literal("i"))                    // IMMEDIATE_TOKEN unwraps to content
        #expect(parts[8] == .reference("kw"))                 // ALIAS unwraps to content
        #expect(parts[9] == .sequence([]))                    // standalone BLANK
    }

    @Test("Defaults extras to whitespace when absent")
    func defaultExtras() throws {
        let json = #"{ "name": "x", "rules": { "s": { "type": "STRING", "value": "a" } } }"#
        let g = try TreeSitterGrammarJSON.grammar(fromString: json, startRule: "s")
        #expect(g.extras == [.builtin(.whitespace)])
    }
}

@Suite("grammar.json import errors")
struct ImportErrorTests {
    @Test("Top-level non-object is rejected")
    func notAnObject() {
        #expect(throws: TreeSitterGrammarJSON.ImportError.notAnObject) {
            try TreeSitterGrammarJSON.grammar(fromString: "[1, 2, 3]", startRule: "s")
        }
    }

    @Test("Missing rules object is rejected")
    func missingRules() {
        #expect(throws: TreeSitterGrammarJSON.ImportError.missingRules) {
            try TreeSitterGrammarJSON.grammar(fromString: #"{ "name": "x" }"#, startRule: "s")
        }
    }

    @Test("Unknown rule type is rejected")
    func unknownType() {
        let json = #"{ "rules": { "s": { "type": "WEIRD" } } }"#
        #expect(throws: TreeSitterGrammarJSON.ImportError.unknownRuleType("WEIRD")) {
            try TreeSitterGrammarJSON.grammar(fromString: json, startRule: "s")
        }
    }

    @Test("Rule without a type is rejected")
    func missingType() {
        let json = #"{ "rules": { "s": { "name": "no type here" } } }"#
        #expect(throws: TreeSitterGrammarJSON.ImportError.missingRuleType) {
            try TreeSitterGrammarJSON.grammar(fromString: json, startRule: "s")
        }
    }

    @Test("Content-bearing rule without content is rejected")
    func missingContent() {
        let json = #"{ "rules": { "s": { "type": "REPEAT" } } }"#
        #expect(throws: TreeSitterGrammarJSON.ImportError.missingRuleType) {
            try TreeSitterGrammarJSON.grammar(fromString: json, startRule: "s")
        }
    }
}

@Suite("grammar.json defensive handling")
struct DefensiveTests {
    @Test("Missing names/values and empty members fall back gracefully")
    func defensiveFallbacks() throws {
        let json = """
        {
          "rules": {
            "s": { "type": "SEQ", "members": [
              { "type": "SYMBOL" },
              { "type": "STRING" },
              { "type": "PATTERN" },
              { "type": "FIELD", "content": { "type": "BLANK" } },
              { "type": "SEQ" },
              { "type": "PREC", "value": 2.5, "content": { "type": "BLANK" } }
            ] }
          },
          "extras": [ "not-a-dict", { "no": "type" } ]
        }
        """
        let g = try TreeSitterGrammarJSON.grammar(fromString: json, startRule: "s")
        guard case let .sequence(parts) = g.rules["s"] else {
            Issue.record("s should be a sequence")
            return
        }
        #expect(parts[0] == .reference(""))                        // SYMBOL without name
        #expect(parts[1] == .literal(""))                          // STRING without value
        #expect(parts[2] == .token(name: "", matcher: .literal(""), isNamed: false)) // PATTERN without value
        #expect(parts[3] == .field("", .sequence([])))             // FIELD without name
        #expect(parts[4] == .sequence([]))                         // SEQ without members
        #expect(parts[5] == .precedence(level: 2, associativity: .none, .sequence([]))) // fractional value
        #expect(g.extras.isEmpty)                                  // both malformed extras dropped
    }

    @Test("A precedence without a value defaults to level zero")
    func precedenceWithoutValue() throws {
        let json = #"{ "rules": { "s": { "type": "PREC_LEFT", "content": { "type": "STRING", "value": "a" } } } }"#
        let g = try TreeSitterGrammarJSON.grammar(fromString: json, startRule: "s")
        #expect(g.rules["s"] == .precedence(level: 0, associativity: .left, .literal("a")))
    }

    @Test("A non-object rule member is rejected")
    func nonObjectMember() {
        let json = #"{ "rules": { "s": { "type": "SEQ", "members": [ 5 ] } } }"#
        #expect(throws: TreeSitterGrammarJSON.ImportError.missingRuleType) {
            try TreeSitterGrammarJSON.grammar(fromString: json, startRule: "s")
        }
    }

    @Test("exportString produces valid JSON text")
    func exportStringText() throws {
        let text = try TreeSitterGrammarJSON.exportString(JSONGrammar.grammar())
        #expect(text.contains("\"rules\""))
        #expect(text.contains("\"document\""))
        // The text must itself be re-importable into a semantically equivalent grammar.
        let g = try TreeSitterGrammarJSON.grammar(fromString: text, startRule: "document")
        let sample = #"{ "a": [1, true] }"#
        #expect(try UTF8Parser(grammar: g).parse(Source(sample)).sExpression()
            == UTF8Parser(grammar: JSONGrammar.grammar()).parse(Source(sample)).sExpression())
    }
}

@Suite("grammar.json real-world import")
struct RealWorldTests {
    /// Imports a genuine, vendored tree-sitter grammar.json if present beside the package, proving the
    /// importer copes with a large real grammar. Skipped when the vendored reference is unavailable.
    @Test("Imports the vendored tree-sitter-go grammar.json")
    func vendoredGo() throws {
        let path = "../rust/tree-sitter/tree-sitter-go/src/grammar.json"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let g = try TreeSitterGrammarJSON.grammar(from: data, startRule: "source_file")
        #expect(g.name == "go")
        #expect(g.rules.count > 100)
        #expect(g.rules["source_file"] != nil)
    }
}
