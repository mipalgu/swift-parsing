# ``TreeSitterBackend``

An opt-in parser engine that wraps the C tree-sitter runtime.

## Overview

`TreeSitterEngine` conforms a bundled tree-sitter language to the same `ParserEngine` protocol as the
native engines, converting the tree-sitter parse tree into the framework's concrete syntax tree. It
lives in its own module so the pure-Swift core never links the C runtime, and is used chiefly to check
native engines against a reference implementation by comparing their trees.

## Topics

### Engine

- ``TreeSitterEngine``
