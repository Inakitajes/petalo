import Foundation

/// Normalizes a captured selection into a compact preview snippet for the
/// prompt surface's selected-text context chip.
public enum SelectedTextPreview {
    /// Collapses every run of whitespace (spaces, tabs, newlines) in `text`
    /// into a single space and trims the ends, so a multi-line selection
    /// previews as a compact single-line snippet.
    ///
    /// The visual 1–2 line truncation with a trailing ellipsis is applied by
    /// SwiftUI's `lineLimit` and `truncationMode`; this function only
    /// normalizes the raw selection so the preview never shows ragged line
    /// breaks or leading/trailing gaps. It performs no length capping of its
    /// own — the layout's `lineLimit` is the single source of truth for the
    /// visible truncation point.
    public static func snippet(from text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
