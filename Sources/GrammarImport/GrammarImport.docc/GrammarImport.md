# ``GrammarImport``

Import and export tree-sitter `grammar.json` documents to and from the grammar IR.

## Overview

`TreeSitterGrammarJSON` converts the normalised `grammar.json` that `tree-sitter generate` produces
into a `ParsingCore` grammar, and back. Regular-expression token patterns are lowered to data-only
token matchers on import and rendered back to regular expressions on export, so grammars can move
between the two ecosystems.

## Topics

### Conversion

- ``TreeSitterGrammarJSON``
