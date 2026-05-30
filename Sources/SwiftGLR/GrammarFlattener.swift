import ParsingCore

/// A grammar symbol in the flattened, context-free production set.
///
/// The flattener lowers the recursive `Rule` intermediate representation into flat productions over a
/// small symbol alphabet. A symbol is either a nonterminal (an index into the flattener's nonterminal
/// table), a terminal (an index into the deduplicated token table), or the augmented end-of-input
/// marker introduced for the start production.
enum Symbol: Hashable, Sendable {
    /// A nonterminal, identified by its index in the nonterminal table.
    case nonterminal(Int)
    /// A terminal, identified by its index in the terminal table.
    case terminal(Int)
    /// The augmented end-of-input marker `$`.
    case endOfInput
}

/// A recognisable terminal: everything needed to match a token at the cursor and emit its leaf.
///
/// Each distinct `(matcher, kindName, isNamed)` triple in the grammar becomes one terminal. The matcher
/// is applied scannerlessly at the cursor; the kind name and named flag reproduce the leaf the
/// recursive-descent engine would emit for the same token.
struct Terminal: Hashable, Sendable {
    /// The matcher recognised at the cursor.
    let matcher: TokenMatcher
    /// The syntax-kind name emitted for a matched token.
    let kindName: String
    /// Whether the emitted token is a named grammar symbol.
    let isNamed: Bool
}

/// How a completed reduction of a production is rendered into the concrete syntax tree.
///
/// This mirrors the recursive-descent engine's tree-shape decisions exactly: a named, non-underscore
/// reference wraps its children in a node; synthetic and underscore-prefixed symbols splice their
/// children into the parent; a field-labelled production attaches a field name.
enum Emit: Hashable, Sendable {
    /// Wrap the reduction's children in `(kind …)`.
    case opaque(SyntaxKind)
    /// Splice the reduction's children into the parent (hidden / synthetic).
    case transparent
    /// Attach the given field label to the reduction's children.
    case field(String)
}

/// A flattened context-free production `lhs → rhs`.
///
/// Productions are the unit the LR(0) automaton and the parser operate over. Each carries the metadata
/// the tree builder needs to reproduce the reference engine's tree shape, plus the right-nullable
/// boundary the RNGLR algorithm needs for right-nulled reductions.
struct Production: Sendable {
    /// The left-hand-side nonterminal index.
    let lhs: Int
    /// The right-hand-side symbols, in order.
    let rhs: [Symbol]
    /// How a completed reduction of this production is rendered.
    let emit: Emit
    /// The optional precedence level and associativity inherited from a `precedence` rule.
    let precedence: (level: Int, assoc: Associativity)?
    /// The ordinal of this production among the alternatives of the same `choice`, or `nil`.
    let choiceOrdinal: Int?
}

/// Lowers a `Grammar` into flat productions plus the symbol tables the automaton and parser consume.
///
/// `GrammarFlattener` desugars the EBNF operators (`choice`, `optional`, `repeat`, `field`,
/// `precedence`) into synthetic nonterminals and per-alternative productions, deduplicates terminals,
/// and records the emit metadata that lets the tree builder reproduce the recursive-descent engine's
/// concrete syntax tree byte-for-byte. The augmented start production `S' → start $` is added last.
struct GrammarFlattener {
    /// The flattened productions, indexed by production id.
    private(set) var productions: [Production] = []
    /// The deduplicated terminal table, indexed by terminal id.
    private(set) var terminals: [Terminal] = []
    /// The nonterminal names, indexed by nonterminal id. Synthetic names contain a `#` marker.
    private(set) var nonterminalNames: [String] = []
    /// The nonterminal id of the augmented start symbol.
    private(set) var augmentedStart: Int = 0
    /// The nonterminal id of the user start rule.
    private(set) var userStart: Int = 0
    /// The production id of the augmented accept production `S' → start $`.
    private(set) var acceptProduction: Int = 0
    /// The grammar's trivia matchers, carried through for the lexer.
    let extras: [TokenMatcher]

    private var nonterminalIDs: [String: Int] = [:]
    private var terminalIDs: [Terminal: Int] = [:]
    private var syntheticCounter = 0
    private let grammar: Grammar

    /// Flattens a grammar.
    ///
    /// - Parameter grammar: The grammar to lower. Its start rule must be defined; the caller validates
    ///   this before constructing the flattener.
    init(grammar: Grammar) {
        self.grammar = grammar
        self.extras = grammar.extras

        // Reserve a nonterminal for every named rule first, so references resolve regardless of order.
        for name in grammar.rules.keys.sorted() {
            _ = intern(nonterminal: name)
        }
        userStart = intern(nonterminal: grammar.startRule)

        // Lower each named rule into productions for its nonterminal.
        for name in grammar.rules.keys.sorted() {
            let body = grammar.rules[name]!
            let emit: Emit = name.hasPrefix("_")
                ? .transparent
                : .opaque(SyntaxKind(name, isNamed: true))
            lower(body, into: intern(nonterminal: name), emit: emit, precedence: nil, choiceOrdinal: nil)
        }

        // Augment: S' → start $.
        augmentedStart = intern(nonterminal: "#start")
        acceptProduction = productions.count
        productions.append(
            Production(
                lhs: augmentedStart,
                rhs: [.nonterminal(userStart), .endOfInput],
                emit: .transparent,
                precedence: nil,
                choiceOrdinal: nil))
    }

    // MARK: - Interning

    private mutating func intern(nonterminal name: String) -> Int {
        if let id = nonterminalIDs[name] { return id }
        let id = nonterminalNames.count
        nonterminalIDs[name] = id
        nonterminalNames.append(name)
        return id
    }

    private mutating func intern(terminal: Terminal) -> Int {
        if let id = terminalIDs[terminal] { return id }
        let id = terminals.count
        terminalIDs[terminal] = id
        terminals.append(terminal)
        return id
    }

    private mutating func freshSynthetic(_ hint: String) -> Int {
        syntheticCounter += 1
        return intern(nonterminal: "#\(hint)\(syntheticCounter)")
    }

    // MARK: - Lowering

    /// Lowers a rule body into one or more productions whose left-hand side is `lhs`.
    ///
    /// The body is reduced to a single right-hand-side sequence of symbols; alternatives within a
    /// `choice` produce one production each. The `emit`, `precedence` and `choiceOrdinal` metadata are
    /// attached to every production directly produced here.
    private mutating func lower(
        _ rule: Rule,
        into lhs: Int,
        emit: Emit,
        precedence: (level: Int, assoc: Associativity)?,
        choiceOrdinal: Int?
    ) {
        switch rule {
        case .choice(let alternatives):
            for (ordinal, alternative) in alternatives.enumerated() {
                let effective = effectivePrecedence(of: alternative, inherited: precedence)
                let rhs = symbols(of: alternative, precedence: effective)
                productions.append(
                    Production(
                        lhs: lhs, rhs: rhs, emit: emit, precedence: effective, choiceOrdinal: ordinal))
            }
        default:
            let effective = effectivePrecedence(of: rule, inherited: precedence)
            let rhs = symbols(of: rule, precedence: effective)
            productions.append(
                Production(
                    lhs: lhs, rhs: rhs, emit: emit, precedence: effective, choiceOrdinal: choiceOrdinal))
        }
    }

    /// The precedence governing a rule: the rule's own outer `precedence` wrapper, else the inherited one.
    ///
    /// A `precedence` rule placed directly around an alternative (a common shape for operator grammars)
    /// must tag that alternative's production, so this peels a leading `precedence` wrapper.
    ///
    /// - Parameters:
    ///   - rule: The alternative or rule being lowered.
    ///   - inherited: The precedence inherited from an enclosing `precedence` rule.
    /// - Returns: The effective precedence to record on the production.
    private func effectivePrecedence(
        of rule: Rule, inherited: (level: Int, assoc: Associativity)?
    ) -> (level: Int, assoc: Associativity)? {
        if case .precedence(let level, let assoc, _) = rule { return (level, assoc) }
        return inherited
    }

    /// Converts a rule into the flat sequence of symbols forming one production's right-hand side.
    ///
    /// EBNF operators that introduce repetition or optionality are lowered to synthetic nonterminals
    /// (each gaining its own productions); sequences inline their parts; tokens and references become
    /// single symbols.
    private mutating func symbols(
        of rule: Rule,
        precedence: (level: Int, assoc: Associativity)?
    ) -> [Symbol] {
        switch rule {
        case .token(let name, let matcher, let isNamed):
            let term = Terminal(matcher: matcher, kindName: name, isNamed: isNamed)
            return [.terminal(intern(terminal: term))]

        case .reference(let name):
            // An undefined reference resolves to a nonterminal with no productions, which can never be
            // completed, forcing recovery exactly as the reference engine does for a dangling reference.
            return [.nonterminal(intern(nonterminal: name))]

        case .sequence(let parts):
            return parts.flatMap { symbols(of: $0, precedence: precedence) }

        case .choice:
            // A nested choice becomes a transparent synthetic nonterminal with one production per branch.
            let nt = freshSynthetic("choice")
            lower(rule, into: nt, emit: .transparent, precedence: precedence, choiceOrdinal: nil)
            return [.nonterminal(nt)]

        case .optional(let sub):
            let nt = freshSynthetic("opt")
            let body = symbols(of: sub, precedence: precedence)
            productions.append(
                Production(lhs: nt, rhs: body, emit: .transparent, precedence: precedence, choiceOrdinal: 0))
            productions.append(
                Production(lhs: nt, rhs: [], emit: .transparent, precedence: precedence, choiceOrdinal: 1))
            return [.nonterminal(nt)]

        case .repeatZeroOrMore(let sub):
            // Left-recursive R → R sub | ε for flat left-to-right child order.
            let nt = freshSynthetic("rep0")
            let body = symbols(of: sub, precedence: precedence)
            productions.append(
                Production(
                    lhs: nt, rhs: [.nonterminal(nt)] + body, emit: .transparent, precedence: precedence,
                    choiceOrdinal: 0))
            productions.append(
                Production(lhs: nt, rhs: [], emit: .transparent, precedence: precedence, choiceOrdinal: 1))
            return [.nonterminal(nt)]

        case .repeatOneOrMore(let sub):
            // Left-recursive R → R sub | sub.
            let nt = freshSynthetic("rep1")
            let body = symbols(of: sub, precedence: precedence)
            productions.append(
                Production(
                    lhs: nt, rhs: [.nonterminal(nt)] + body, emit: .transparent, precedence: precedence,
                    choiceOrdinal: 0))
            productions.append(
                Production(lhs: nt, rhs: body, emit: .transparent, precedence: precedence, choiceOrdinal: 1))
            return [.nonterminal(nt)]

        case .field(let name, let sub):
            let nt = freshSynthetic("field")
            lower(sub, into: nt, emit: .field(name), precedence: precedence, choiceOrdinal: nil)
            return [.nonterminal(nt)]

        case .precedence(let level, let assoc, let sub):
            return symbols(of: sub, precedence: (level, assoc))
        }
    }
}
