# ``ParsingCore``

The dependency-free heart of swift-parsing: the engine protocol, the grammar intermediate
representation, and the concrete syntax tree.

## Overview

`ParsingCore` defines the abstractions every parser engine shares, with no `Foundation`, regular
expression, or existential dependency, so it builds for embedded and WebAssembly targets as well as
the desktop and mobile platforms.

A grammar is described once as a ``Grammar`` of ``Rule`` values whose terminals are data-only
``TokenMatcher``s. An engine conforming to ``ParserEngine`` turns a ``Source`` into a ``ParseResult``
containing a lossless concrete syntax tree (``Syntax`` over an immutable ``GreenNode``) and any
``Diagnostic``s. Engines are generic over the input element granularity via ``ParserInput``, so the
same grammar can be parsed over UTF-8 code units, Unicode scalars, or grapheme clusters.

Engines never throw while parsing: malformed input still yields a complete tree containing `ERROR` and
`MISSING` nodes.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:BuildingParsers>

### Engines

- ``ParserEngine``
- ``ParseResult``
- ``EngineCapabilities``
- ``GrammarError``

### Grammars

- ``Grammar``
- ``Rule``
- ``TokenMatcher``
- ``BuiltinClass``
- ``Associativity``

### Input

- ``Source``
- ``ParserInput``
- ``ParserElement``
- ``SourceSpan``

### Concrete syntax tree

- ``Syntax``
- ``GreenNode``
- ``GreenChild``
- ``SyntaxKind``
- ``Diagnostic``
