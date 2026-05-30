# ``G4Import``

Import ANTLR `.g4` grammars into the grammar IR.

## Overview

`G4Grammar` lowers a documented subset of the ANTLR `.g4` grammar format directly into a `ParsingCore`
grammar, so a language defined for ANTLR can be parsed by the native engine without ANTLR or the JVM. It
mirrors the role `GrammarImport` plays for tree-sitter `grammar.json`, sharing the same target
intermediate representation.

`.g4` is a *combined* grammar: a single file holds both parser rules (lowercase initial) and lexer rules
(uppercase initial). The framework's representation is scannerless, with terminals expressed as
`TokenMatcher` matches inlined into the rules that use them. The importer bridges that gap: lexer rules
and `fragment` rules are resolved into token matchers (fragments inlined into their callers), parser
rules become structural rules, and a `-> skip` or `-> channel(...)` lexer rule becomes a trivia
`extra`. A parser rule whose body is a single token reference (for example `number : NUMBER ;`) yields a
named leaf node, matching tree-sitter's tree shape.

### Supported subset

- The combined header `grammar Name;`.
- Parser rules, lexer rules, and `fragment` lexer rules, each a `|`-separated list of alternatives.
- A leading-underscore parser-rule name is hidden, splicing its children into the parent.
- Elements: rule references, single-quoted string literals (with C-style escapes), character sets
  `[a-z]`, negated sets `~[...]`/`~'x'`, the dot wildcard `.`, and parenthesised groups.
- EBNF suffixes `?`, `*`, `+`; the non-greedy markers `??`, `*?`, `+?` are accepted and treated as
  their greedy equivalents (the native engine resolves alternatives by ordered choice).
- Element labels `name=element` and `name+=element`, lowered to grammar fields.
- The lexer commands `-> skip` and `-> channel(...)`, and the built-in `EOF` reference.
- `//` line comments and `/* */` block comments.

### Not supported

Labelled alternatives (`# Label`), lexical modes, embedded actions, semantic predicates,
`options`/`tokens`/`channels` blocks, grammar imports, separate `parser grammar`/`lexer grammar` files,
and rule arguments or return values. Any of these raises `G4ImportError`.

## Topics

### Importing

- ``G4Grammar``
- ``G4ImportError``
