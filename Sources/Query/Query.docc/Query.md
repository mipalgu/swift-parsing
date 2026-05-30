# ``Query``

Run tree-sitter-style S-expression queries over a `ParsingCore` concrete syntax tree.

## Overview

`Query` compiles a pattern written in tree-sitter's query language and runs it against any tree built
by an engine in this framework. A pattern describes the shape a subtree must have and binds matched
nodes to capture names; optional predicates constrain matches by the captured nodes' source text.

The supported syntax mirrors tree-sitter:

- **Named nodes** `(object ...)` match a `SyntaxKind` by name and their children in order.
- **Anonymous nodes** `","` match a literal punctuation token.
- **Wildcards** `_` matches any node and `(_)` matches any named node.
- **Field labels** `key: (string)` constrain a child to a `GreenChild` field slot.
- **Negated fields** `!value` assert a node has no child in that field.
- **Quantifiers** `?`, `*` and `+` repeat a pattern, and may apply to a parenthesised group.
- **Alternations** `[(string) (number)]` match any one of several patterns.
- **Anchors** `.` constrain named siblings to be adjacent (at the start, between, or at the end).
- **Captures** `@name` bind a matched node so it is reported in a ``QueryMatch``.
- **Predicates** `(#eq? @a "x")`, `#not-eq?`, `#match?`, `#not-match?`, `#any-of?` and `#not-any-of?`
  filter matches by the captured text.

Compilation is the only fallible step; running a compiled query never throws.

## Topics

### Compiling and running queries

- ``Query/init(_:)``
- ``Query/matches(in:)``
- ``Query/captures(in:)``

### Match results

- ``QueryMatch``
- ``QueryCapture``

### The pattern intermediate representation

- ``QueryPattern``
- ``Quantifier``
- ``Predicate``
- ``PredicateKind``
- ``PredicateArgument``

### Errors

- ``QueryError``
