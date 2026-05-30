import Foundation
import ParsingCore

/// Imports ANTLR `.g4` grammar text into the `ParsingCore` grammar intermediate representation.
///
/// `.g4` is the human-authored ANTLR grammar format that defines a language's parser and lexer rules in
/// one combined file. This importer lowers a documented subset of that format directly into the
/// framework's scannerless `Grammar`, so a grammar written for ANTLR can be parsed by the native engine
/// without ANTLR or the JVM.
///
/// ## Supported subset
///
/// - A combined grammar header `grammar Name;`.
/// - Parser rules (lowercase initial) and lexer rules (uppercase initial), each a `|`-separated list of
///   alternatives; a leading-underscore parser-rule name is hidden, mirroring tree-sitter's convention.
/// - `fragment` lexer rules, inlined into the lexer rules that reference them.
/// - Elements: rule references, single-quoted string literals (with C-style escapes), character sets
///   `[a-z]` and negated sets `~[...]`/`~'x'`, the dot wildcard `.`, and parenthesised groups.
/// - EBNF suffixes `?`, `*`, and `+`; the non-greedy markers `??`, `*?`, `+?` are accepted and treated
///   as their greedy equivalents, because the native engine resolves alternatives by ordered choice.
/// - Element labels `name=element` and `name+=element`, lowered to grammar fields.
/// - The lexer commands `-> skip` and `-> channel(...)`, whose rules become trivia (`extras`).
/// - The built-in `EOF` reference, which contributes no node.
/// - `//` line comments and `/* */` block comments.
///
/// ## Not supported
///
/// Labelled alternatives (`# Label`), lexical modes, embedded actions `{...}`, semantic predicates,
/// `options`/`tokens`/`channels` blocks, grammar imports, separate `parser grammar`/`lexer grammar`
/// files, and rule arguments or return values. Encountering any of these raises `G4ImportError`.
public enum G4Grammar {
    /// Imports a grammar from `.g4` source text.
    /// - Parameter text: The ANTLR `.g4` grammar text.
    /// - Returns: The imported grammar.
    /// - Throws: `G4ImportError` if the text is malformed or uses an unsupported construct.
    public static func grammar(fromString text: String) throws(G4ImportError) -> Grammar {
        var lexer = G4Lexer(text)
        let tokens = try lexer.tokenise()
        var parser = G4Parser(tokens)
        let parsed = try parser.parse()
        let lowering = try G4Lowering(parsed)
        return try lowering.grammar()
    }

    /// Imports a grammar from `.g4` source data (decoded as UTF-8).
    /// - Parameter data: The ANTLR `.g4` grammar contents.
    /// - Returns: The imported grammar.
    /// - Throws: `G4ImportError` if the text is malformed or uses an unsupported construct.
    public static func grammar(from data: Data) throws(G4ImportError) -> Grammar {
        try grammar(fromString: String(decoding: data, as: UTF8.self))
    }

    /// A JSON grammar expressed in ANTLR `.g4` syntax, shipped as a portable string so it is available
    /// on every platform (including WebAssembly) without relying on bundle resources.
    ///
    /// Its rule and node names match `ParsingDSL.JSONGrammar`, so importing it and parsing with the
    /// native engine yields the same concrete syntax tree.
    public static let jsonGrammar: String = """
        grammar JSON;
        document : _value EOF ;
        _value : object | array | string | number | true | false | null ;
        object : '{' ( pair ( ',' pair )* )? '}' ;
        pair : key=( string | number ) ':' value=_value ;
        array : '[' ( _value ( ',' _value )* )? ']' ;
        string : '"' string_content? '"' ;
        string_content : STRING_CONTENT ;
        number : NUMBER ;
        true : 'true' ;
        false : 'false' ;
        null : 'null' ;
        STRING_CONTENT : ~'"'+ ;
        NUMBER : '-'? ( '0' | [1-9] [0-9]* ) ( '.' [0-9]+ )? ( [eE] [+-]? [0-9]+ )? ;
        WS : [ \\t\\n\\r]+ -> skip ;
        """
}
