import Benchmark
import ParsingCore
import ParsingDSL
import RecursiveDescent

// Performance benchmarks for the native parser engine. They are run by the package-benchmark plugin
// (`swift package benchmark`) and are not part of the shipped libraries. The metrics gathered are
// wall-clock time, throughput, total malloc count, and peak resident memory, so both speed and
// allocation behaviour are tracked against a saved baseline.

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

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration.metrics = [
        .wallClock,
        .throughput,
        .mallocCountTotal,
        .peakMemoryResident,
    ]

    let grammar = JSONGrammar.grammar()
    let smallSource = Source(makeJSON(objectCount: 16))
    let largeSource = Source(makeJSON(objectCount: 1024))

    Benchmark("Parse small JSON (UTF-8, 16 objects)") { benchmark in
        let engine = try UTF8Parser(grammar: grammar)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(engine.parse(smallSource))
        }
    }

    Benchmark("Parse large JSON (UTF-8, 1024 objects)") { benchmark in
        let engine = try UTF8Parser(grammar: grammar)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(engine.parse(largeSource))
        }
    }

    Benchmark("Parse large JSON (Unicode scalars, 1024 objects)") { benchmark in
        let engine = try ScalarParser(grammar: grammar)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(engine.parse(largeSource))
        }
    }

    let luaGrammar = LuaGrammar.chunk()
    let smallLuaSource = Source(makeLua(functionCount: 8))
    let largeLuaSource = Source(makeLua(functionCount: 256))

    Benchmark("Parse small Lua (UTF-8, 8 functions)") { benchmark in
        let engine = try UTF8Parser(grammar: luaGrammar)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(engine.parse(smallLuaSource))
        }
    }

    Benchmark("Parse large Lua (UTF-8, 256 functions)") { benchmark in
        let engine = try UTF8Parser(grammar: luaGrammar)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(engine.parse(largeLuaSource))
        }
    }

    let cGrammar = CGrammar.translationUnit()
    let smallCSource = Source(makeC(functionCount: 8))
    let largeCSource = Source(makeC(functionCount: 256))

    Benchmark("Parse small C (UTF-8, 8 functions)") { benchmark in
        let engine = try UTF8Parser(grammar: cGrammar)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(engine.parse(smallCSource))
        }
    }

    Benchmark("Parse large C (UTF-8, 256 functions)") { benchmark in
        let engine = try UTF8Parser(grammar: cGrammar)
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            blackHole(engine.parse(largeCSource))
        }
    }
}
