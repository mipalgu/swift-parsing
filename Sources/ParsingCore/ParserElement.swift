/// A single input element at the parser's chosen granularity.
///
/// Conformers are the element types of the supported input views: `UInt8` (UTF-8 code units, the
/// fastest and default granularity), `Unicode.Scalar` (code points), and `Character` (extended
/// grapheme clusters, the most faithful for composite characters but the slowest).
///
/// The protocol exposes only granularity-agnostic, allocation-free, **ASCII-fast-path** information so
/// that token matching works identically at every granularity and remains compatible with Embedded
/// Swift (no `Foundation`, no Unicode data tables on the default path).
public protocol ParserElement: Equatable, Sendable {
    /// The primary Unicode scalar value of this element, used for range and character-class checks.
    ///
    /// For a UTF-8 code unit this is the byte value (`0...255`); for a `Unicode.Scalar` it is the
    /// scalar value; for a `Character` it is the value of its first scalar.
    var scalarValue: UInt32 { get }

    /// The number of UTF-8 bytes this element contributes, used to keep ``SourceSpan`` offsets in bytes.
    var utf8Width: Int { get }
}

extension ParserElement {
    /// Whether this element is an ASCII decimal digit `0`-`9`.
    @inlinable public var isASCIIDigit: Bool { scalarValue >= 0x30 && scalarValue <= 0x39 }

    /// Whether this element is ASCII whitespace (space, tab, newline, carriage return, vertical tab, form feed).
    @inlinable public var isASCIIWhitespace: Bool {
        scalarValue == 0x20 || (scalarValue >= 0x09 && scalarValue <= 0x0D)
    }

    /// Whether this element is an ASCII hexadecimal digit (`0`-`9`, `a`-`f`, `A`-`F`).
    @inlinable public var isASCIIHexDigit: Bool {
        guard !isASCIIDigit else { return true }
        let lower = scalarValue | 0x20
        return lower >= 0x61 && lower <= 0x66
    }

    /// Whether this element is an ASCII letter (`a`-`z`, `A`-`Z`).
    @inlinable public var isASCIILetter: Bool {
        let lower = scalarValue | 0x20
        return lower >= 0x61 && lower <= 0x7A
    }
}

extension UInt8: ParserElement {
    /// The byte value of this UTF-8 code unit (`0...255`).
    @inlinable public var scalarValue: UInt32 { UInt32(self) }
    /// A single UTF-8 code unit always contributes one byte.
    @inlinable public var utf8Width: Int { 1 }
}

extension Unicode.Scalar: ParserElement {
    /// The scalar's Unicode code-point value.
    @inlinable public var scalarValue: UInt32 { value }
    /// The number of UTF-8 bytes needed to encode this scalar.
    @inlinable public var utf8Width: Int {
        switch value {
        case 0..<0x80: 1
        case 0x80..<0x800: 2
        case 0x800..<0x1_0000: 3
        default: 4
        }
    }
}

extension Character: ParserElement {
    /// The value of this character's first Unicode scalar (`0` for the empty case, which cannot occur).
    @inlinable public var scalarValue: UInt32 { unicodeScalars.first?.value ?? 0 }
    /// The total UTF-8 byte width of every scalar in this extended grapheme cluster.
    @inlinable public var utf8Width: Int {
        var total = 0
        for scalar in unicodeScalars { total += scalar.utf8Width }
        return total
    }
}
