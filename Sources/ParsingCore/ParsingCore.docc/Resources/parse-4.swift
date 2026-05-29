import ParsingCore
import ParsingDSL
import RecursiveDescent

let grammar = JSONGrammar.grammar()
let input = Source(#"{ "city": "café" }"#)

// The same grammar parses at any granularity, with the same tree.
let utf8 = try UTF8Parser(grammar: grammar).parse(input)
let scalar = try ScalarParser(grammar: grammar).parse(input)
let grapheme = try GraphemeParser(grammar: grammar).parse(input)

assert(utf8.sExpression() == scalar.sExpression())
assert(scalar.sExpression() == grapheme.sExpression())
