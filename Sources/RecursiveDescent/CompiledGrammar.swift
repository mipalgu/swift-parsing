import ParsingCore

// A one-time lowering of a `Grammar` into an engine-internal form that pre-computes everything the hot
// parse loop would otherwise recompute on every call: literals are decomposed into element arrays once
// (instead of allocating a fresh `[Element]` per match), rule references are resolved to direct node
// pointers (instead of a dictionary lookup per reference), and every `SyntaxKind` is built once. The
// lowering is performed a single time per engine instance and shared, immutably, across all parses.

/// A compiled token matcher whose literals are pre-decomposed at the input granularity.
///
/// Mirrors ``TokenMatcher`` but stores literals as `[Element]` so matching never re-decomposes a
/// `String`. Reference semantics keep the recursive `indirect`-equivalent cases cheap to share.
final class CompiledMatcher<Element: ParserElement>: @unchecked Sendable {
    enum Kind {
        case literal([Element])
        case anyElement
        case scalarRange(ClosedRange<UInt32>)
        case builtin(BuiltinClass)
        case negated(CompiledMatcher)
        case sequence([CompiledMatcher])
        case alternation([CompiledMatcher])
        case repeated(min: Int, max: Int?, CompiledMatcher)
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

/// A compiled grammar rule, lowered from ``Rule`` with references resolved to direct node pointers.
///
/// Each case carries pre-built ``SyntaxKind`` values and, for references, a direct pointer to the
/// referenced rule's compiled body plus its hidden-rule flag, so the parse loop performs no dictionary
/// lookups or `SyntaxKind` construction on the hot path.
/// The `kind` is written once during the one-time lowering (to tie recursive reference knots) and is
/// only ever read afterwards, so sharing compiled rules across concurrent parses is safe.
final class CompiledRule<Input: ParserInput>: @unchecked Sendable {
    typealias Element = Input.Element
    enum Kind {
        case token(SyntaxKind, CompiledMatcher<Element>)
        /// A reference resolved to the referenced rule's body, its wrapping kind, and whether it is hidden.
        case reference(body: CompiledRule, kind: SyntaxKind, isHidden: Bool)
        /// A reference whose target rule is undefined; always a mismatch (matches the interpreter).
        case unresolvedReference
        case sequence([CompiledRule])
        case choice([CompiledRule])
        case repeatZeroOrMore(CompiledRule)
        case repeatOneOrMore(CompiledRule)
        case optional(CompiledRule)
        case field(String, CompiledRule)
    }
    var kind: Kind!
    init() { self.kind = nil }
    init(_ kind: Kind) { self.kind = kind }
}

/// A grammar lowered once into the engine-internal compiled form for a given input granularity.
final class CompiledGrammar<Input: ParserInput>: @unchecked Sendable {
    typealias Element = Input.Element
    /// The start rule expressed as a reference, so parsing it produces the same wrapping node the
    /// interpreter produced for `.reference(startRule)`.
    let startReference: CompiledRule<Input>
    let startKind: SyntaxKind
    /// The compiled extra (trivia) matchers, pre-decomposed.
    let extras: [CompiledMatcher<Element>]
    /// Whether the only extra is the ASCII-whitespace builtin, enabling a branch-free trivia fast path.
    let extrasAreWhitespaceOnly: Bool

    init(_ grammar: Grammar) {
        let startKind = SyntaxKind(grammar.startRule, isNamed: true)
        self.startKind = startKind
        self.extras = grammar.extras.map { CompiledGrammar.lower(matcher: $0) }
        self.extrasAreWhitespaceOnly =
            grammar.extras.count == 1 && grammar.extras[0] == .builtin(.whitespace)

        // Compile rules with a memo so mutually recursive references share one node and cycles terminate.
        var memo: [String: CompiledRule<Input>] = [:]
        func ruleNode(named name: String) -> CompiledRule<Input> {
            if let existing = memo[name] { return existing }
            let placeholder = CompiledRule<Input>()
            memo[name] = placeholder
            guard let body = grammar.rules[name] else {
                placeholder.kind = .unresolvedReference
                return placeholder
            }
            placeholder.kind = CompiledGrammar.lower(rule: body, ruleNode: ruleNode).kind
            return placeholder
        }
        self.startReference = CompiledGrammar.lower(
            rule: .reference(grammar.startRule), ruleNode: ruleNode)
    }

    /// Lowers a grammar rule, resolving references through `ruleNode`.
    private static func lower(
        rule: Rule, ruleNode: (String) -> CompiledRule<Input>
    ) -> CompiledRule<Input> {
        switch rule {
        case .token(let name, let matcher, let isNamed):
            return CompiledRule(.token(SyntaxKind(name, isNamed: isNamed), lower(matcher: matcher)))
        case .reference(let name):
            let body = ruleNode(name)
            if case .unresolvedReference = body.kind {
                return CompiledRule(.unresolvedReference)
            }
            return CompiledRule(
                .reference(
                    body: body, kind: SyntaxKind(name, isNamed: true), isHidden: name.hasPrefix("_")))
        case .sequence(let rules):
            return CompiledRule(.sequence(rules.map { lower(rule: $0, ruleNode: ruleNode) }))
        case .choice(let alternatives):
            return CompiledRule(.choice(alternatives.map { lower(rule: $0, ruleNode: ruleNode) }))
        case .repeatZeroOrMore(let sub):
            return CompiledRule(.repeatZeroOrMore(lower(rule: sub, ruleNode: ruleNode)))
        case .repeatOneOrMore(let sub):
            return CompiledRule(.repeatOneOrMore(lower(rule: sub, ruleNode: ruleNode)))
        case .optional(let sub):
            return CompiledRule(.optional(lower(rule: sub, ruleNode: ruleNode)))
        case .field(let name, let sub):
            return CompiledRule(.field(name, lower(rule: sub, ruleNode: ruleNode)))
        case .precedence(_, _, let sub):
            // Precedence carries no parse-time behaviour in this engine; splice through transparently.
            return lower(rule: sub, ruleNode: ruleNode)
        }
    }

    /// Lowers a token matcher, pre-decomposing literals into elements at the input granularity.
    private static func lower(matcher: TokenMatcher) -> CompiledMatcher<Element> {
        switch matcher {
        case .literal(let text):
            return CompiledMatcher(.literal(Input.elements(of: text)))
        case .anyElement:
            return CompiledMatcher(.anyElement)
        case .scalarRange(let range):
            return CompiledMatcher(.scalarRange(range))
        case .builtin(let builtinClass):
            return CompiledMatcher(.builtin(builtinClass))
        case .negated(let inner):
            return CompiledMatcher(.negated(lower(matcher: inner)))
        case .sequence(let matchers):
            return CompiledMatcher(.sequence(matchers.map { lower(matcher: $0) }))
        case .alternation(let matchers):
            return CompiledMatcher(.alternation(matchers.map { lower(matcher: $0) }))
        case .repeated(let min, let max, let inner):
            return CompiledMatcher(.repeated(min: min, max: max, lower(matcher: inner)))
        }
    }
}
