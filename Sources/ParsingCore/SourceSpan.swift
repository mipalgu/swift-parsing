/// A half-open range of UTF-8 byte offsets into a source buffer.
///
/// `SourceSpan` is the stored coordinate used throughout the concrete syntax tree
/// and diagnostics. It is deliberately a tiny value type holding only a start offset
/// and a length so that nodes remain cheap to copy and `Sendable` for free. Reading
/// the underlying bytes is done separately via a borrowed ``Span`` over the source
/// (see ``Source``), which keeps storage compact while access stays memory-safe.
public struct SourceSpan: Hashable, Sendable, CustomStringConvertible {
    /// The UTF-8 byte offset at which the span begins.
    public let start: Int

    /// The number of UTF-8 bytes the span covers.
    public let length: Int

    /// Creates a span.
    ///
    /// - Parameters:
    ///   - start: The UTF-8 byte offset at which the span begins. Must be non-negative.
    ///   - length: The number of UTF-8 bytes covered. Must be non-negative.
    public init(start: Int, length: Int) {
        precondition(start >= 0, "span start must be non-negative")
        precondition(length >= 0, "span length must be non-negative")
        self.start = start
        self.length = length
    }

    /// The UTF-8 byte offset one past the end of the span.
    public var end: Int { start + length }

    /// Whether the span covers zero bytes (used for `MISSING` nodes).
    public var isEmpty: Bool { length == 0 }

    /// The span expressed as a half-open `Range`.
    public var range: Range<Int> { start ..< end }

    /// An empty span positioned at `offset`.
    ///
    /// - Parameter offset: The UTF-8 byte offset of the empty span.
    /// - Returns: A zero-length span at `offset`.
    public static func empty(at offset: Int) -> SourceSpan {
        SourceSpan(start: offset, length: 0)
    }

    /// The smallest span that fully contains both `self` and `other`.
    ///
    /// - Parameter other: Another span to combine with.
    /// - Returns: A span spanning from the lower start to the higher end of the two.
    public func union(_ other: SourceSpan) -> SourceSpan {
        let lo = Swift.min(start, other.start)
        let hi = Swift.max(end, other.end)
        return SourceSpan(start: lo, length: hi - lo)
    }

    public var description: String { "[\(start)..<\(end))" }
}
