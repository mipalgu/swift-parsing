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

/// A large document together with a single, small edit applied late in the text, used to contrast an
/// incremental reparse against a full reparse.
///
/// The edit rewrites the numeric `id` of the very last object, so the first changed byte sits near the
/// end of the source. An incremental session can therefore reuse almost the entire verified token prefix
/// and re-derive only the short suffix, whereas a full parse must re-process the whole document.
private struct LateEditFixture {
    /// The original document, before the edit.
    let original: Source
    /// The document after the edit has been applied.
    let edited: Source
    /// The single edit, expressed in UTF-8 byte offsets.
    let edit: TextEdit

    /// Builds the fixture for the given JSON document, replacing one substring late in the text.
    /// - Parameter objectCount: The number of objects in the generated JSON document.
    init(objectCount: Int) {
        let base = makeJSON(objectCount: objectCount)
        // The last object contains the substring `"id":<n>` with <n> equal to `objectCount - 1`.
        // Replacing that number with a longer one produces a small edit near the end of the document.
        let needle = #""id":\#(objectCount - 1),"#
        let replacement = #""id":\#(objectCount + 1_000_000),"#
        guard let range = base.range(of: needle, options: .backwards) else {
            self.original = Source(base)
            self.edited = Source(base)
            self.edit = TextEdit(startByte: 0, oldEndByte: 0, newEndByte: 0)
            return
        }
        // Convert the substring range to UTF-8 byte offsets, matching the engine's byte-offset contract.
        let startByte = base.utf8.distance(from: base.utf8.startIndex, to: range.lowerBound.samePosition(in: base.utf8)!)
        let oldEndByte = startByte + needle.utf8.count
        let newEndByte = startByte + replacement.utf8.count

        self.original = Source(base)
        self.edited = Source(base.replacingCharacters(in: range, with: replacement))
        self.edit = TextEdit(startByte: startByte, oldEndByte: oldEndByte, newEndByte: newEndByte)
    }
}

/// A large JSON document with a single small edit late in the text, built once and reused so document
/// generation never enters a measurement.
private let incrementalFixture = LateEditFixture(objectCount: 4096)

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

    // Incremental reparse versus a full reparse. The fixture is a large JSON document with a single small
    // edit placed late in the text, so an incremental session reuses the verified token prefix up to the
    // first changed byte and re-derives only the short suffix. Memory metrics are part of the default set,
    // but they are listed explicitly on the incremental cases to record that the session's per-input-size
    // checkpoint retention is what is measured there. Engine construction stays outside the timer, as
    // elsewhere; the GLR engine is shared by the baseline and the incremental cases for a like-for-like cost.

    // Baseline: every iteration parses the edited document from scratch, as a non-incremental client would
    // after each keystroke.
    Benchmark("Reparse large JSON (GLR, full parse baseline)") { benchmark in
        let engine = try UTF8GLRParser(grammar: json)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations { blackHole(engine.parse(incrementalFixture.edited)) }
    }

    // Incremental: a fresh session over the original document is established outside the timer, then only the
    // single late edit's reparse is measured. A session is single use, so it is rebuilt each closure
    // invocation; one reparse per invocation keeps the comparison against the baseline direct.
    Benchmark(
        "Reparse large JSON (GLR, incremental single late edit)",
        configuration: .init(
            metrics: [.wallClock, .throughput, .mallocCountTotal, .peakMemoryResident],
            scalingFactor: .one
        )
    ) { benchmark in
        let engine = try UTF8GLRParser(grammar: json)
        let session = engine.incrementalParse(incrementalFixture.original)
        benchmark.startMeasurement()
        let reparsed = session.reparse(incrementalFixture.edited, edits: [incrementalFixture.edit])
        blackHole(reparsed.result)
        benchmark.stopMeasurement()
    }

    // Reference: the cost, and the memory footprint, of establishing the initial incremental session before
    // any edit is applied. Together with the two cases above this isolates the marginal cost of one reparse.
    Benchmark(
        "Parse large JSON (GLR, incremental initial session)",
        configuration: .init(
            metrics: [.wallClock, .throughput, .mallocCountTotal, .peakMemoryResident],
            scalingFactor: .one
        )
    ) { benchmark in
        let engine = try UTF8GLRParser(grammar: json)
        benchmark.startMeasurement()
        let session = engine.incrementalParse(incrementalFixture.original)
        blackHole(session.result)
        benchmark.stopMeasurement()
    }

}
