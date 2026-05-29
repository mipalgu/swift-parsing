import ParsingCore
import ParsingDSL

// A grammar for a comma-separated list of integers, e.g. "1, 2, 3".
let listGrammar = Grammar(name: "list", start: "list") {
    rule("list") {
        seq {
            ref("number")
            repeat0 { seq { ","; ref("number") } }
        }
    }
}
