import Testing

import ParsingCore
import ParsingDSL

@testable import SwiftALLStar

@Suite("Engine metadata")
struct MetadataTests {
    @Test("Identifiers are derived per granularity")
    func identifiers() {
        #expect(ALLStarUTF8Parser.identifier == "allstar-utf8")
        #expect(ALLStarScalarParser.identifier == "allstar-scalar")
        #expect(ALLStarGraphemeParser.identifier == "allstar-grapheme")
    }

    @Test("Capabilities are lossless and error-recovering, but not ambiguous")
    func capabilities() {
        #expect(ALLStarUTF8Parser.capabilities.contains(.lossless))
        #expect(ALLStarUTF8Parser.capabilities.contains(.errorRecovering))
        #expect(!ALLStarUTF8Parser.capabilities.contains(.ambiguous))
    }

    @Test("An undefined start rule is rejected at construction")
    func undefinedStart() {
        let grammar = Grammar(name: "g", startRule: "missing", rules: ["s": .literal("a")])
        #expect(throws: GrammarError.undefinedStartRule("missing")) {
            _ = try ALLStarUTF8Parser(grammar: grammar)
        }
    }

    @Test("A directly left-recursive grammar constructs successfully")
    func directLeftRecursionConstructs() throws {
        let grammar = Grammar(name: "expr", startRule: "e", rules: [
            "e": .choice([
                .sequence([.reference("e"), .literal("+"), .reference("e")]),
                .token(name: "id", matcher: Match.oneOrMore(Match.letter), isNamed: true),
            ]),
        ])
        #expect(throws: Never.self) { _ = try ALLStarUTF8Parser(grammar: grammar) }
    }

    @Test("An indirectly left-recursive grammar is rejected")
    func indirectLeftRecursionRejected() {
        let grammar = Grammar(name: "g", startRule: "a", rules: [
            "a": .choice([.reference("b"), .literal("x")]),
            "b": .sequence([.reference("a"), .literal("y")]),
        ])
        #expect(throws: GrammarError.self) { _ = try ALLStarUTF8Parser(grammar: grammar) }
    }
}
