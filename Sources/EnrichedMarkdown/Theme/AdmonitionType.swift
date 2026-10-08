/// The GitHub alert types, the parser's `admonitionType` attribute for them.
/// Any other `> [!TAG]` keeps its tag as written, for a render plugin to
/// claim; unclaimed, it renders as a plain quote.
public enum AdmonitionType: String, CaseIterable, Sendable {
    case note
    case tip
    case important
    case warning
    case caution

    /// The header label ("Note").
    var title: String { rawValue.capitalized }
}
