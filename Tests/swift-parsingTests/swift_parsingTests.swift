import Foundation
import Testing

@testable import swift_parsing

@Suite("CLI core: parse")
struct CLIParseTests {
    @Test("Parses JSON to an S-expression via the default engine")
    func parseValid() throws {
        let (sexp, diagnostics) = try CLICore.parseJSON(#"{"a": 1}"#, engineIdentifier: CLICore.defaultEngine)
        #expect(sexp == "(document (object (pair key: (string (string_content)) value: (number))))")
        #expect(diagnostics.isEmpty)
    }

    @Test("Reports diagnostics for malformed JSON but still returns a tree")
    func parseInvalid() throws {
        let (sexp, diagnostics) = try CLICore.parseJSON("true false", engineIdentifier: CLICore.defaultEngine)
        #expect(sexp.contains("(ERROR"))
        #expect(!diagnostics.isEmpty)
    }

    @Test("Unknown engine is rejected with a helpful message")
    func unknownEngine() {
        #expect(throws: CLICore.CLIError.unknownEngine("glr")) {
            try CLICore.parseJSON("{}", engineIdentifier: "glr")
        }
        #expect(CLICore.CLIError.unknownEngine("glr").description.contains("rd-utf8"))
    }

    @Test("Available engines include the default native engine")
    func availableEngines() {
        #expect(CLICore.availableEngines.contains(CLICore.defaultEngine))
    }

    @Test("Every available engine parses JSON identically", arguments: CLICore.availableEngines)
    func everyEngine(_ identifier: String) throws {
        let (sexp, _) = try CLICore.parseJSON(#"{"a": 1}"#, engineIdentifier: identifier)
        #expect(sexp == "(document (object (pair key: (string (string_content)) value: (number))))")
    }
}

@Suite("CLI core: convert")
struct CLIConvertTests {
    private let grammarJSON = """
    {
      "name": "mini",
      "rules": {
        "s": { "type": "SEQ", "members": [ { "type": "STRING", "value": "a" }, { "type": "SYMBOL", "name": "b" } ] },
        "b": { "type": "STRING", "value": "b" }
      },
      "extras": [ { "type": "PATTERN", "value": "\\\\s+" } ]
    }
    """

    @Test("Converts grammar.json to normalised grammar.json")
    func convertToJSON() throws {
        let output = try CLICore.convertGrammar(grammarJSON, startRule: "s", target: "json")
        #expect(output.contains("\"SEQ\""))
        #expect(output.contains("\"SYMBOL\""))
        #expect(output.contains("\"name\""))
    }

    @Test("Unknown target is rejected")
    func unknownTarget() {
        #expect(throws: CLICore.CLIError.unknownTarget("dsl")) {
            try CLICore.convertGrammar(grammarJSON, startRule: "s", target: "dsl")
        }
        #expect(CLICore.CLIError.unknownTarget("dsl").description.contains("json"))
    }
}

@Suite("CLI commands (end to end)")
struct CLICommandTests {
    private func tempFile(_ contents: String, ext: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-\(UUID().uuidString).\(ext)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("parse subcommand runs on a JSON file (default subcommand and diagnostics flag)")
    func runParse() throws {
        let path = try tempFile(#"{"a": 1} extra"#, ext: "json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Default subcommand: no explicit "parse", with the diagnostics flag to exercise that branch.
        var command = try SwiftParsingCommand.parseAsRoot([path, "--diagnostics"])
        try command.run()
    }

    @Test("convert subcommand runs on a grammar.json file")
    func runConvert() throws {
        let json = #"{ "name": "m", "rules": { "s": { "type": "STRING", "value": "a" } } }"#
        let path = try tempFile(json, ext: "json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var command = try SwiftParsingCommand.parseAsRoot(["convert", path, "--start", "s"])
        try command.run()
    }

    @Test("parse on a missing file throws")
    func runParseMissingFile() throws {
        var command = try SwiftParsingCommand.parseAsRoot(["parse", "/no/such/file.json"])
        #expect(throws: (any Error).self) { try command.run() }
    }
}
