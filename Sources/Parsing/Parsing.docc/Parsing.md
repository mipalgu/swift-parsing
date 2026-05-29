# ``Parsing``

The full-featured overlay over `ParsingCore` for non-embedded targets.

## Overview

`Parsing` adds conveniences that depend on facilities unavailable in Embedded Swift, keeping the core
itself dependency-free. It provides ``RegexLowering``, which converts between regular-expression
strings and the data-only token matcher used by the core, so regular-expression grammars can be lowered
to the Embedded-safe representation.

## Topics

### Regular expressions

- ``RegexLowering``
