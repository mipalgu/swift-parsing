import ParsingCore

/// Imports and exports W3C EBNF grammar text to and from the `Grammar` IR.
///
/// The dialect is the Extended Backus-Naur Form used by the W3C in the XML specification and in the
/// formal grammars published at `w3.org`. It was chosen over ISO/IEC 14977 because its constructs map
/// directly onto the IR and onto modern regular-expression intuition: productions use `::=`,
/// concatenation is written by juxtaposition (no comma separator), alternation is `|`, the postfix
/// quantifiers `?` `*` `+` give optional, zero-or-more and one-or-more, parentheses group, terminals
/// are single- or double-quoted strings, character classes are `[...]` (negated `[^...]`) holding
/// literal members, `a-z` ranges and `#xN` hexadecimal code points, and `/* ... */` introduces a
/// comment. ISO/IEC 14977's mandatory concatenation commas, `{ }` repetition and `[ ]` optional
/// brackets are widely criticised as error-prone and are not part of the W3C form, so they are not
/// accepted here.
///
/// The mapping to the IR is total in both directions for the constructs the IR can represent. A
/// production lowers to a named `Rule`; juxtaposition to `.sequence`; `|` to `.choice`; `?` to
/// `.optional`; `*` to `.repeatZeroOrMore`; `+` to `.repeatOneOrMore`; a reference name to
/// `.reference`; a quoted terminal to a literal `.token`; and a character class to a `.token` whose
/// matcher is a scalar range, an alternation of ranges and literals, or a `.negated` matcher. Export
/// renders each of these back to canonical EBNF text.
public enum EBNFGrammar {
    /// An error encountered while importing EBNF text.
    ///
    /// Importing is strict: any structural problem throws one of these cases rather than producing a
    /// partial or guessed grammar.
    public enum ImportError: Error, Hashable, Sendable {
        /// A production was expected (a name followed by `::=`) but the name was missing.
        case expectedProductionName(line: Int)
        /// The definition operator `::=` was expected after a production name but was missing.
        case expectedDefinitionOperator(line: Int)
        /// A term was expected (after an operator, or inside a group) but none was found.
        case expectedTerm(line: Int)
        /// A grouping `(` was opened but never closed by a matching `)`.
        case unbalancedParenthesis(line: Int)
        /// A quoted terminal string was opened but never closed.
        case unterminatedString(line: Int)
        /// A character class `[` was opened but never closed by a matching `]`.
        case unterminatedCharacterClass(line: Int)
        /// A hexadecimal code point `#x...` contained no valid hexadecimal digits.
        case invalidHexadecimal(line: Int)
        /// A comment `/*` was opened but never closed by a matching `*/`.
        case unterminatedComment(line: Int)
        /// The text contained no productions, so there is no grammar to build.
        case emptyGrammar
        /// Input remained after a production was fully parsed (an unexpected token).
        case unexpectedToken(String, line: Int)
    }

    // MARK: - Import

    /// Imports a grammar from EBNF text.
    ///
    /// - Parameters:
    ///   - text: The EBNF grammar text.
    ///   - name: The name to record on the resulting grammar. Defaults to `"ebnf"`.
    ///   - startRule: The start rule name. When `nil`, the first production declared in the text is
    ///     used, matching the convention that the first production is the grammar's goal symbol.
    ///   - extras: Trivia token matchers for the resulting grammar. Defaults to ASCII whitespace.
    /// - Returns: The imported `Grammar`.
    /// - Throws: ``ImportError`` if the text is malformed or declares no productions.
    public static func grammar(
        from text: String,
        name: String = "ebnf",
        startRule: String? = nil,
        extras: [TokenMatcher] = [.builtin(.whitespace)]
    ) throws -> Grammar {
        var parser = Parser(text)
        let productions = try parser.parseGrammar()
        guard let first = productions.first else { throw ImportError.emptyGrammar }

        var rules: [String: Rule] = [:]
        for production in productions { rules[production.name] = production.rule }
        return Grammar(name: name, startRule: startRule ?? first.name, rules: rules, extras: extras)
    }

    // MARK: - Export

    /// Exports a grammar to W3C EBNF text.
    ///
    /// Productions are emitted in a stable order: the start rule first, then the remaining rules by
    /// name, so the output is deterministic and re-importable.
    ///
    /// - Parameter grammar: The grammar to export.
    /// - Returns: The EBNF text. Each production occupies one line in `name ::= expression` form.
    public static func export(_ grammar: Grammar) -> String {
        let ordered =
            [grammar.startRule] + grammar.rules.keys.filter { $0 != grammar.startRule }.sorted()
        var lines: [String] = []
        for name in ordered {
            guard let rule = grammar.rules[name] else { continue }
            lines.append("\(name) \(Notation.define) \(exportRule(rule))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders a single rule as an EBNF expression at the lowest (alternation) precedence.
    private static func exportRule(_ rule: Rule) -> String {
        switch rule {
        case .reference(let name):
            return name
        case .token(_, let matcher, _):
            return exportMatcher(matcher)
        case .sequence(let rules):
            return rules.map(groupedExport).joined(separator: " ")
        case .choice(let rules):
            return rules.map(groupedExport).joined(separator: " \(Notation.alternate) ")
        case .optional(let sub):
            return "\(quantifiedExport(sub))\(Notation.optional)"
        case .repeatZeroOrMore(let sub):
            return "\(quantifiedExport(sub))\(Notation.star)"
        case .repeatOneOrMore(let sub):
            return "\(quantifiedExport(sub))\(Notation.plus)"
        case .field(_, let sub):
            // The IR field label has no W3C EBNF surface form, so the labelled content is emitted bare.
            return exportRule(sub)
        case .precedence(_, _, let sub):
            // Static precedence has no W3C EBNF surface form, so the inner rule is emitted bare.
            return exportRule(sub)
        }
    }

    /// Renders a rule that sits inside a sequence or choice, parenthesising it only when its top-level
    /// operator binds more loosely than the surrounding context.
    private static func groupedExport(_ rule: Rule) -> String {
        switch rule {
        case .choice, .sequence:
            return "\(Notation.groupOpen)\(exportRule(rule))\(Notation.groupClose)"
        case .field(_, let sub), .precedence(_, _, let sub):
            return groupedExport(sub)
        default:
            return exportRule(rule)
        }
    }

    /// Renders a rule that a postfix quantifier (`?`, `*`, `+`) will be attached to, parenthesising any
    /// rule whose own surface form is not already a single atom.
    private static func quantifiedExport(_ rule: Rule) -> String {
        switch rule {
        case .reference, .token:
            return exportRule(rule)
        case .field(_, let sub), .precedence(_, _, let sub):
            return quantifiedExport(sub)
        default:
            return "\(Notation.groupOpen)\(exportRule(rule))\(Notation.groupClose)"
        }
    }

    /// Renders a token matcher as an EBNF terminal or character class.
    private static func exportMatcher(_ matcher: TokenMatcher) -> String {
        switch matcher {
        case .literal(let text):
            return quotedTerminal(text)
        case .anyElement:
            return CharacterClass.anyElement
        case .scalarRange(let range):
            return "\(Notation.classOpen)\(rangeBody(range))\(Notation.classClose)"
        case .builtin(let builtinClass):
            return CharacterClass.export(builtinClass)
        case .negated(let inner):
            return "\(Notation.classOpen)\(Notation.classNegate)\(classBody(of: inner))\(Notation.classClose)"
        case .alternation(let matchers) where matchers.allSatisfy(isClassMember):
            return "\(Notation.classOpen)\(matchers.map(classBody).joined())\(Notation.classClose)"
        case .alternation(let matchers):
            return matchers.map(exportMatcher).joined(separator: " \(Notation.alternate) ")
        case .sequence(let matchers):
            return matchers.map(exportMatcher).joined()
        case .repeated(let min, let max, let inner):
            return exportRepeatedMatcher(min: min, max: max, inner)
        case .lookahead(let negate, let inner):
            // W3C EBNF has no zero-width-assertion surface form, so a lookahead cannot be rendered as a
            // production. Rather than silently drop it, emit a visible EBNF comment naming the construct
            // and the matcher it guards; the comment is skipped on re-import and the export stays total.
            let note = negate ? Notation.negativeLookaheadNote : Notation.positiveLookaheadNote
            return "\(Notation.commentOpen) \(note) \(exportMatcher(inner)) \(Notation.commentClose)"
        }
    }

    /// Renders a repeated matcher with a postfix quantifier when it is `?`, `*` or `+`, otherwise as an
    /// alternation of its character-class members where possible.
    private static func exportRepeatedMatcher(min: Int, max: Int?, _ inner: TokenMatcher) -> String {
        let atom = exportMatcher(inner)
        switch (min, max) {
        case (0, .some(1)): return "\(atom)\(Notation.optional)"
        case (0, .none): return "\(atom)\(Notation.star)"
        case (1, .none): return "\(atom)\(Notation.plus)"
        default: return atom
        }
    }

    /// Whether a matcher can appear as a member of a `[...]` character class.
    ///
    /// Only single-character literals and scalar ranges qualify; a multi-character literal is a terminal
    /// string, not a class member, and must be emitted as a quoted alternative instead.
    private static func isClassMember(_ matcher: TokenMatcher) -> Bool {
        switch matcher {
        case .literal(let text): return text.count == 1
        case .scalarRange: return true
        default: return false
        }
    }

    /// The interior of a character class for a single matcher member.
    private static func classBody(of matcher: TokenMatcher) -> String {
        switch matcher {
        case .literal(let text):
            return text.map(escapeInClass).joined()
        case .scalarRange(let range):
            return rangeBody(range)
        case .alternation(let matchers):
            return matchers.map(classBody).joined()
        case .builtin(let builtinClass):
            return CharacterClass.classBody(builtinClass)
        default:
            return escapeInClass(Character(exportMatcher(matcher)))
        }
    }

    /// Renders the `low-high` body of a scalar range for use inside a character class.
    private static func rangeBody(_ range: ClosedRange<UInt32>) -> String {
        "\(scalarLiteral(range.lowerBound))\(Notation.rangeMarker)\(scalarLiteral(range.upperBound))"
    }

    /// Renders a single scalar value for use inside a character class, using a `#xN` escape when the
    /// scalar is not a safe printable ASCII character.
    private static func scalarLiteral(_ value: UInt32) -> String {
        guard let scalar = Unicode.Scalar(value), value >= 0x21, value < 0x7F else {
            return "\(Notation.hexPrefix)\(String(value, radix: 16, uppercase: true))"
        }
        return escapeInClass(Character(scalar))
    }

    /// Quotes a terminal string, preferring single quotes and falling back to double quotes when the
    /// text itself contains a single quote.
    private static func quotedTerminal(_ text: String) -> String {
        if text.contains(Notation.singleQuote) {
            return "\(Notation.doubleQuote)\(text)\(Notation.doubleQuote)"
        }
        return "\(Notation.singleQuote)\(text)\(Notation.singleQuote)"
    }

    /// Escapes a character that would otherwise terminate or alter a character class.
    private static func escapeInClass(_ character: Character) -> String {
        if character == Notation.classClose || character == Notation.rangeMarker || character == "\\" {
            return "\\\(character)"
        }
        return String(character)
    }
}
