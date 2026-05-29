import Foundation
import Parsing
import ParsingCore

/// Imports and exports tree-sitter `grammar.json` documents to and from the `Grammar` IR.
///
/// `grammar.json` is the normalised grammar that `tree-sitter generate` produces from a
/// `grammar.js` source. It is plain JSON (unlike `grammar.js`, which is JavaScript and requires a
/// JavaScript engine to evaluate), which makes it the faithful, dependency-free artifact to convert.
///
/// The mapping covers the rule vocabulary tree-sitter emits: `SYMBOL`, `STRING`, `PATTERN`, `SEQ`,
/// `CHOICE` (including the `CHOICE[x, BLANK]` encoding of `optional`), `REPEAT`, `REPEAT1`, `BLANK`,
/// `FIELD`, `PREC`/`PREC_LEFT`/`PREC_RIGHT`/`PREC_DYNAMIC`, `TOKEN`/`IMMEDIATE_TOKEN` and `ALIAS`.
/// `TOKEN` atomicity and `ALIAS` renaming are not represented in the IR (the wrapped content is
/// imported directly); `extras` that are rule references (such as `comment`) are skipped because the
/// IR's `extras` hold token matchers only.
public enum TreeSitterGrammarJSON {
    /// An error encountered while importing a `grammar.json` document.
    public enum ImportError: Error, Equatable {
        /// The top level was not a JSON object.
        case notAnObject
        /// The document had no `rules` object.
        case missingRules
        /// A rule node lacked a `type` field.
        case missingRuleType
        /// A rule node used a `type` this importer does not understand.
        case unknownRuleType(String)
    }

    /// The tree-sitter `grammar.json` schema vocabulary, defined once and shared by import and export.
    private enum Schema {
        // Object keys.
        static let name = "name"
        static let rules = "rules"
        static let extras = "extras"
        static let type = "type"
        static let members = "members"
        static let content = "content"
        static let value = "value"
        // Rule-node type tags.
        static let symbol = "SYMBOL"
        static let string = "STRING"
        static let pattern = "PATTERN"
        static let blank = "BLANK"
        static let sequence = "SEQ"
        static let choice = "CHOICE"
        static let repeatZeroOrMore = "REPEAT"
        static let repeatOneOrMore = "REPEAT1"
        static let field = "FIELD"
        static let precedence = "PREC"
        static let precedenceLeft = "PREC_LEFT"
        static let precedenceRight = "PREC_RIGHT"
        static let precedenceDynamic = "PREC_DYNAMIC"
        static let token = "TOKEN"
        static let immediateToken = "IMMEDIATE_TOKEN"
        static let alias = "ALIAS"
    }

    // MARK: - Import

    /// Imports a grammar from `grammar.json` data.
    ///
    /// - Parameters:
    ///   - data: The `grammar.json` contents.
    ///   - startRule: The start rule name (tree-sitter treats the first declared rule as the start;
    ///     because JSON object order is not preserved on decoding, the caller supplies it explicitly).
    /// - Returns: The imported `Grammar`.
    /// - Throws: ``ImportError`` if the document is malformed or uses an unknown rule type.
    public static func grammar(from data: Data, startRule: String) throws -> Grammar {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notAnObject
        }
        guard let rawRules = top[Schema.rules] as? [String: Any] else {
            throw ImportError.missingRules
        }
        let name = top[Schema.name] as? String ?? "imported"

        var rules: [String: Rule] = [:]
        for (ruleName, rawRule) in rawRules {
            rules[ruleName] = try importRule(rawRule)
        }

        let extras: [TokenMatcher]
        if let rawExtras = top[Schema.extras] as? [Any] {
            extras = rawExtras.compactMap(importExtra)
        } else {
            extras = [.builtin(.whitespace)]
        }

        return Grammar(name: name, startRule: startRule, rules: rules, extras: extras)
    }

    /// Imports a grammar from a `grammar.json` string.
    /// - Parameters:
    ///   - json: The `grammar.json` text.
    ///   - startRule: The start rule name.
    /// - Returns: The imported `Grammar`.
    /// - Throws: ``ImportError`` or a JSON decoding error.
    public static func grammar(fromString json: String, startRule: String) throws -> Grammar {
        try grammar(from: Data(json.utf8), startRule: startRule)
    }

    private static func importRule(_ raw: Any) throws -> Rule {
        guard let node = raw as? [String: Any] else { throw ImportError.missingRuleType }
        guard let type = node[Schema.type] as? String else { throw ImportError.missingRuleType }

        switch type {
        case Schema.symbol:
            return .reference(node[Schema.name] as? String ?? "")
        case Schema.string:
            return .literal(node[Schema.value] as? String ?? "")
        case Schema.pattern:
            let value = node[Schema.value] as? String ?? ""
            return .token(name: value, matcher: RegexLowering.matcher(fromRegex: value), isNamed: false)
        case Schema.blank:
            return .sequence([])
        case Schema.sequence:
            return .sequence(try members(node).map(importRule))
        case Schema.choice:
            return try importChoice(node)
        case Schema.repeatZeroOrMore:
            return .repeatZeroOrMore(try importContent(node))
        case Schema.repeatOneOrMore:
            return .repeatOneOrMore(try importContent(node))
        case Schema.field:
            return .field(node[Schema.name] as? String ?? "", try importContent(node))
        case Schema.precedence, Schema.precedenceDynamic:
            return .precedence(level: intValue(node[Schema.value]), associativity: .none, try importContent(node))
        case Schema.precedenceLeft:
            return .precedence(level: intValue(node[Schema.value]), associativity: .left, try importContent(node))
        case Schema.precedenceRight:
            return .precedence(level: intValue(node[Schema.value]), associativity: .right, try importContent(node))
        case Schema.token, Schema.immediateToken, Schema.alias:
            return try importContent(node)
        default:
            throw ImportError.unknownRuleType(type)
        }
    }

    private static func importChoice(_ node: [String: Any]) throws -> Rule {
        let rawMembers = try members(node)
        let isBlank: (Any) -> Bool = { ($0 as? [String: Any])?[Schema.type] as? String == Schema.blank }
        let hasBlank = rawMembers.contains(where: isBlank)
        let nonBlank = try rawMembers.filter { !isBlank($0) }.map(importRule)
        let inner: Rule = nonBlank.count == 1 ? nonBlank[0] : .choice(nonBlank)
        return hasBlank ? .optional(inner) : .choice(nonBlank)
    }

    private static func members(_ node: [String: Any]) throws -> [Any] {
        node[Schema.members] as? [Any] ?? []
    }

    private static func importContent(_ node: [String: Any]) throws -> Rule {
        guard let content = node[Schema.content] else { throw ImportError.missingRuleType }
        return try importRule(content)
    }

    private static func importExtra(_ raw: Any) -> TokenMatcher? {
        guard let node = raw as? [String: Any], let type = node[Schema.type] as? String else { return nil }
        switch type {
        case Schema.string: return (node[Schema.value] as? String).map(TokenMatcher.literal)
        case Schema.pattern: return (node[Schema.value] as? String).map(RegexLowering.matcher(fromRegex:))
        default: return nil // e.g. SYMBOL extras (comments) cannot be represented as token matchers
        }
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        return 0
    }

    // MARK: - Export

    /// Exports a grammar to `grammar.json` data (with sorted keys for deterministic output).
    /// - Parameter grammar: The grammar to export.
    /// - Returns: The `grammar.json` contents.
    /// - Throws: If JSON serialisation fails.
    public static func export(_ grammar: Grammar) throws -> Data {
        var rules: [String: Any] = [:]
        for (name, rule) in grammar.rules { rules[name] = exportRule(rule) }
        let top: [String: Any] = [
            Schema.name: grammar.name,
            Schema.rules: rules,
            Schema.extras: grammar.extras.map(exportExtra),
        ]
        return try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys, .prettyPrinted])
    }

    /// Exports a grammar to a `grammar.json` string.
    /// - Parameter grammar: The grammar to export.
    /// - Returns: The `grammar.json` text.
    /// - Throws: If JSON serialisation fails.
    public static func exportString(_ grammar: Grammar) throws -> String {
        String(decoding: try export(grammar), as: UTF8.self)
    }

    private static func exportRule(_ rule: Rule) -> [String: Any] {
        switch rule {
        case let .reference(name):
            return [Schema.type: Schema.symbol, Schema.name: name]
        case let .token(_, matcher, _):
            if case let .literal(text) = matcher {
                return [Schema.type: Schema.string, Schema.value: text]
            }
            return [Schema.type: Schema.pattern, Schema.value: RegexLowering.regexString(from: matcher)]
        case let .sequence(rules):
            return [Schema.type: Schema.sequence, Schema.members: rules.map(exportRule)]
        case let .choice(rules):
            return [Schema.type: Schema.choice, Schema.members: rules.map(exportRule)]
        case let .optional(sub):
            return [Schema.type: Schema.choice, Schema.members: [exportRule(sub), [Schema.type: Schema.blank]]]
        case let .repeatZeroOrMore(sub):
            return [Schema.type: Schema.repeatZeroOrMore, Schema.content: exportRule(sub)]
        case let .repeatOneOrMore(sub):
            return [Schema.type: Schema.repeatOneOrMore, Schema.content: exportRule(sub)]
        case let .field(name, sub):
            return [Schema.type: Schema.field, Schema.name: name, Schema.content: exportRule(sub)]
        case let .precedence(level, associativity, sub):
            let type = switch associativity {
            case .left: Schema.precedenceLeft
            case .right: Schema.precedenceRight
            case .none: Schema.precedence
            }
            return [Schema.type: type, Schema.value: level, Schema.content: exportRule(sub)]
        }
    }

    private static func exportExtra(_ matcher: TokenMatcher) -> [String: Any] {
        if case let .literal(text) = matcher {
            return [Schema.type: Schema.string, Schema.value: text]
        }
        return [Schema.type: Schema.pattern, Schema.value: RegexLowering.regexString(from: matcher)]
    }
}
