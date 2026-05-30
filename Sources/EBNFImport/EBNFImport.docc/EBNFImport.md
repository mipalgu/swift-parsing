# ``EBNFImport``

Import and export W3C EBNF grammar text to and from the grammar IR.

## Overview

`EBNFGrammar` converts Extended Backus-Naur Form grammar text into a `ParsingCore` grammar, and back.
The dialect is the W3C EBNF used in the XML specification: productions use `::=`, concatenation is
written by juxtaposition, alternation is `|`, the postfix quantifiers `?` `*` `+` give optional,
zero-or-more and one-or-more, parentheses group, terminals are single- or double-quoted strings, and
character classes `[...]` (negated `[^...]`) hold literal members, `a-z` ranges and `#xN` hexadecimal
code points. Comments are written `/* ... */`.

Importing is strict: a structural problem throws a typed `EBNFGrammar.ImportError` rather than
producing a guessed grammar. A round-trip from the IR to EBNF and back preserves the grammar's
structure for references and literal terminals, and its parsing behaviour for every construct the
notation can express.

## Topics

### Conversion

- ``EBNFGrammar``
