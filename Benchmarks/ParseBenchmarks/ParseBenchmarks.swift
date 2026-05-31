import Benchmark
import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR

// Performance benchmarks for the native parser engines. They are run by the package-benchmark plugin
// (`swift package benchmark`) and are not part of the shipped libraries. The metrics gathered are
// wall-clock time, throughput, total malloc count, and peak resident memory, so both speed and
// allocation behaviour are tracked against a saved baseline.
//
// The core of the suite is a parity matrix: the three native engines (recursive descent, GLR, ALL(*))
// parse the same large input for each of the three real languages, so their throughput and allocation can
// be compared directly. A small-input and an alternate-granularity case on the reference engine give a
// fast smoke signal. See BENCHMARKS.md for the methodology and the CI regression-threshold policy.

/// Builds a representative JSON document with the given number of array elements.
///
/// Each element is an object that exercises every value kind in the grammar (numbers, strings,
/// booleans, and a nested array), so the benchmark reflects realistic mixed input rather than a
/// single value kind.
/// - Parameter objectCount: The number of objects in the top-level array.
/// - Returns: A valid JSON document as text.
private func makeJSON(objectCount: Int) -> String {
    var elements: [String] = []
    elements.reserveCapacity(objectCount)
    for index in 0..<objectCount {
        let active = index % 2 == 0
        elements.append(
            #"{"id":\#(index),"name":"item-\#(index)","active":\#(active),"score":\#(Double(index) * 1.5),"tags":["alpha","beta","gamma"]}"#
        )
    }
    return "[" + elements.joined(separator: ",") + "]"
}

/// Builds a representative Lua source module with the given number of functions.
///
/// Each function exercises a spread of the grammar (local declarations, a numeric `for` loop, a table
/// constructor, an `if`/`else`, arithmetic and comparison expressions, a method call, and a line comment),
/// so the benchmark reflects realistic mixed Lua rather than a single construct.
/// - Parameter functionCount: The number of functions in the generated module.
/// - Returns: Valid Lua source as text.
private func makeLua(functionCount: Int) -> String {
    var parts: [String] = []
    parts.reserveCapacity(functionCount + 2)
    parts.append("-- Generated Lua module for benchmarking")
    parts.append("local M = {}")
    for index in 0..<functionCount {
        parts.append(
            """
            function M.process_\(index)(items, factor)
                -- accumulate a weighted sum over the items
                local total = 0
                for i = 1, #items do
                    local value = items[i] * factor + \(index)
                    if value > 0 and value <= 100 then
                        total = total + value
                    else
                        total = total - value
                    end
                end
                local config = { id = \(index), name = "process_\(index)", ratio = \(Double(index) * 1.5) }
                return M:finalise(total, config)
            end
            """)
    }
    parts.append("return M")
    return parts.joined(separator: "\n")
}

/// Builds a representative C translation unit with the given number of functions.
///
/// Each function exercises a spread of the grammar (typed parameters, local declarations, a `for` loop, an
/// `if`/`else`, arithmetic, comparison and assignment operators across several precedence tiers, a function
/// call, a pointer dereference, and a line comment), so the benchmark reflects realistic mixed C rather
/// than a single construct and stresses the deep operator ladder.
/// - Parameter functionCount: The number of functions in the generated translation unit.
/// - Returns: Valid C source as text.
private func makeC(functionCount: Int) -> String {
    var parts: [String] = []
    parts.reserveCapacity(functionCount + 2)
    parts.append("// Generated C translation unit for benchmarking")
    parts.append("int counter = 0;")
    for index in 0..<functionCount {
        parts.append(
            """
            int process_\(index)(int *items, int count, int factor) {
                // accumulate a weighted sum over the items
                int total = 0;
                for (int i = 0; i < count; i = i + 1) {
                    int value = items[i] * factor + \(index);
                    if (value > 0 && value <= 100) {
                        total += value;
                    } else {
                        total -= value;
                    }
                }
                counter = counter + total;
                return total >= 0 ? total : -total;
            }
            """)
    }
    parts.append("int total(void) { return counter; }")
    return parts.joined(separator: "\n")
}

/// A large input for each real language, built once and reused so generation never enters a measurement.
private let parityInputs: [(language: String, grammar: Grammar, source: Source)] = [
    ("JSON", JSONGrammar.grammar(), Source(makeJSON(objectCount: 1024))),
    ("Lua", LuaGrammar.chunk(), Source(makeLua(functionCount: 256))),
    ("C", CGrammar.translationUnit(), Source(makeC(functionCount: 256))),
]

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration.metrics = [
        .wallClock,
        .throughput,
        .mallocCountTotal,
        .peakMemoryResident,
    ]

    // The parity matrix: each native engine over the same large input per language. Engine construction is
    // outside `startMeasurement`, so only steady-state parsing of identical input is compared.
    for (language, grammar, source) in parityInputs {
        Benchmark("Parse large \(language) (recursive descent)") { benchmark in
            let engine = try UTF8Parser(grammar: grammar)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations { blackHole(engine.parse(source)) }
        }
        Benchmark("Parse large \(language) (GLR)") { benchmark in
            let engine = try UTF8GLRParser(grammar: grammar)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations { blackHole(engine.parse(source)) }
        }
        Benchmark("Parse large \(language) (ALL-star)") { benchmark in
            let engine = try ALLStarUTF8Parser(grammar: grammar)
            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations { blackHole(engine.parse(source)) }
        }
    }

    // Smoke signals on the reference engine: a small input and an alternate input granularity.
    let json = JSONGrammar.grammar()
    let smallJSON = Source(makeJSON(objectCount: 16))
    let largeJSON = Source(makeJSON(objectCount: 1024))

    Benchmark("Parse small JSON (recursive descent, 16 objects)") { benchmark in
        let engine = try UTF8Parser(grammar: json)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations { blackHole(engine.parse(smallJSON)) }
    }

    Benchmark("Parse large JSON (recursive descent, Unicode scalars)") { benchmark in
        let engine = try ScalarParser(grammar: json)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations { blackHole(engine.parse(largeJSON)) }
    }

    // Incremental reparse: a single late edit on a large document. The session reparse reuses the
    // unchanged prefix, so it should run far faster than a full parse of the edited document; the memory
    // metrics (configured above) capture the parsing state a session retains for the input's lifetime.
    let incrementalBase = makeJSON(objectCount: 1024)
    let incrementalBytes = Array(incrementalBase.utf8)
    let incrementalEditAt = max(0, incrementalBytes.count - 1)
    var incrementalEditedBytes = incrementalBytes
    incrementalEditedBytes.insert(0x20, at: incrementalEditAt)  // a late whitespace insertion, still valid JSON
    let incrementalEditedText = String(decoding: incrementalEditedBytes, as: UTF8.self)
    let incrementalEdit = TextEdit(
        startByte: incrementalEditAt, oldEndByte: incrementalEditAt, newEndByte: incrementalEditAt + 1)

    Benchmark("Reparse large JSON after a late edit (GLR full parse baseline)") { benchmark in
        let engine = try UTF8GLRParser(grammar: JSONGrammar.grammar())
        let edited = Source(incrementalEditedText)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations { blackHole(engine.parse(edited)) }
    }

    Benchmark("Reparse large JSON after a late edit (GLR incremental session)") { benchmark in
        let engine = try UTF8GLRParser(grammar: JSONGrammar.grammar())
        let original = Source(incrementalBase)
        let edited = Source(incrementalEditedText)
        let edits = [incrementalEdit]
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            let session = engine.incrementalParse(original)
            blackHole(session.reparse(edited, edits: edits))
        }
    }

}
