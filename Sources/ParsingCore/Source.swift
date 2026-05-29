/// An immutable parse input: the original text together with its UTF-8 byte view.
///
/// Engines scan over the bytes through a borrowed `Span` (`bytes.span`), the safe,
/// bounds-checked alternative to `UnsafeBufferPointer`. The original `String` is
/// retained so callers can recover exact text slices for any ``SourceSpan`` without
/// the tree itself copying substrings.
public struct Source: Sendable, Hashable {
    /// The original source text, exactly as provided.
    public let text: String

    /// The UTF-8 byte encoding of ``text``. This is the buffer all byte offsets index into.
    public let bytes: [UInt8]

    /// Creates a source from a string.
    ///
    /// - Parameter text: The text to parse.
    public init(_ text: String) {
        self.text = text
        self.bytes = Array(text.utf8)
    }

    /// The total number of UTF-8 bytes in the source.
    public var count: Int { bytes.count }

    /// Returns the exact text covered by a span.
    ///
    /// - Parameter span: A byte range within this source. Must lie within bounds.
    /// - Returns: The decoded text for the byte range, or an empty string if the span is empty.
    public func text(of span: SourceSpan) -> String {
        guard !span.isEmpty else { return "" }
        precondition(span.end <= bytes.count, "span out of bounds")
        return String(decoding: bytes[span.range], as: UTF8.self)
    }
}
