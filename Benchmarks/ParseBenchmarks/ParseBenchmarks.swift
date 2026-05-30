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
}
