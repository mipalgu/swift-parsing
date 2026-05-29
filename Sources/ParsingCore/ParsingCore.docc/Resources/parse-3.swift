import ParsingCore
import ParsingDSL
import RecursiveDescent

let engine = try UTF8Parser(grammar: JSONGrammar.grammar())

// Parsing never throws: malformed input yields a complete tree plus diagnostics.
let broken = engine.parse(Source("true false"))
print(broken.sExpression())   // (document (true) (ERROR))
print(broken.hasErrors)       // true

for diagnostic in broken.diagnostics {
    print(diagnostic.message)
}
