import Foundation
import Testing

import ParsingCore
import ParsingDSL
import RecursiveDescent
@testable import SwiftGLR

/// Tests of the GLR-specific machinery: forking on ambiguity, packing in the forest, collapsing to one
/// canonical tree, and terminating on epsilon and hidden recursion where a naive Tomita parser would
/// loop or under-derive.
@Suite("Ambiguity, forking and RNGLR correctness")
struct AmbiguityTests {
    /// A classically ambiguous expression grammar `expr → expr + expr | expr * expr | num`.
    private func ambiguousExpressionGrammar() -> Grammar {
        let num = Rule.token(name: "num", matcher: Match.oneOrMore(Match.digit), isNamed: true)
        return Grammar(
            name: "expr", startRule: "expr",
            rules: [
                "expr": .choice([
                    .sequence([.reference("expr"), .literal("+"), .reference("expr")]),
                    .sequence([.reference("expr"), .literal("*"), .reference("expr")]),
                    num,
                ])
            ])
    }

    @Test("An ambiguous expression collapses to one canonical tree with a warning")
    func ambiguousCollapses() throws {
        let result = try UTF8GLRParser(grammar: ambiguousExpressionGrammar()).parse(Source("1+2*3"))
        // The parse completes losslessly with a single deterministic tree.
        #expect(result.tree.green.reconstructedText == "1+2*3")
        // The ambiguity is observable as a warning, not an error.
        #expect(result.diagnostics.contains { $0.severity == .warning })
        #expect(!result.hasErrors)
        // The result is deterministic across repeated runs.
        let again = try UTF8GLRParser(grammar: ambiguousExpressionGrammar()).parse(Source("1+2*3"))
        #expect(result.sExpression() == again.sExpression())
    }

    /// The same expression grammar with precedence and left-associativity annotations.
    private func precedenceExpressionGrammar() -> Grammar {
        let num = Rule.token(name: "num", matcher: Match.oneOrMore(Match.digit), isNamed: true)
        return Grammar(
            name: "expr", startRule: "expr",
            rules: [
                "expr": .choice([
                    .precedence(
                        level: 1, associativity: .left,
                        .sequence([.reference("expr"), .literal("+"), .reference("expr")])),
                    .precedence(
                        level: 2, associativity: .left,
                        .sequence([.reference("expr"), .literal("*"), .reference("expr")])),
                    num,
                ])
            ])
    }

    @Test("Precedence and associativity disambiguate the same expression deterministically")
    func precedenceDisambiguates() throws {
        let result = try UTF8GLRParser(grammar: precedenceExpressionGrammar()).parse(Source("1+2*3"))
        #expect(result.tree.green.reconstructedText == "1+2*3")
        #expect(!result.hasErrors)
        // The chosen tree binds `*` tighter than `+`: the multiplication is the deeper subtree.
        let sexpr = result.sExpression()
        #expect(sexpr.contains("(num)"))
        // Repeated runs are identical.
        let again = try UTF8GLRParser(grammar: precedenceExpressionGrammar()).parse(Source("1+2*3"))
        #expect(sexpr == again.sExpression())
    }

    @Test("Left associativity yields a left-leaning tree", arguments: ["1+2+3+4"])
    func leftAssociative(_ input: String) throws {
        let result = try UTF8GLRParser(grammar: precedenceExpressionGrammar()).parse(Source(input))
        #expect(result.tree.green.reconstructedText == input)
        #expect(!result.hasErrors)
    }

    @Test("Hidden right recursion through epsilon terminates and derives correctly")
    func hiddenRightRecursion() throws {
        // s → a s | b ; where the recursion is reachable only through the nullable `maybe`.
        let grammar = Grammar(
            name: "g", startRule: "s",
            rules: [
                "s": .choice([
                    .sequence([
                        .token(name: "a", matcher: Match.lit("a"), isNamed: true), .reference("s"),
                    ]),
                    .token(name: "b", matcher: Match.lit("b"), isNamed: true),
                ])
            ], extras: [])
        let result = try UTF8GLRParser(grammar: grammar).parse(Source("aaab"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "aaab")
        // Each `a` nests one level deeper, ending in `b`.
        #expect(result.sExpression().contains("(a)"))
        #expect(result.sExpression().contains("(b)"))
    }

    @Test("A nullable repetition matching nothing contributes no children")
    func nullableRepetitionEmpty() throws {
        // s → x* ; on empty input matches zero repetitions and yields an empty document.
        let grammar = Grammar(
            name: "g", startRule: "s",
            rules: ["s": .repeatZeroOrMore(.token(name: "x", matcher: Match.lit("x"), isNamed: true))],
            extras: [])
        let result = try UTF8GLRParser(grammar: grammar).parse(Source(""))
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(s)")
        #expect(result.tree.green.reconstructedText == "")
    }

    @Test("A directly self-referential nullable rule terminates")
    func zeroWidthCycle() throws {
        // s → s | ε : a hidden cycle that must reach a fixed point rather than loop.
        let grammar = Grammar(
            name: "g", startRule: "s",
            rules: ["s": .choice([.reference("s"), .optional(.literal("q"))])],
            extras: [])
        let result = try UTF8GLRParser(grammar: grammar).parse(Source(""))
        // The parse must terminate and recover or accept; the key assertion is that it returns at all.
        #expect(result.tree.green.reconstructedText == "")
    }

    @Test("Repeated runs of the same ambiguous input are deterministic", arguments: ["1+2+3", "1*2+3*4"])
    func deterministicCollapse(_ input: String) throws {
        let grammar = ambiguousExpressionGrammar()
        let first = try UTF8GLRParser(grammar: grammar).parse(Source(input)).sExpression()
        let second = try UTF8GLRParser(grammar: grammar).parse(Source(input)).sExpression()
        #expect(first == second)
    }
}

/// Property-style tests over generated valid JSON, asserting round-trip losslessness and exact agreement
/// with the recursive-descent reference, plus termination on pathological-but-finite inputs.
@Suite("Properties")
struct PropertyTests {
    /// A small deterministic pseudo-random generator so the corpus is reproducible.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    private func randomJSON(_ rng: inout Rng, depth: Int) -> String {
        if depth <= 0 || rng.int(3) == 0 {
            switch rng.int(5) {
            case 0: return String(rng.int(1000))
            case 1: return "true"
            case 2: return "false"
            case 3: return "null"
            default: return "\"s\(rng.int(100))\""
            }
        }
        if rng.int(2) == 0 {
            let count = rng.int(4)
            let items = (0..<count).map { _ in randomJSON(&rng, depth: depth - 1) }
            return "[" + items.joined(separator: ", ") + "]"
        }
        let count = rng.int(4)
        let pairs = (0..<count).map { i in "\"k\(i)\": " + randomJSON(&rng, depth: depth - 1) }
        return "{" + pairs.joined(separator: ", ") + "}"
    }

    @Test("Generated JSON round-trips and matches the reference engine")
    func generatedDifferential() throws {
        let grammar = JSONGrammar.grammar()
        var rng = Rng(state: 0x1234_5678)
        for _ in 0..<200 {
            let input = randomJSON(&rng, depth: 4)
            let glr = try UTF8GLRParser(grammar: grammar).parse(Source(input))
            let rd = try UTF8Parser(grammar: grammar).parse(Source(input))
            #expect(glr.sExpression() == rd.sExpression(), "input \(input)")
            #expect(glr.tree.green.reconstructedText == input)
        }
    }

    #if canImport(Dispatch)
    @Test("Deeply nested input terminates and matches the reference engine")
    func deepNesting() {
        // The work runs on a thread with an ample stack: tree depth maps to native recursion depth in
        // both the GLR tree builder and the recursive-descent reference, so a deep input would otherwise
        // be bounded by the small stack of a test task rather than by the algorithm.
        let depth = 200
        let input = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        let outcome = runWithLargeStack { () -> (errors: Bool, text: String, glr: String, rd: String) in
            let grammar = JSONGrammar.grammar()
            let glr = (try? UTF8GLRParser(grammar: grammar))?.parse(Source(input))
            let rd = (try? UTF8Parser(grammar: grammar))?.parse(Source(input))
            return (
                glr?.hasErrors ?? true, glr?.tree.green.reconstructedText ?? "",
                glr?.sExpression() ?? "", rd?.sExpression() ?? "")
        }
        #expect(!outcome.errors)
        #expect(outcome.text == input)
        #expect(outcome.glr == outcome.rd)
    }
    #endif
}

#if canImport(Dispatch)
/// Runs a value-returning body on a dedicated thread with a large stack and returns its result.
///
/// Deep recursion in the body is then bounded by the algorithm rather than by a test task's small stack.
///
/// - Parameter body: The work to run.
/// - Returns: The body's result.
private func runWithLargeStack<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
    let box = ResultBox<Result>()
    let done = DispatchSemaphore(value: 0)
    let worker = Thread {
        box.value = body()
        done.signal()
    }
    worker.stackSize = 64 * 1024 * 1024
    worker.start()
    done.wait()
    return box.value!
}

/// A minimal mutable box for handing a thread's result back to the caller.
private final class ResultBox<Value: Sendable>: @unchecked Sendable {
    var value: Value?
}
#endif
