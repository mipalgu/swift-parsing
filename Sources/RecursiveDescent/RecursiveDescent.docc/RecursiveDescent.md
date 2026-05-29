# ``RecursiveDescent``

The native parser engine, generic over input granularity.

## Overview

`RecursiveDescentEngine` interprets a grammar by recursive descent with ordered-choice backtracking,
scanning terminals on demand so lexing is context-sensitive. It produces a lossless, error-tolerant
concrete syntax tree and never throws while parsing.

Choose the input element granularity by selecting the engine type: ``UTF8Parser`` is the fastest and
the default, ``ScalarParser`` works at Unicode scalars, and ``GraphemeParser`` works at extended
grapheme clusters. All three produce the same tree for the same input.

## Topics

### Engine

- ``RecursiveDescentEngine``

### Granularities

- ``UTF8Parser``
- ``ScalarParser``
- ``GraphemeParser``
