# ``ParsingDSL``

A Swift result-builder surface for authoring grammars, and the built-in JSON grammar.

## Overview

`ParsingDSL` lowers a declarative description to a `ParsingCore` grammar. Define rules with
``rule(_:_:)``, refer to them with ``ref(_:)``, and compose them with `seq`, `choice`, `optional`,
`repeat0`, `repeat1`, and `field`. Build the token of a terminal from the ``Match`` primitives, which
produce a data-only matcher rather than a regular expression.

## Topics

### Grammar building

- ``rule(_:_:)``
- ``ref(_:)``
- ``token(_:)``
- ``RuleExpr``
- ``Match``

### Built-in grammars

- ``JSONGrammar``
