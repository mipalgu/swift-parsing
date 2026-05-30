import GrammarImport
import ParsingCore
import ParsingDSL
import RecursiveDescent

/// Engine-agnostic command logic for the `swift-parsing` CLI, factored out of the argument-parsing
/// layer so it can be unit-tested without spawning a process.
enum CLICore {
    /// An error surfaced to the user by the CLI.
    enum CLIError: Error, Equatable, CustomStringConvertible {
        /// The named engine is not known.
        case unknownEngine(String)
        /// The requested conversion target is not known.
        case unknownTarget(String)

        var description: String {
            switch self {
            case .unknownEngine(let name):
                "unknown engine '\(name)' (available: \(availableEngines.joined(separator: ", ")))"
            case .unknownTarget(let name): "unknown conversion target '\(name)' (available: json)"
            }
        }
    }

    /// A native engine the CLI can construct, keyed by the engine type's own `ParserEngine.identifier`.
    private static let nativeEngines: [(id: String, make: @Sendable (Grammar) throws -> any ParserEngine)] = [
        (UTF8Parser.identifier, { try UTF8Parser(grammar: $0) }),
        (ScalarParser.identifier, { try ScalarParser(grammar: $0) }),
        (GraphemeParser.identifier, { try GraphemeParser(grammar: $0) }),
    ]

    /// The identifier of the default engine (UTF-8, the fastest granularity).
    static var defaultEngine: String { UTF8Parser.identifier }

    /// The engine identifiers the CLI can construct, derived from the engine types themselves.
    static var availableEngines: [String] { nativeEngines.map(\.id) }

    /// Builds a parser engine for a grammar by identifier.
    /// - Parameters:
    ///   - identifier: The engine identifier (see ``availableEngines``).
    ///   - grammar: The grammar to parse against.
    /// - Returns: A parser engine.
    /// - Throws: ``CLIError/unknownEngine(_:)`` if the identifier is not recognised, or a
    ///   `GrammarError` if the grammar cannot be prepared.
    static func engine(_ identifier: String, grammar: Grammar) throws -> any ParserEngine {
        guard let factory = nativeEngines.first(where: { $0.id == identifier })?.make else {
            throw CLIError.unknownEngine(identifier)
        }
        return try factory(grammar)
    }

    /// Parses JSON text with the named engine and renders the result.
    /// - Parameters:
    ///   - text: The JSON source to parse.
    ///   - engineIdentifier: The engine to use.
    /// - Returns: The S-expression rendering and the formatted diagnostics (one per line).
    /// - Throws: ``CLIError/unknownEngine(_:)`` or an engine construction error.
    static func parseJSON(_ text: String, engineIdentifier: String) throws -> (
        sExpression: String, diagnostics: [String]
    ) {
        let engine = try engine(engineIdentifier, grammar: JSONGrammar.grammar())
        let result = engine.parse(Source(text))
        return (result.sExpression(), result.diagnostics.map(\.description))
    }

    /// Imports a `grammar.json` document and re-renders it in the requested target format.
    /// - Parameters:
    ///   - json: The `grammar.json` contents.
    ///   - startRule: The grammar's start rule name.
    ///   - target: The output format (`"json"`).
    /// - Returns: The converted output.
    /// - Throws: ``CLIError/unknownTarget(_:)`` or an import error.
    static func convertGrammar(_ json: String, startRule: String, target: String) throws -> String {
        let grammar = try TreeSitterGrammarJSON.grammar(fromString: json, startRule: startRule)
        switch target {
        case "json":
            return try TreeSitterGrammarJSON.exportString(grammar)
        default:
            throw CLIError.unknownTarget(target)
        }
    }
}
