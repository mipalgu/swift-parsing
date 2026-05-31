import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftGLR
import Testing

/// Incremental reparse tests for the GLR engine.
///
/// The governing correctness property is that an incremental reparse is byte-for-byte a full reparse: the
/// only difference is that unchanged subtrees keep the previous tree's node identities instead of being
/// re-allocated. The suite pins that equality across insertions, deletions and replacements on the JSON and
/// Lua grammars, confirms that a localised edit genuinely reuses the untouched subtrees, and checks the
/// capability flag and the no-op short-circuit.
@Suite("GLR incremental reparse")
struct IncrementalTests {
    /// Derives the minimal single edit that turns `old` into `new` by trimming the common byte prefix and
    /// suffix, mirroring how an editor would report a localised change.
    static func edit(from old: String, to new: String) -> TextEdit {
        let oldBytes = Array(old.utf8)
        let newBytes = Array(new.utf8)
        var start = 0
        while start < oldBytes.count, start < newBytes.count, oldBytes[start] == newBytes[start] {
            start += 1
        }
        var oldEnd = oldBytes.count
        var newEnd = newBytes.count
        while oldEnd > start, newEnd > start, oldBytes[oldEnd - 1] == newBytes[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        return TextEdit(startByte: start, oldEndByte: oldEnd, newEndByte: newEnd)
    }

    /// Every distinct green-node identity in a subtree, used to measure reuse across a reparse.
    static func identities(_ node: GreenNode) -> Set<ObjectIdentifier> {
        var result: Set<ObjectIdentifier> = [ObjectIdentifier(node)]
        for child in node.children { result.formUnion(identities(child.node)) }
        return result
    }

    /// Asserts that reparsing `old` edited to `new` equals a full parse of `new` and round-trips.
    private func expectReparseMatchesFullParse(grammar: Grammar, old: String, new: String) throws {
        let engine = try UTF8GLRParser(grammar: grammar)
        let previous = engine.parse(Source(old))
        let editList = [Self.edit(from: old, to: new)]
        let incremental = engine.reparse(Source(new), edits: editList, previous: previous)
        let full = engine.parse(Source(new))

        #expect(
            incremental.tree.green.isEquivalent(to: full.tree.green),
            "incremental tree differs from a full parse of \(new.debugDescription)")
        #expect(incremental.sExpression() == full.sExpression())
        #expect(incremental.tree.green.reconstructedText == new)
        #expect(incremental.hasErrors == full.hasErrors)
    }

    @Test(
        "Reparsing an edited JSON document equals a full parse",
        arguments: [
            (#"{"a": 1, "b": 2, "c": 3}"#, #"{"a": 1, "b": 20, "c": 3}"#),  // replace a value
            (#"{"a": 1, "b": 2, "c": 3}"#, #"{"a": 1, "c": 3}"#),  // delete a pair
            (#"{"a": 1, "c": 3}"#, #"{"a": 1, "b": 2, "c": 3}"#),  // insert a pair
            (#"[1, 2, 3, 4, 5]"#, #"[1, 2, 30, 4, 5]"#),  // replace inside an array
            (#"{"x": [true, false]}"#, #"{"x": [true, false, null]}"#),  // nested insertion
        ])
    func jsonReparse(_ pair: (old: String, new: String)) throws {
        try expectReparseMatchesFullParse(grammar: JSONGrammar.grammar(), old: pair.old, new: pair.new)
    }

    @Test(
        "Reparsing an edited Lua chunk equals a full parse",
        arguments: [
            ("local a = 1\nlocal b = 2\nlocal c = 3\n", "local a = 1\nlocal b = 22\nlocal c = 3\n"),
            ("local a = 1\nlocal b = 2\nlocal c = 3\n", "local a = 1\nlocal c = 3\n"),
            ("local a = 1\nlocal c = 3\n", "local a = 1\nlocal b = 2\nlocal c = 3\n"),
            ("x = f(1)\ny = g(2)\nz = h(3)\n", "x = f(1)\ny = g(2, 4)\nz = h(3)\n"),
            ("if c then return 1 end\nx = 2\n", "if c then return 10 end\nx = 2\n"),
        ])
    func luaReparse(_ pair: (old: String, new: String)) throws {
        try expectReparseMatchesFullParse(grammar: LuaGrammar.chunk(), old: pair.old, new: pair.new)
    }

    @Test("A localised edit reuses the overwhelming majority of subtrees by identity")
    func localisedEditReusesSubtrees() throws {
        let engine = try UTF8GLRParser(grammar: LuaGrammar.chunk())
        // Twenty statements, one of which is edited: the other nineteen and their many descendants must be
        // reused, so reuse should dominate the tree rather than touch only a few coincidental leaves.
        let statements = (1...20).map { "local v\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let new = statements.replacingOccurrences(of: "local v10 = 10", with: "local v10 = 999")
        let previous = engine.parse(Source(statements))
        let incremental = engine.reparse(Source(new), edits: [Self.edit(from: statements, to: new)], previous: previous)

        let newNodes = Self.identities(incremental.tree.green)
        let reused = newNodes.intersection(Self.identities(previous.tree.green))
        let fraction = Double(reused.count) / Double(newNodes.count)
        #expect(fraction > 0.8, "expected most of the tree to be reused, reused \(reused.count)/\(newNodes.count)")
        #expect(incremental.sExpression() == engine.parse(Source(new)).sExpression())
        #expect(incremental.tree.green.isEquivalent(to: engine.parse(Source(new)).tree.green))
    }

    @Test("Reparsing an unchanged source with no edits returns the previous result")
    func noOpReparseReturnsPrevious() throws {
        let engine = try UTF8GLRParser(grammar: JSONGrammar.grammar())
        let source = Source(#"{"a": 1, "b": 2}"#)
        let previous = engine.parse(source)
        let again = engine.reparse(source, edits: [], previous: previous)
        #expect(again.tree.green === previous.tree.green)
    }

    @Test("The GLR engine advertises the incremental capability; the reference engine does not")
    func capabilityFlags() {
        #expect(UTF8GLRParser.capabilities.contains(.incremental))
        #expect(!UTF8Parser.capabilities.contains(.incremental))
    }

    @Test("The reference engine's default reparse is a correct full parse")
    func referenceReparseFallsBackToFullParse() throws {
        let engine = try UTF8Parser(grammar: JSONGrammar.grammar())
        let previous = engine.parse(Source(#"{"a": 1}"#))
        let new = #"{"a": 2}"#
        let reparsed = engine.reparse(Source(new), edits: [Self.edit(from: #"{"a": 1}"#, to: new)], previous: previous)
        #expect(reparsed.sExpression() == engine.parse(Source(new)).sExpression())
        #expect(reparsed.tree.green.reconstructedText == new)
    }
}
