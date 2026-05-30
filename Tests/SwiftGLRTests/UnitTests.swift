import Testing

import ParsingCore
import ParsingDSL
@testable import SwiftGLR

@Suite("Grammar flattening")
struct GrammarFlattenerTests {
    @Test("The JSON grammar flattens to productions with an augmented start")
    func jsonFlattens() {
        let flattener = GrammarFlattener(grammar: JSONGrammar.grammar())
        #expect(!flattener.productions.isEmpty)
        // The augmented accept production reduces the user start followed by end-of-input.
        let accept = flattener.productions[flattener.acceptProduction]
        #expect(accept.rhs.count == 2)
        #expect(accept.rhs.last == .endOfInput)
        if case .nonterminal(let nt) = accept.rhs.first {
            #expect(nt == flattener.userStart)
        } else {
            Issue.record("the accept production should start with the user start nonterminal")
        }
    }

    @Test("Underscore-prefixed rules are transparent, named rules are opaque")
    func emitClassification() {
        let flattener = GrammarFlattener(grammar: JSONGrammar.grammar())
        func emit(of name: String) -> Emit? {
            guard let nt = flattener.nonterminalNames.firstIndex(of: name) else { return nil }
            return flattener.productions.first { $0.lhs == nt }?.emit
        }
        // `_value` is hidden, so its productions splice.
        if case .transparent = emit(of: "_value") {} else { Issue.record("_value should be transparent") }
        // `object` and `pair` are named, so they wrap.
        if case .opaque = emit(of: "object") {} else { Issue.record("object should be opaque") }
        if case .opaque = emit(of: "pair") {} else { Issue.record("pair should be opaque") }
    }

    @Test("Terminals are deduplicated")
    func terminalDedup() {
        // Two rules referencing the same literal share one terminal.
        let grammar = Grammar(
            name: "g", startRule: "s",
            rules: ["s": .sequence([.literal(","), .literal(",")])])
        let flattener = GrammarFlattener(grammar: grammar)
        let commas = flattener.terminals.filter { $0.kindName == "," }
        #expect(commas.count == 1)
    }
}

@Suite("Automaton construction")
struct LR0AutomatonTests {
    @Test("The JSON grammar parses without recording any genuine ambiguity")
    func jsonHasNoAmbiguity() throws {
        // Right-nulled reductions can place more than one reduce action in a cell (an epsilon repetition
        // beside a right-nulled completion); these converge on the same interned forest node rather than
        // forking. The meaningful property is that no JSON parse records an ambiguity warning.
        let grammar = JSONGrammar.grammar()
        for input in [#"{ "a": 1 }"#, #"[1, 2, 3]"#, #"{"o": {"a": [1, 2]}}"#, "{}", "[]"] {
            let result = try UTF8GLRParser(grammar: grammar).parse(Source(input))
            #expect(!result.diagnostics.contains { $0.severity == .warning }, "input \(input)")
        }
    }

    @Test("Right-nulled reductions are present for nullable optional tails")
    func rightNulledReductions() {
        let tables = GLRTables(grammar: JSONGrammar.grammar())
        var sawNullableSuffix = false
        for state in 0..<tables.stateCount {
            for (_, actions) in tables.reduce[state] {
                if actions.contains(where: { !$0.nullableSuffix.isEmpty }) { sawNullableSuffix = true }
            }
        }
        #expect(sawNullableSuffix)
    }

    @Test("The start state shifts the structural opening tokens")
    func startStateShifts() {
        let tables = GLRTables(grammar: JSONGrammar.grammar())
        let shiftable = Set(tables.shiftableTerminals(state: tables.startState))
        // The opening brace and bracket of object/array are shiftable from the start.
        let braceID = tables.terminals.firstIndex { $0.kindName == "{" }
        let bracketID = tables.terminals.firstIndex { $0.kindName == "[" }
        #expect(braceID.map { shiftable.contains($0) } == true)
        #expect(bracketID.map { shiftable.contains($0) } == true)
    }
}

@Suite("Scannerless lexer")
struct LexerTests {
    private func makeLexer(_ text: String) -> (Lexer<Substring.UTF8View>, GLRTables) {
        let tables = GLRTables(grammar: JSONGrammar.grammar())
        let input = Substring.UTF8View.make(from: text)
        return (Lexer(input: input, terminals: tables.terminals, extras: tables.extras), tables)
    }

    @Test("Trivia is consumed identically to the reference convention")
    func triviaConsumption() {
        let (lexer, _) = makeLexer("   \n\ttrue")
        let input = Substring.UTF8View.make(from: "   \n\ttrue")
        let (end, trivia) = lexer.consumeTrivia(at: input.startIndex)
        #expect(trivia == "   \n\t")
        #expect(Substring.UTF8View.text(of: input[end..<input.endIndex]) == "true")
    }

    @Test("Longest-match selection keeps a multi-digit number whole")
    func longestMatch() throws {
        // The JSON number token is anonymous (its `number` node comes from the rule reference), so the
        // terminal carrying the multi-digit matcher matches the whole run greedily.
        let tables = GLRTables(grammar: JSONGrammar.grammar())
        let (lexer, _) = makeLexer("100")
        let input = Substring.UTF8View.make(from: "100")
        let all = Set(0..<tables.terminals.count)
        let (matches, _, _) = lexer.candidates(at: input.startIndex, expected: all)
        let longest = matches.max { $0.byteLength < $1.byteLength }
        #expect(longest?.text == "100")
    }

    @Test("Only expected terminals are recognised")
    func stateDirected() {
        let tables = GLRTables(grammar: JSONGrammar.grammar())
        let trueID = tables.terminals.firstIndex { $0.kindName == "true" }!
        let (lexer, _) = makeLexer("true")
        let input = Substring.UTF8View.make(from: "true")
        // With only `true` expected, the matcher recognises it.
        let (matches, _, _) = lexer.candidates(at: input.startIndex, expected: Set([trueID]))
        #expect(matches.count == 1)
        // With nothing expected, there are no candidates.
        let (none, _, _) = lexer.candidates(at: input.startIndex, expected: [])
        #expect(none.isEmpty)
    }
}

@Suite("Graph-structured stack")
struct GSSTests {
    @Test("At most one vertex per state per level (merging invariant)")
    func merging() {
        let gss = GSS()
        let (a, newA) = gss.node(state: 5, level: 0)
        let (b, newB) = gss.node(state: 5, level: 0)
        #expect(newA)
        #expect(!newB)
        #expect(a === b)
    }

    @Test("Edges are deduplicated")
    func edgeDedup() {
        let gss = GSS()
        let sppf = SPPF()
        let leaf = sppf.epsilonNode(at: 0)
        let (top, _) = gss.node(state: 1, level: 1)
        let (bottom, _) = gss.node(state: 0, level: 0)
        #expect(gss.addEdge(from: top, to: bottom, sppf: leaf))
        #expect(!gss.addEdge(from: top, to: bottom, sppf: leaf))
        #expect(top.edges.count == 1)
    }

    @Test("Reduction paths enumerate the labels in right-hand-side order")
    func pathEnumeration() {
        let gss = GSS()
        let sppf = SPPF()
        let (v0, _) = gss.node(state: 0, level: 0)
        let (v1, _) = gss.node(state: 1, level: 1)
        let (v2, _) = gss.node(state: 2, level: 2)
        let first = sppf.epsilonNode(at: 0)
        let second = sppf.epsilonNode(at: 1)
        gss.addEdge(from: v1, to: v0, sppf: first)
        gss.addEdge(from: v2, to: v1, sppf: second)
        let paths = gss.paths(from: v2, length: 2)
        #expect(paths.count == 1)
        #expect(paths[0].labels.count == 2)
        // Bottom-to-top order: the deeper edge's label comes first.
        #expect(paths[0].labels[0] === first)
        #expect(paths[0].labels[1] === second)
        #expect(paths[0].base === v0)
    }
}

@Suite("Shared packed parse forest")
struct SPPFTests {
    @Test("Nonterminal nodes are interned by symbol and span")
    func interning() {
        let sppf = SPPF()
        let (a, newA) = sppf.nonterminalNode(nt: 3, start: 0, end: 4)
        let (b, newB) = sppf.nonterminalNode(nt: 3, start: 0, end: 4)
        #expect(newA)
        #expect(!newB)
        #expect(a === b)
    }

    @Test("Distinct derivations add packed families and dedupe identical ones")
    func packing() {
        let sppf = SPPF()
        let (node, _) = sppf.nonterminalNode(nt: 1, start: 0, end: 2)
        let child = sppf.epsilonNode(at: 0)
        sppf.addFamily(to: node, production: 0, children: [child])
        sppf.addFamily(to: node, production: 0, children: [child])  // duplicate, ignored
        sppf.addFamily(to: node, production: 1, children: [child])  // distinct derivation
        #expect(node.families.count == 2)
    }

    @Test("Epsilon nodes are zero-width")
    func epsilonZeroWidth() {
        let sppf = SPPF()
        let node = sppf.epsilonNode(at: 7)
        #expect(node.start == 7)
        #expect(node.end == 7)
    }
}
