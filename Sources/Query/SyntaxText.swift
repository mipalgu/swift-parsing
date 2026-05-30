import ParsingCore

extension Syntax {
    /// The source text this node covers, with surrounding trivia trimmed away.
    ///
    /// Predicates such as `#eq?` and `#match?` compare the *content* of a node, not its whitespace
    /// padding, so this concatenates the content text of every token in the subtree, in order,
    /// omitting each token's leading and trailing trivia. For a leaf token it is simply the token's
    /// text; for an internal node it is the joined content of its descendant tokens.
    var contentText: String {
        var out = ""
        appendContent(into: &out)
        return out
    }

    /// Appends this subtree's token content (without trivia) to `out`.
    private func appendContent(into out: inout String) {
        switch green.payload {
        case .token(let text, _, _):
            out += text
        case .node(let children):
            for child in children {
                Syntax(child.node).appendContent(into: &out)
            }
        }
    }
}
