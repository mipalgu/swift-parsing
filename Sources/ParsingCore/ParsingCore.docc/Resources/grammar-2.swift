import ParsingCore
import ParsingDSL

let listGrammar = Grammar(name: "list", start: "list") {
    rule("list") {
        seq {
            ref("number")
            repeat0 { seq { ","; ref("number") } }
        }
    }

    // A number is one or more ASCII digits — built from matcher primitives, no regular expression.
    rule("number") { token(Match.oneOrMore(Match.digit)) }
}
