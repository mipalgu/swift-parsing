# swift-parsing

A performant, cross-platform parsing framework for Swift, in the spirit of
[tree-sitter](https://tree-sitter.github.io/tree-sitter/) and
[ANTLR](https://www.antlr.org), but with a modern, protocol-oriented Swift design rather than a
heavily object-oriented runtime.

The library is built around a small, pure-Swift **protocol framework**: a single `ParserEngine`
abstraction with multiple conforming engines behind it. Native engines (a recursive-descent
interpreter today; table-driven GLR and ALL(\*) engines planned) sit alongside optional wrapper
engines for existing toolkits (tree-sitter, ANTLR), each in its own module so the core never inherits
a C runtime or the JVM. This makes the package a natural **differential-testing and benchmarking
rig**: the same grammar and input can be run through every engine and their concrete syntax trees
compared.

A canonical **grammar intermediate representation (IR)** sits at the hub. Surface grammar syntaxes,
a Swift result-builder DSL, tree-sitter `grammar.json`, and (in future) ANTLR `.g4` and EBNF, are
importers and exporters around that IR, which is what enables grammar round-tripping between formats.

## Status

This is the first milestone: a proven vertical slice for the JSON language.

| Area | State |
| --- | --- |
| `ParsingCore` | Red/green concrete syntax tree, `ParserEngine` protocol, Grammar IR, diagnostics |
| `ParsingDSL` | Result-builder grammar authoring surface; JSON grammar |
| `RecursiveDescent` | Native engine: parser-directed scanning, lossless and error-tolerant CST |
| `GrammarImport` | tree-sitter `grammar.json` import and export, with round-tripping |
| `swift-parsing` (CLI) | `parse` and `convert` subcommands (Swift Argument Parser) |

Planned next: a tree-sitter wrapper engine plus a differential harness, table-driven GLR and ALL(\*)
engines, incremental reparsing, an S-expression query language, ANTLR `.g4`/EBNF conversion, the full
cross-platform target matrix (Linux/musl, WebAssembly, iOS, Windows), and a cross-language benchmark
harness.

## Requirements

- Swift 6.2 or newer (the package builds in Swift 6 language mode with complete concurrency checking).

## Building and testing

```sh
swift build
swift test
swift test --enable-code-coverage
```

All reachable code is covered by tests; the only uncovered regions are `precondition` failure paths,
which cannot be exercised without aborting the process.

## Command-line tool

```sh
# Parse a JSON file and print its concrete syntax tree as an S-expression.
swift run swift-parsing parse example.json

# Show diagnostics (to standard error) for malformed input; a complete tree is still produced.
swift run swift-parsing parse example.json --diagnostics

# Convert a tree-sitter grammar.json document, re-emitting it in normalised form.
swift run swift-parsing convert grammar.json --start document
```

For `{ "a": 1 }`, `parse` prints:

```
(document (object (pair key: (string (string_content)) value: (number))))
```

## Authoring a grammar

Grammars are written in a Swift result-builder DSL that lowers to the Grammar IR. Rules whose names
begin with an underscore are *hidden*: they contribute their children to the parent without creating
a node of their own (mirroring tree-sitter's convention).

```swift
import ParsingCore
import ParsingDSL

let grammar = Grammar(name: "json", start: "document") {
    rule("document") { ref("_value") }
    rule("_value") {
        choice {
            ref("object"); ref("array"); ref("string"); ref("number")
            ref("true"); ref("false"); ref("null")
        }
    }
    // ... and so on
}
```

## Parsing programmatically

```swift
import ParsingCore
import ParsingDSL
import RecursiveDescent

let engine = try RecursiveDescentEngine(grammar: JSONGrammar.grammar())
let result = engine.parse(Source(#"{ "a": 1 }"#))
print(result.sExpression())          // the concrete syntax tree
print(result.hasErrors)              // false
print(result.tree.green.reconstructedText)  // round-trips exactly to the input
```

Engines never throw past their API. Malformed input still yields a complete tree containing `ERROR`
and `MISSING` nodes, alongside diagnostics describing each problem.

## Licence

MIT. See [LICENSE](LICENSE).
