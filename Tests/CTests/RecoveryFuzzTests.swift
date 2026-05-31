// The recovery fuzzers drive the reference engine over thousands of mutated inputs; some nest deeply
// enough that its recursion exceeds the WasmKit interpreter's call-frame budget (the same runtime limit
// that excludes the C suite from WebAssembly). They are exhaustive native verification, run in full on the
// macOS, Linux and Windows jobs, so they are compiled out of the WebAssembly build.
#if !os(WASI)

    import ParsingCore
    import ParsingDSL
    import RecursiveDescent
    import SwiftALLStar
    import Testing

    /// Property-based recovery differential for the structural C grammar.
    ///
    /// Every valid corpus input is mutated into malformed variants by exhaustive truncation (each prefix),
    /// single-character deletion, and prefix-plus-junk concatenation. For each variant the ALL(*) engine must
    /// agree with the recursive-descent reference engine on the byte-identical S-expression, round-trip
    /// losslessly, and agree on the error flag. This pins ALL(*) recovery to the reference contract across
    /// thousands of malformed inputs, not just a hand-picked few.
    @Suite("C recovery fuzz differential")
    struct CRecoveryFuzzTests {
        @Test("ALL(*) recovery matches the reference engine on a fuzzed malformed corpus")
        func recoveryMatchesReference() throws {
            let grammar = CGrammar.translationUnit()
            let reference = try UTF8Parser(grammar: grammar)
            let allStar = try ALLStarUTF8Parser(grammar: grammar)
            let report = RecoveryFuzz.compare(seeds: Corpus.structural, reference: reference, allStar: allStar)
            #expect(report.divergences.isEmpty, "\(report.checked) inputs checked; \(report.summary)")
        }
    }

    /// Deterministic recovery-differential fuzzing, shared in spirit with the Lua and JSON structural suites.
    ///
    /// The fuzzer needs no random source: it derives malformed inputs structurally from the valid corpus, so
    /// every run checks the same set and a failure is exactly reproducible. The engines are built once by the
    /// caller and reused across every mutation.
    enum RecoveryFuzz {
        /// The outcome of comparing ALL(*) recovery against the reference engine over a fuzzed corpus.
        struct Report {
            /// The number of distinct malformed inputs checked.
            let checked: Int
            /// A human-readable line per diverging input (capped), empty when every input matched.
            let divergences: [String]
            /// A one-line summary, listing the first few divergences when present.
            var summary: String {
                divergences.isEmpty
                    ? "all matched" : "\(divergences.count) diverged:\n\(divergences.joined(separator: "\n"))"
            }
        }

        /// Generates malformed variants of each seed: every prefix, every single-character deletion, and the
        /// midpoint prefix followed by a few junk fragments. The result is de-duplicated and order-stable.
        static func mutations(of seeds: [String]) -> [String] {
            let junk = ["@@@", "}", ")", "end", " = ", "(("]
            var seen = Set<String>()
            var out: [String] = []
            func add(_ candidate: String) { if seen.insert(candidate).inserted { out.append(candidate) } }
            for seed in seeds {
                let characters = Array(seed)
                for prefixLength in 0...characters.count { add(String(characters[0..<prefixLength])) }
                if characters.count > 1 {
                    for dropped in characters.indices {
                        var trimmed = characters
                        trimmed.remove(at: dropped)
                        add(String(trimmed))
                    }
                }
                let midpoint = characters.count / 2
                for fragment in junk { add(String(characters[0..<midpoint]) + fragment) }
            }
            return out
        }

        /// Parses every mutation with both engines and records each input where ALL(*) diverges from the
        /// reference on S-expression, round-trip text, or error flag.
        static func compare(seeds: [String], reference: UTF8Parser, allStar: ALLStarUTF8Parser) -> Report {
            let inputs = mutations(of: seeds)
            var divergences: [String] = []
            for input in inputs {
                let referenceResult = reference.parse(Source(input))
                let allStarResult = allStar.parse(Source(input))
                let sExpressionMatches = allStarResult.sExpression() == referenceResult.sExpression()
                let roundTrips = allStarResult.tree.green.reconstructedText == input
                let errorFlagMatches = allStarResult.hasErrors == referenceResult.hasErrors
                guard !(sExpressionMatches && roundTrips && errorFlagMatches) else { continue }
                guard divergences.count < 12 else { continue }
                var line = "  input=\(input.debugDescription) sexp=\(sExpressionMatches)"
                line += " roundtrip=\(roundTrips) flag=\(errorFlagMatches)"
                if !sExpressionMatches {
                    line += "\n     rd=\(referenceResult.sExpression())\n     as=\(allStarResult.sExpression())"
                }
                divergences.append(line)
            }
            return Report(checked: inputs.count, divergences: divergences)
        }
    }

#endif
