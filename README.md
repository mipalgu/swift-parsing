# swift-parsing

A performant, cross-platform parsing framework for Swift, in the spirit of
[tree-sitter](https://tree-sitter.github.io/tree-sitter/) and
[ANTLR](https://www.antlr.org), but with a modern, protocol-oriented Swift design rather than a
heavily object-oriented runtime.

The library is built around a small, pure-Swift **protocol framework**: a single `ParserEngine`
abstraction with multiple conforming engines behind it. Native engines sit alongside optional wrapper
engines for existing toolkits (such as tree-sitter), each in its own module so the core never inherits
a C runtime or the JVM. The same grammar and input can be run through every engine and their concrete
syntax trees compared.

A canonical **grammar intermediate representation (IR)** sits at the hub. Surface grammar syntaxes, a
Swift result-builder DSL and tree-sitter `grammar.json`, are importers and exporters around that IR,
which is what enables grammars to round-trip between formats.

The core (`ParsingCore`) is pure Swift with no `Foundation`, regular-expression, or existential
dependency, and is generic over the input element granularity, so it suits embedded and WebAssembly
targets as well as macOS, Linux, iOS and Windows.

## Requirements

- Swift 6.2 or newer (the package builds in Swift 6 language mode with complete concurrency checking).

## Installation

Add the package to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/mipalgu/swift-parsing", from: "0.1.0"),
```

and add the products you need (`ParsingCore`, `ParsingDSL`, `RecursiveDescent`, `GrammarImport`, or
`Parsing`) to your target's dependencies. The opt-in tree-sitter backend, which wraps the C
tree-sitter runtime behind the same `ParserEngine` protocol, lives in the companion
[swift-parsing-tree-sitter](https://github.com/mipalgu/swift-parsing-tree-sitter) package so this one
stays pure Swift.

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

Grammars are written in a Swift result-builder DSL that lowers to the Grammar IR. Token patterns are
built from primitives (`Match.digit`, `Match.range`, `Match.oneOrMore`, …) rather than regular
expressions. Rules whose names begin with an underscore are *hidden*: they contribute their children
to the parent without creating a node of their own.

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
    rule("number") { token(Match.oneOrMore(Match.digit)) }
    // ... and so on
}
```

## Parsing programmatically

Choose an input granularity by selecting the engine type: `UTF8Parser` (fastest, the default),
`ScalarParser` (Unicode scalars), or `GraphemeParser` (extended grapheme clusters, the most faithful
for composite characters).

```swift
import ParsingCore
import ParsingDSL
import RecursiveDescent

let engine = try UTF8Parser(grammar: JSONGrammar.grammar())
let result = engine.parse(Source(#"{ "a": 1 }"#))
print(result.sExpression())                  // the concrete syntax tree
print(result.hasErrors)                      // false
print(result.tree.green.reconstructedText)   // round-trips exactly to the input
```

Engines never throw past their API. Malformed input still yields a complete tree containing `ERROR`
and `MISSING` nodes, alongside diagnostics describing each problem.

## Documentation

Full API documentation and tutorials are published at
<https://mipalgu.github.io/swift-parsing/>.

## Licence

MIT. See [LICENSE](LICENSE).
