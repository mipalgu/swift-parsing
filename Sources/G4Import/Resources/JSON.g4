// An ANTLR4 grammar for JSON, with rule and node names deliberately aligned to the tree-sitter
// `tree-sitter-json` grammar (and the `ParsingDSL.JSONGrammar`) so that the native engine produces an
// identical canonical S-expression for either grammar. This is the acceptance fixture for the
// `G4Import` importer.
//
// Naming alignment with tree-sitter (rather than ANTLR's own `JSON.g4`, which uses `json`, `obj`,
// `arr`, `value`): the start rule is `document`; the value rule is hidden as `_value`; structural rules
// are `object`, `pair`, `array`, `string`, `string_content`, `number`, `true`, `false`, `null`.
//
// Strings are modelled without escape sequences, matching the documented first-milestone simplification
// of `ParsingDSL.JSONGrammar`: `string_content` is any run of non-quote elements.

grammar JSON;

document
    : _value EOF
    ;

_value
    : object
    | array
    | string
    | number
    | true
    | false
    | null
    ;

object
    : '{' ( pair ( ',' pair )* )? '}'
    ;

pair
    : key=( string | number ) ':' value=_value
    ;

array
    : '[' ( _value ( ',' _value )* )? ']'
    ;

string
    : '"' string_content? '"'
    ;

string_content
    : STRING_CONTENT
    ;

number
    : NUMBER
    ;

true
    : 'true'
    ;

false
    : 'false'
    ;

null
    : 'null'
    ;

STRING_CONTENT
    : ~'"'+
    ;

NUMBER
    : '-'? ( '0' | [1-9] [0-9]* ) ( '.' [0-9]+ )? ( [eE] [+-]? [0-9]+ )?
    ;

WS
    : [ \t\n\r]+ -> skip
    ;
