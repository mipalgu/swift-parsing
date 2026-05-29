# Getting Started

Parse your first input and read the resulting syntax tree.

## Overview

swift-parsing turns text into a *concrete syntax tree*: a lossless tree that preserves every token and
all whitespace. This article walks through parsing a small JSON document with the built-in grammar.

### Parse a document

Create an engine for a grammar and call ``ParserEngine/parse(_:)`` with a ``Source``:

```swift
import ParsingCore
import ParsingDSL
import RecursiveDescent

let engine = try UTF8Parser(grammar: JSONGrammar.grammar())
let result = engine.parse(Source(#"{ "a": 1 }"#))
```

### Read the result

A ``ParseResult`` carries the tree and any diagnostics:

```swift
print(result.sExpression())
// (document (object (pair key: (string (string_content)) value: (number))))

print(result.hasErrors)                     // false
print(result.tree.green.reconstructedText)  // {"a": 1}  — reconstructs the input exactly
```

### Handle malformed input

Engines never throw while parsing. Malformed input still produces a complete tree, with `ERROR` and
`MISSING` nodes marking the problems and matching ``Diagnostic`` values explaining them:

```swift
let broken = engine.parse(Source("true false"))
print(broken.sExpression())     // (document (true) (ERROR))
print(broken.hasErrors)         // true
print(broken.diagnostics.first?.message ?? "")
```

### Choose an input granularity

The engine type selects the input element granularity. `UTF8Parser` is the fastest and the default;
`ScalarParser` works at Unicode scalars; `GraphemeParser` works at extended grapheme clusters, the
most faithful for composite characters. All produce the same tree for the same input.
