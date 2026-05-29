/// An input source viewed at a chosen element granularity.
///
/// `ParserInput` abstracts the three string views the framework can parse over, so the engine is
/// written once and specialised per granularity: `Substring.UTF8View` (default, fastest),
/// `Substring.UnicodeScalarView` (code points), and `Substring` (grapheme `Character`s). The protocol
/// is a plain `Collection` constraint with a small set of conversion hooks; it imports nothing beyond
/// the standard library, so it is available in Embedded Swift.
public protocol ParserInput: Collection, Sendable where Element: ParserElement, Index: Comparable {
    /// A short, stable name for this granularity (`"utf8"`, `"scalar"`, `"grapheme"`), used to derive
    /// engine identifiers so those identifiers are defined in one place rather than as literals.
    static var granularityName: String { get }

    /// Builds an input view of the given text at this granularity.
    ///
    /// - Parameter text: The source text.
    /// - Returns: A view of `text` whose elements are at this granularity.
    static func make(from text: String) -> Self

    /// Decomposes a literal string into elements at this granularity, for literal matching.
    ///
    /// - Parameter string: The literal text.
    /// - Returns: The literal's elements in order.
    static func elements(of string: String) -> [Element]

    /// Reconstructs the text covered by a slice of this input.
    ///
    /// - Parameter slice: A subsequence of this input.
    /// - Returns: The decoded text for the slice.
    static func text(of slice: SubSequence) -> String
}

extension Substring.UTF8View: ParserInput {
    @inlinable public static var granularityName: String { "utf8" }
    @inlinable public static func make(from text: String) -> Substring.UTF8View { text[...].utf8 }
    @inlinable public static func elements(of string: String) -> [UInt8] { Array(string.utf8) }
    @inlinable public static func text(of slice: SubSequence) -> String { String(decoding: slice, as: UTF8.self) }
}

extension Substring.UnicodeScalarView: ParserInput {
    @inlinable public static var granularityName: String { "scalar" }
    @inlinable public static func make(from text: String) -> Substring.UnicodeScalarView { text[...].unicodeScalars }
    @inlinable public static func elements(of string: String) -> [Unicode.Scalar] { Array(string.unicodeScalars) }
    @inlinable public static func text(of slice: SubSequence) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }
}

extension Substring: ParserInput {
    @inlinable public static var granularityName: String { "grapheme" }
    @inlinable public static func make(from text: String) -> Substring { text[...] }
    @inlinable public static func elements(of string: String) -> [Character] { Array(string) }
    @inlinable public static func text(of slice: Substring) -> String { String(slice) }
}
