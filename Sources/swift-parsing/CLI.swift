import ArgumentParser
import Foundation

/// The `swift-parsing` command-line tool.
///
/// A thin front-end over the parsing framework that mirrors the kind of tooling tree-sitter and
/// ANTLR provide. In the first milestone it can parse JSON through a chosen engine and convert
/// tree-sitter `grammar.json` documents.
@main
struct SwiftParsingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-parsing",
        abstract: "A performant, multi-backend parsing framework for Swift.",
        subcommands: [Parse.self, Convert.self],
        defaultSubcommand: Parse.self
    )
}

/// Parses a JSON file and prints its concrete syntax tree as an S-expression.
struct Parse: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Parse a JSON file and print its syntax tree as an S-expression."
    )

    @Argument(help: "Path to the JSON file to parse.")
    var file: String

    @Option(name: .shortAndLong, help: "Parser engine to use (\(CLICore.availableEngines.joined(separator: ", "))).")
    var engine: String = "rd"

    @Flag(name: .shortAndLong, help: "Also print diagnostics to standard error.")
    var diagnostics: Bool = false

    func run() throws {
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let (sExpression, messages) = try CLICore.parseJSON(text, engineIdentifier: engine)
        print(sExpression)
        if diagnostics {
            for message in messages {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
        }
    }
}

/// Converts a tree-sitter `grammar.json` document into another grammar representation.
struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert a tree-sitter grammar.json document into another representation."
    )

    @Argument(help: "Path to the grammar.json file.")
    var file: String

    @Option(help: "The grammar's start rule name (tree-sitter's first declared rule).")
    var start: String

    @Option(help: "Output format (json).")
    var to: String = "json"

    func run() throws {
        let json = try String(contentsOfFile: file, encoding: .utf8)
        print(try CLICore.convertGrammar(json, startRule: start, target: to))
    }
}
