import ParsingCore

/// Error-recovery policy shared by the GLR engine, centralising the recovery vocabulary.
///
/// The engine never throws past `parse`: a wholly unparseable input recovers with a `MISSING` value,
/// and unparseable trailing input becomes an `ERROR` node. These two coarse, panic-mode behaviours
/// match the recursive-descent engine so the two engines agree on the differential error cases. The
/// strings and kinds live here in one place so the engines cannot drift.
enum Recovery {
    /// The placeholder kind name for a missing value synthesised when the whole input is unparseable.
    static let missingValueKind = SyntaxKind("value")

    /// The anonymous kind name for a token wrapping unparseable trailing input inside an `ERROR` node.
    static let errorTokenKind = SyntaxKind("<error>", isNamed: false)

    /// The diagnostic message for a wholly unparseable input, parameterised by the start rule.
    ///
    /// - Parameter startRule: The grammar's start rule name.
    /// - Returns: The diagnostic message.
    static func missingStartMessage(startRule: String) -> String { "expected \(startRule)" }

    /// The diagnostic message for unparseable trailing input.
    static let trailingMessage = "unexpected trailing input"
}
