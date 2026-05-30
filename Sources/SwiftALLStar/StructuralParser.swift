import ParsingCore

/// Drives a single parse: walks the ATN, consults the predictor at decisions, and builds the tree.
///
/// This is the structural counterpart to adaptive prediction. It maintains the live cursor and call
/// stack, calls the predictor to choose alternatives, consumes tokens with their leading trivia for
/// losslessness, splices hidden rules into their parents, and recovers unparseable input into
/// `ERROR`/`MISSING` nodes so it never throws past the engine. Its tree shape mirrors the
/// recursive-descent reference engine, which is what makes the differential S-expression contract hold.
final class StructuralParser<Input: ParserInput> {
    let grammar: Grammar
    let atn: ATN
    let input: Input
    var index: Input.Index
    var byteOffset: Int = 0
    var diagnostics: [Diagnostic] = []
    let predictor: Predictor<Input>
    /// The live parser call stack of return states (innermost last), passed to full-LL prediction.
    private var callStack: [ATNStateID] = []
    /// The minimum operator precedence per rule currently on the stack (for left-recursion guards).
    private var precedenceStack: [Int] = []

    /// Creates a structural parser.
    /// - Parameters:
    ///   - grammar: The grammar being parsed.
    ///   - atn: The compiled ATN.
    ///   - input: The input view.
    init(grammar: Grammar, atn: ATN, input: Input) {
        self.grammar = grammar
        self.atn = atn
        self.input = input
        self.index = input.startIndex
        self.predictor = Predictor(atn: atn, input: input, extras: grammar.extras)
    }

    /// Advances the cursor to `end`, accumulating consumed bytes for diagnostics and offsets.
    private func advance(to end: Input.Index) {
        if end != index {
            byteOffset += Input.text(of: input[index..<end]).utf8.count
            index = end
        }
    }

    // MARK: - Document / recovery (Function 1 entry, §6.5)

    /// Parses the start rule, recovering into `ERROR`/`MISSING` nodes and a complete document tree.
    func parseDocument() -> GreenNode {
        let startKind = SyntaxKind(grammar.startRule, isNamed: true)
        var documentNode: GreenNode
        if grammar.rules[grammar.startRule] != nil, let node = parseReference(grammar.startRule) {
            documentNode = node
        } else {
            diagnostics.append(.error("expected \(grammar.startRule)", at: .empty(at: byteOffset)))
            documentNode = GreenNode.node(startKind, children: [.init(node: .missingToken(SyntaxKind("value")))])
        }

        let trailingTrivia = consumeTriviaText()
        if index != input.endIndex {
            diagnostics.append(.error("unexpected trailing input", at: .empty(at: byteOffset)))
            let junk = Input.text(of: input[index..<input.endIndex])
            let errorToken = GreenNode.token(
                SyntaxKind("<error>", isNamed: false), text: junk, leadingTrivia: trailingTrivia)
            let errorNode = GreenNode.errorNode(children: [.init(node: errorToken)])
            documentNode = GreenNode.node(documentNode.kind, children: documentNode.children + [.init(node: errorNode)])
        } else if !trailingTrivia.isEmpty {
            let carrier = GreenNode.token(SyntaxKind("", isNamed: false), text: "", leadingTrivia: trailingTrivia)
            documentNode = GreenNode.node(documentNode.kind, children: documentNode.children + [.init(node: carrier)])
        }
        return documentNode
    }

    // MARK: - Rule walking (§6.2)

    /// Parses a rule reference into its node, splicing hidden rules and returning `nil` on failure.
    private func parseReference(_ name: String) -> GreenNode? {
        guard let children = parseRuleBody(name) else { return nil }
        if name.hasPrefix("_") {
            // A hidden rule with a single child surfaces that child; otherwise it groups them invisibly.
            if children.count == 1 { return children[0].node }
            return GreenNode.node(SyntaxKind("_group", isNamed: false), children: children)
        }
        return GreenNode.node(SyntaxKind(name, isNamed: true), children: children)
    }

    /// Walks a rule's submachine, accumulating its children, or returns `nil` if it cannot be parsed.
    private func parseRuleBody(_ name: String) -> [GreenChild]? {
        guard let entry = atn.ruleEntry[name], let stop = atn.ruleStop[name] else { return nil }
        precedenceStack.append(0)
        defer { precedenceStack.removeLast() }
        var kids: [GreenChild] = []
        var p = entry
        while p != stop {
            let state = atn[p]
            if state.isStop { break }
            if let decision = state.decision {
                let start = skipTriviaIndex()
                let alt = predictor.adaptivePredict(
                    decision: decision, callStack: callStack, start: start,
                    minPrecedence: precedenceStack.last ?? 0)
                if alt == Predictor<Input>.noViableAlternative { return nil }
                p = state.transitions[alt - 1].target
                continue
            }
            switch state.transitions[0] {
            case .epsilon(let t), .action(let t):
                p = t
            case .predicate(_, let t):
                p = t
            case .atom(let matcher, let isNamed, let tokenName, let field, let t):
                guard let child = consumeToken(matcher, isNamed: isNamed, name: tokenName, field: field) else {
                    return nil
                }
                kids.append(child)
                p = t
            case .rule(_, let follow, let ruleName, let isHidden, let isDefined, let field, let t):
                guard isDefined else {
                    // A reference to an undefined rule fails the whole rule, surfacing a MISSING at the top.
                    return nil
                }
                callStack.append(follow)
                let sub = parseSubrule(ruleName, field: field, isHidden: isHidden)
                callStack.removeLast()
                guard let sub else { return nil }
                kids.append(contentsOf: sub)
                p = t
            }
        }
        return kids
    }

    /// Parses a called rule, splicing its children if hidden or wrapping them otherwise.
    private func parseSubrule(_ name: String, field: String?, isHidden: Bool) -> [GreenChild]? {
        guard let children = parseRuleBody(name) else { return nil }
        if isHidden {
            if let field, children.count == 1 {
                return [GreenChild(field: field, node: children[0].node)]
            }
            if let field {
                let group = GreenNode.node(SyntaxKind("group", isNamed: false), children: children)
                return [GreenChild(field: field, node: group)]
            }
            return children  // splice directly into parent
        }
        let node = GreenNode.node(SyntaxKind(name, isNamed: true), children: children)
        return [GreenChild(field: field, node: node)]
    }

    // MARK: - Token consumption (§6.3)

    /// Consumes a token with its leading trivia, or returns `nil` if it does not match.
    ///
    /// On a mismatch the cursor is restored and `nil` is returned so the failure bubbles up to the rule
    /// and then to document-level recovery, mirroring the reference engine's ordered-choice backtracking.
    private func consumeToken(_ matcher: TokenMatcher, isNamed: Bool, name: String, field: String?) -> GreenChild? {
        let savedIndex = index
        let savedOffset = byteOffset
        let triviaStart = index
        let afterTrivia = skipTrivia(grammar.extras, in: input, at: index)
        advance(to: afterTrivia)
        let leading = Input.text(of: input[triviaStart..<index])
        guard let end = matchToken(matcher, in: input, at: index) else {
            index = savedIndex
            byteOffset = savedOffset
            return nil
        }
        let text = Input.text(of: input[index..<end])
        advance(to: end)
        let token = GreenNode.token(SyntaxKind(name, isNamed: isNamed), text: text, leadingTrivia: leading)
        return GreenChild(field: field, node: token)
    }

    // MARK: - Trivia helpers

    /// The index after the trivia run at the cursor, without advancing the cursor.
    private func skipTriviaIndex() -> Input.Index {
        skipTrivia(grammar.extras, in: input, at: index)
    }

    /// Consumes the trivia run at the cursor and returns its text.
    private func consumeTriviaText() -> String {
        let start = index
        let end = skipTrivia(grammar.extras, in: input, at: index)
        advance(to: end)
        return Input.text(of: input[start..<end])
    }
}
