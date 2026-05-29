import Foundation
import ParsingCore

/// Imports and exports tree-sitter `grammar.json` documents to and from the ``Grammar`` IR.
///
/// `grammar.json` is the normalised grammar that `tree-sitter generate` produces from a
/// `grammar.js` source. It is plain JSON (unlike `grammar.js`, which is JavaScript and requires a
/// JavaScript engine to evaluate), which makes it the faithful, dependency-free artifact to convert.
///
/// The mapping covers the rule vocabulary tree-sitter emits: `SYMBOL`, `STRING`, `PATTERN`, `SEQ`,
/// `CHOICE` (including the `CHOICE[x, BLANK]` encoding of `optional`), `REPEAT`, `REPEAT1`, `BLANK`,
/// `FIELD`, `PREC`/`PREC_LEFT`/`PREC_RIGHT`/`PREC_DYNAMIC`, `TOKEN`/`IMMEDIATE_TOKEN` and `ALIAS`.
/// `TOKEN` atomicity and `ALIAS` renaming are not represented in the IR yet (the wrapped content is
/// imported directly); `extras` that are rule references (such as `comment`) are skipped because the
/// IR's `extras` hold token patterns only. These are documented first-milestone simplifications.
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

    // MARK: - Import

    /// Imports a grammar from `grammar.json` data.
    ///
    /// - Parameters:
    ///   - data: The `grammar.json` contents.
    ///   - startRule: The start rule name (tree-sitter treats the first declared rule as the start;
    ///     because JSON object order is not preserved on decoding, the caller supplies it explicitly).
    /// - Returns: The imported ``Grammar``.
    /// - Throws: ``ImportError`` if the document is malformed or uses an unknown rule type.
    public static func grammar(from data: Data, startRule: String) throws -> Grammar {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notAnObject
        }
        guard let rawRules = top["rules"] as? [String: Any] else {
            throw ImportError.missingRules
        }
        let name = top["name"] as? String ?? "imported"

        var rules: [String: Rule] = [:]
        for (ruleName, rawRule) in rawRules {
            rules[ruleName] = try importRule(rawRule)
        }

        let extras: [TokenPattern]
        if let rawExtras = top["extras"] as? [Any] {
            extras = rawExtras.compactMap(importExtra)
        } else {
            extras = [.regex("[ \\t\\r\\n]+")]
        }

        return Grammar(name: name, startRule: startRule, rules: rules, extras: extras)
    }

    /// Imports a grammar from a `grammar.json` string.
    /// - Parameters:
    ///   - json: The `grammar.json` text.
    ///   - startRule: The start rule name.
    /// - Returns: The imported ``Grammar``.
    /// - Throws: ``ImportError`` or a JSON decoding error.
    public static func grammar(fromString json: String, startRule: String) throws -> Grammar {
        try grammar(from: Data(json.utf8), startRule: startRule)
    }

    private static func importRule(_ raw: Any) throws -> Rule {
        guard let node = raw as? [String: Any] else { throw ImportError.missingRuleType }
        guard let type = node["type"] as? String else { throw ImportError.missingRuleType }

        switch type {
        case "SYMBOL":
            return .reference(node["name"] as? String ?? "")
        case "STRING":
            return .literal(node["value"] as? String ?? "")
        case "PATTERN":
            let value = node["value"] as? String ?? ""
            return .token(name: value, pattern: .regex(value), isNamed: false)
        case "BLANK":
            return .sequence([])
        case "SEQ":
            return .sequence(try members(node).map(importRule))
        case "CHOICE":
            return try importChoice(node)
        case "REPEAT":
            return .repeatZeroOrMore(try importContent(node))
        case "REPEAT1":
            return .repeatOneOrMore(try importContent(node))
        case "FIELD":
            return .field(node["name"] as? String ?? "", try importContent(node))
        case "PREC", "PREC_DYNAMIC":
            return .precedence(level: intValue(node["value"]), associativity: .none, try importContent(node))
        case "PREC_LEFT":
            return .precedence(level: intValue(node["value"]), associativity: .left, try importContent(node))
        case "PREC_RIGHT":
            return .precedence(level: intValue(node["value"]), associativity: .right, try importContent(node))
        case "TOKEN", "IMMEDIATE_TOKEN", "ALIAS":
            return try importContent(node) // atomicity / alias not represented in the IR yet
        default:
            throw ImportError.unknownRuleType(type)
        }
    }

    private static func importChoice(_ node: [String: Any]) throws -> Rule {
        let rawMembers = try members(node)
        let hasBlank = rawMembers.contains { ($0 as? [String: Any])?["type"] as? String == "BLANK" }
        let nonBlank = try rawMembers
            .filter { ($0 as? [String: Any])?["type"] as? String != "BLANK" }
            .map(importRule)
        let inner: Rule = nonBlank.count == 1 ? nonBlank[0] : .choice(nonBlank)
        return hasBlank ? .optional(inner) : .choice(nonBlank)
    }

    private static func members(_ node: [String: Any]) throws -> [Any] {
        node["members"] as? [Any] ?? []
    }

    private static func importContent(_ node: [String: Any]) throws -> Rule {
        guard let content = node["content"] else { throw ImportError.missingRuleType }
        return try importRule(content)
    }

    private static func importExtra(_ raw: Any) -> TokenPattern? {
        guard let node = raw as? [String: Any], let type = node["type"] as? String else { return nil }
        switch type {
        case "STRING": return (node["value"] as? String).map(TokenPattern.literal)
        case "PATTERN": return (node["value"] as? String).map(TokenPattern.regex)
        default: return nil // e.g. SYMBOL extras (comments) cannot be represented as token patterns
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
            "name": grammar.name,
            "rules": rules,
            "extras": grammar.extras.map(exportExtra),
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
            return ["type": "SYMBOL", "name": name]
        case let .token(_, .literal(text), _):
            return ["type": "STRING", "value": text]
        case let .token(_, .regex(source), _):
            return ["type": "PATTERN", "value": source]
        case let .sequence(rules):
            return ["type": "SEQ", "members": rules.map(exportRule)]
        case let .choice(rules):
            return ["type": "CHOICE", "members": rules.map(exportRule)]
        case let .optional(sub):
            return ["type": "CHOICE", "members": [exportRule(sub), ["type": "BLANK"]]]
        case let .repeatZeroOrMore(sub):
            return ["type": "REPEAT", "content": exportRule(sub)]
        case let .repeatOneOrMore(sub):
            return ["type": "REPEAT1", "content": exportRule(sub)]
        case let .field(name, sub):
            return ["type": "FIELD", "name": name, "content": exportRule(sub)]
        case let .precedence(level, associativity, sub):
            let type = switch associativity {
            case .left: "PREC_LEFT"
            case .right: "PREC_RIGHT"
            case .none: "PREC"
            }
            return ["type": type, "value": level, "content": exportRule(sub)]
        }
    }

    private static func exportExtra(_ pattern: TokenPattern) -> [String: Any] {
        switch pattern {
        case let .literal(text): return ["type": "STRING", "value": text]
        case let .regex(source): return ["type": "PATTERN", "value": source]
        }
    }
}
