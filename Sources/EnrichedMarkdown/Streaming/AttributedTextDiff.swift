import UIKit

/// The smallest edit turning one rendered document into the next, found by
/// trimming the common prefix and suffix. Attachments compare by what they
/// render, not identity: re-rendering a block creates new attachment
/// objects, and swapping in an equal one would rebuild its view (or reload
/// its image) for nothing.
struct AttributedTextDiff: Equatable {
    /// Characters of the old text to replace.
    let replacedRange: NSRange
    /// Characters of the new text replacing them.
    let replacementRange: NSRange
    /// Characters of the new text whose string is new, not just restyled —
    /// what fades in.
    let insertedRange: NSRange

    var isEmpty: Bool { replacedRange.length == 0 && replacementRange.length == 0 }

    /// `unchangedPrefix` characters are known equal (the stable blocks of a
    /// streaming render) and are not compared.
    init(from old: NSAttributedString, to new: NSAttributedString, unchangedPrefix: Int = 0) {
        let oldString = old.string as NSString
        let newString = new.string as NSString
        let oldLength = oldString.length
        let newLength = newString.length
        let start = min(unchangedPrefix, oldLength, newLength)

        let stringPrefix = start + Self.commonPrefixLength(oldString, newString, from: start)
        let prefix = Self.attributedPrefixEnd(old, new, from: start, to: stringPrefix)

        let stringSuffix = Self.commonSuffixLength(oldString, newString, limit: min(oldLength, newLength) - stringPrefix)
        let suffix = Self.attributedSuffixLength(old, new, stringSuffix: stringSuffix, prefix: prefix)

        replacedRange = NSRange(location: prefix, length: oldLength - suffix - prefix)
        replacementRange = NSRange(location: prefix, length: newLength - suffix - prefix)
        insertedRange = NSRange(location: stringPrefix, length: max(0, newLength - stringSuffix - stringPrefix))
    }

    /// Equal text, attributes, and attachment content.
    static func isEquivalent(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> Bool {
        lhs.length == rhs.length && AttributedTextDiff(from: lhs, to: rhs).isEmpty
    }

    // MARK: - Strings

    private static func commonPrefixLength(_ old: NSString, _ new: NSString, from start: Int) -> Int {
        let limit = min(old.length, new.length) - start
        guard limit > 0 else { return 0 }
        return withBuffers(old, NSRange(location: start, length: limit), new, NSRange(location: start, length: limit)) {
            var index = 0
            while index < limit, $0[index] == $1[index] {
                index += 1
            }
            return index
        }
    }

    private static func commonSuffixLength(_ old: NSString, _ new: NSString, limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        let oldRange = NSRange(location: old.length - limit, length: limit)
        let newRange = NSRange(location: new.length - limit, length: limit)
        return withBuffers(old, oldRange, new, newRange) {
            var count = 0
            while count < limit, $0[limit - 1 - count] == $1[limit - 1 - count] {
                count += 1
            }
            return count
        }
    }

    private static func withBuffers(
        _ old: NSString, _ oldRange: NSRange,
        _ new: NSString, _ newRange: NSRange,
        _ body: (UnsafeMutablePointer<unichar>, UnsafeMutablePointer<unichar>) -> Int
    ) -> Int {
        let oldBuffer = UnsafeMutablePointer<unichar>.allocate(capacity: oldRange.length)
        let newBuffer = UnsafeMutablePointer<unichar>.allocate(capacity: newRange.length)
        defer {
            oldBuffer.deallocate()
            newBuffer.deallocate()
        }
        old.getCharacters(oldBuffer, range: oldRange)
        new.getCharacters(newBuffer, range: newRange)
        return body(oldBuffer, newBuffer)
    }

    // MARK: - Attributes

    /// The first index in `start..<end` (equal strings) whose attributes differ.
    private static func attributedPrefixEnd(
        _ old: NSAttributedString,
        _ new: NSAttributedString,
        from start: Int,
        to end: Int
    ) -> Int {
        var index = start
        while index < end {
            let bounds = NSRange(location: index, length: end - index)
            var oldRun = NSRange()
            var newRun = NSRange()
            let oldAttributes = old.attributes(at: index, longestEffectiveRange: &oldRun, in: bounds)
            let newAttributes = new.attributes(at: index, longestEffectiveRange: &newRun, in: bounds)
            guard attributesMatch(oldAttributes, newAttributes) else { return index }
            index = min(NSMaxRange(oldRun), NSMaxRange(newRun))
        }
        return end
    }

    /// How many of the `stringSuffix` trailing characters also match in
    /// attributes, never reaching back past `prefix`.
    private static func attributedSuffixLength(
        _ old: NSAttributedString,
        _ new: NSAttributedString,
        stringSuffix: Int,
        prefix: Int
    ) -> Int {
        let limit = min(stringSuffix, old.length - prefix, new.length - prefix)
        var matched = 0
        while matched < limit {
            let oldIndex = old.length - 1 - matched
            let newIndex = new.length - 1 - matched
            let remaining = limit - matched
            var oldRun = NSRange()
            var newRun = NSRange()
            let oldAttributes = old.attributes(
                at: oldIndex,
                longestEffectiveRange: &oldRun,
                in: NSRange(location: oldIndex + 1 - remaining, length: remaining)
            )
            let newAttributes = new.attributes(
                at: newIndex,
                longestEffectiveRange: &newRun,
                in: NSRange(location: newIndex + 1 - remaining, length: remaining)
            )
            guard attributesMatch(oldAttributes, newAttributes) else { return matched }
            matched += min(oldIndex + 1 - oldRun.location, newIndex + 1 - newRun.location)
        }
        return limit
    }

    static func attributesMatch(
        _ lhs: [NSAttributedString.Key: Any],
        _ rhs: [NSAttributedString.Key: Any]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, value) in lhs {
            guard let other = rhs[key] else { return false }
            if key == .attachment {
                guard attachmentsMatch(value, other) else { return false }
            } else if !(value as AnyObject).isEqual(other) {
                return false
            }
        }
        return true
    }

    /// Same class at the same source range (compared as its own attribute)
    /// renders the same; a table's cells are compared too, since a streamed
    /// row can change them without moving the range's start.
    private static func attachmentsMatch(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let lhs = lhs as? NSTextAttachment, let rhs = rhs as? NSTextAttachment else {
            return (lhs as AnyObject).isEqual(rhs)
        }
        if lhs === rhs {
            return true
        }
        guard type(of: lhs) == type(of: rhs) else { return false }
        if let lhsTable = lhs as? TableAttachment, let rhsTable = rhs as? TableAttachment {
            return lhsTable.plainText() == rhsTable.plainText()
        }
        if let lhsImage = lhs as? MarkdownImageAttachment, let rhsImage = rhs as? MarkdownImageAttachment {
            return lhsImage.isEquivalent(to: rhsImage)
        }
        if let lhsPlugin = lhs as? any MarkdownPluginAttachment, let rhsPlugin = rhs as? any MarkdownPluginAttachment {
            return lhsPlugin.markdownText() == rhsPlugin.markdownText()
        }
        return lhs.bounds == rhs.bounds
    }
}

private extension MarkdownImageAttachment {
    func isEquivalent(to other: MarkdownImageAttachment) -> Bool {
        imageURL == other.imageURL
            && requestHeaders == other.requestHeaders
            && isInline == other.isInline
            && cachedHeight == other.cachedHeight
            && cachedBorderRadius == other.cachedBorderRadius
            && accessibilityLabel == other.accessibilityLabel
    }
}
