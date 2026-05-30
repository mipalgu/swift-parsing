/// A single problem reported while parsing, anchored to a source location.
///
/// Engines never throw past their public API; instead they always return a complete
/// tree (with `ERROR`/`MISSING` nodes) plus a collection of `Diagnostic` values
/// describing what went wrong and where.
public struct Diagnostic: Hashable, Sendable, CustomStringConvertible {
    /// How serious a diagnostic is.
    public enum Severity: Sendable, Hashable {
        /// A genuine syntax error: the input did not conform to the grammar.
        case error
        /// A non-fatal concern worth surfacing.
        case warning
        /// Informational only.
        case info
    }

    /// The severity of the diagnostic.
    public let severity: Severity

    /// A human-readable description of the problem, in Australian English.
    public let message: String

    /// The byte range the diagnostic refers to.
    public let span: SourceSpan

    /// Creates a diagnostic.
    ///
    /// - Parameters:
    ///   - severity: How serious the diagnostic is.
    ///   - message: A human-readable description of the problem.
    ///   - span: The byte range the diagnostic refers to.
    public init(severity: Severity, message: String, span: SourceSpan) {
        self.severity = severity
        self.message = message
        self.span = span
    }

    /// Creates an error-severity diagnostic.
    ///
    /// - Parameters:
    ///   - message: A human-readable description of the problem.
    ///   - span: The byte range the error refers to.
    /// - Returns: An error diagnostic.
    public static func error(_ message: String, at span: SourceSpan) -> Diagnostic {
        Diagnostic(severity: .error, message: message, span: span)
    }

    /// A human-readable rendering combining severity, message, and source span.
    public var description: String { "\(severity): \(message) \(span)" }
}
