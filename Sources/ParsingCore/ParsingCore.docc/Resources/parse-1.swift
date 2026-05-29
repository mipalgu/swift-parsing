import ParsingCore
import ParsingDSL
import RecursiveDescent

// Create an engine for the built-in JSON grammar.
let engine = try UTF8Parser(grammar: JSONGrammar.grammar())
