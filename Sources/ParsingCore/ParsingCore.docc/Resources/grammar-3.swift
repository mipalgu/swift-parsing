import ParsingCore
import ParsingDSL
import RecursiveDescent

let listGrammar = Grammar(name: "list", start: "list") {
    rule("list") {
        seq {
            ref("number")
            repeat0 { seq { ","; ref("number") } }
        }
    }
    rule("number") { token(Match.oneOrMore(Match.digit)) }
}

// Parse with the grammar.
let result = try UTF8Parser(grammar: listGrammar).parse(Source("1, 22, 333"))
print(result.sExpression())   // (list (number) (number) (number))
