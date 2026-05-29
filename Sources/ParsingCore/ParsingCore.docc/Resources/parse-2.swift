import ParsingCore
import ParsingDSL
import RecursiveDescent

let engine = try UTF8Parser(grammar: JSONGrammar.grammar())

// Parse a document and render its concrete syntax tree.
let result = engine.parse(Source(#"{ "a": 1 }"#))
print(result.sExpression())
// (document (object (pair key: (string (string_content)) value: (number))))
