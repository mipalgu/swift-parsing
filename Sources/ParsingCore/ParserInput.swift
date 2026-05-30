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
    /// The granularity name for the UTF-8 code-unit view.
    @inlinable public static var granularityName: String { "utf8" }
    /// Views the text as its UTF-8 code units.
    @inlinable public static func make(from text: String) -> Substring.UTF8View { text[...].utf8 }
    /// Decomposes a literal into its UTF-8 code units.
    @inlinable public static func elements(of string: String) -> [UInt8] { Array(string.utf8) }
    /// Decodes a UTF-8 slice back into text.
    @inlinable public static func text(of slice: SubSequence) -> String { String(decoding: slice, as: UTF8.self) }
}

extension Substring.UnicodeScalarView: ParserInput {
    /// The granularity name for the Unicode-scalar view.
    @inlinable public static var granularityName: String { "scalar" }
    /// Views the text as its Unicode scalars.
    @inlinable public static func make(from text: String) -> Substring.UnicodeScalarView { text[...].unicodeScalars }
    /// Decomposes a literal into its Unicode scalars.
    @inlinable public static func elements(of string: String) -> [Unicode.Scalar] { Array(string.unicodeScalars) }
    /// Reassembles a scalar slice back into text.
    @inlinable public static func text(of slice: SubSequence) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }
}

extension Substring: ParserInput {
    /// The granularity name for the grapheme-cluster view.
    @inlinable public static var granularityName: String { "grapheme" }
    /// Views the text as a substring of grapheme clusters.
    @inlinable public static func make(from text: String) -> Substring { text[...] }
    /// Decomposes a literal into its grapheme-cluster characters.
    @inlinable public static func elements(of string: String) -> [Character] { Array(string) }
    /// Converts a grapheme slice back into text.
    @inlinable public static func text(of slice: Substring) -> String { String(slice) }
}
