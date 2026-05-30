/// An error raised while compiling query source text into a ``Query``.
///
/// Matching never throws: a compiled query simply yields no matches where a tree does not satisfy
/// it. Only the up-front compilation of malformed query text fails, and it does so with one of these
/// cases, each carrying the byte offset at which the problem was detected so callers can point at it.
public enum QueryError: Error, Hashable, Sendable {
    /// A character that cannot begin or continue a pattern was found at the given UTF-8 byte offset.
    case unexpectedCharacter(Character, offset: Int)
    /// The source ended while a construct (a node, group, alternation or predicate) was still open.
    case unexpectedEnd
    /// A closing delimiter (`)` or `]`) was found with no matching opener, at the given byte offset.
    case unbalancedDelimiter(Character, offset: Int)
    /// A node-type name was expected (after `(`) but something else was found, at the given byte offset.
    case expectedNodeName(offset: Int)
    /// A capture name was expected (after `@`) but none followed, at the given byte offset.
    case expectedCaptureName(offset: Int)
    /// A predicate was written with a name this engine does not implement, at the given byte offset.
    case unknownPredicate(String, offset: Int)
    /// A predicate was given the wrong number or kind of arguments, with a human-readable reason.
    case malformedPredicate(String)
    /// A quantifier (`?`, `*` or `+`) appeared with nothing before it to quantify, at the given offset.
    case danglingQuantifier(Character, offset: Int)
    /// A field label (`name:`) appeared with no node, group or alternation following it, at the offset.
    case danglingField(String, offset: Int)
}
