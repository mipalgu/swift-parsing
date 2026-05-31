/// A single contiguous edit to a source's UTF-8 byte stream, described in the tree-sitter style.
///
/// An edit replaces the old byte range `startByte..<oldEndByte` with new content occupying
/// `startByte..<newEndByte`. The start offset is shared by both the old and new text (everything before it
/// is unchanged); the two end offsets differ by the edit's length change. A pure insertion has
/// `oldEndByte == startByte`, a pure deletion has `newEndByte == startByte`, and a replacement moves both.
///
/// Offsets are UTF-8 byte offsets, matching ``GreenNode/byteWidth`` and ``SourceSpan``, so an edit lines up
/// with the lossless tree without any granularity conversion.
public struct TextEdit: Hashable, Sendable {
    /// The byte offset at which the change begins, identical in the old and new text.
    public let startByte: Int
    /// The byte offset at which the replaced range ends in the *old* text.
    public let oldEndByte: Int
    /// The byte offset at which the replacement ends in the *new* text.
    public let newEndByte: Int

    /// Creates an edit from its three byte offsets.
    ///
    /// - Parameters:
    ///   - startByte: The offset at which the change begins (shared by old and new text).
    ///   - oldEndByte: The offset at which the replaced range ends in the old text. Must be `>= startByte`.
    ///   - newEndByte: The offset at which the replacement ends in the new text. Must be `>= startByte`.
    public init(startByte: Int, oldEndByte: Int, newEndByte: Int) {
        self.startByte = startByte
        self.oldEndByte = max(startByte, oldEndByte)
        self.newEndByte = max(startByte, newEndByte)
    }

    /// Creates an edit that replaces an old byte range with new content of a given byte length.
    ///
    /// - Parameters:
    ///   - oldRange: The half-open byte range replaced in the old text.
    ///   - newLength: The byte length of the replacement in the new text.
    public init(replacing oldRange: Range<Int>, withNewLength newLength: Int) {
        self.init(
            startByte: oldRange.lowerBound,
            oldEndByte: oldRange.upperBound,
            newEndByte: oldRange.lowerBound + newLength)
    }

    /// The number of old bytes the edit removes.
    public var oldLength: Int { oldEndByte - startByte }
    /// The number of new bytes the edit inserts.
    public var newLength: Int { newEndByte - startByte }
    /// The net change in byte length: positive for a net insertion, negative for a net deletion.
    public var byteDelta: Int { newLength - oldLength }

    /// The damaged byte span of a set of edits in the *new* text: the half-open range from the first
    /// edit's start to the last edit's new end, or `nil` when there are no edits.
    ///
    /// The span is the region a reparse cannot assume is unchanged; content outside it maps unchanged from
    /// the old text (shifted by the accumulated byte delta) and is a candidate for subtree reuse.
    ///
    /// - Parameter edits: The edits applied to the old text, in any order.
    /// - Returns: The combined damaged range in new-text coordinates, or `nil` if `edits` is empty.
    public static func damagedSpan(of edits: [TextEdit]) -> Range<Int>? {
        guard let first = edits.min(by: { $0.startByte < $1.startByte }) else { return nil }
        let start = first.startByte
        let end = edits.map { $0.newEndByte }.max() ?? start
        return start..<max(start, end)
    }
}
