# Building Parsers

Author a grammar in the Swift DSL and run it through an engine.

## Overview

A grammar is a ``Grammar``: a set of named ``Rule``s with a start rule and a list of `extras` (trivia
such as whitespace). The `ParsingDSL` module provides a result-builder surface for writing grammars,
and `Match` constructors for building the data-only ``TokenMatcher`` of each terminal, without regular
expressions.

### Rules and references

`rule(_:_:)` defines a named rule; `ref(_:)` refers to one. Rules whose names begin with an underscore
are *hidden*: they splice their children into the parent instead of creating a node, which keeps
passthrough rules out of the tree.

```swift
rule("document") { ref("_value") }
rule("_value") { choice { ref("object"); ref("number"); ref("string") } }
```

### Token matchers

Terminals are built from primitives rather than regular expressions, so they work at any input
granularity and in embedded builds:

```swift
rule("number") {
    token(Match.seq(
        Match.optional(Match.lit("-")),
        Match.oneOrMore(Match.digit)
    ))
}
rule("string_content") { token(Match.oneOrMore(Match.not(Match.lit("\"")))) }
```

The available combinators include ``TokenMatcher/literal(_:)``, character ranges, the built-in classes
of ``BuiltinClass``, negation, sequence, alternation, and repetition.

### Fields

`field(_:_:)` labels a child so it can be referred to by role, for example a pair's `key` and `value`:

```swift
rule("pair") {
    seq {
        field("key") { ref("string") }
        ":"
        field("value") { ref("_value") }
    }
}
```

### Importing existing grammars

Grammars written for tree-sitter can be imported from their compiled `grammar.json` with the
`GrammarImport` module, which lowers regular-expression token patterns to ``TokenMatcher`` values.
