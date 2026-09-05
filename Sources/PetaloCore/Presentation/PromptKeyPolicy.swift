import Foundation

/// Decides whether the prompt panel should be actively made key — not just
/// permitted to become key — based on the prompt surface's expansion state.
///
/// While expanded, the panel is made key so the hosted text field receives
/// keyboard input immediately: the cursor is blinking and ready to type the
/// moment the surface opens, whether it was opened by a click, a hover, or a
/// shortcut. While collapsed, the panel stays non-key to preserve the
/// transparent-corner click-through contract — clicks in the rounded gaps
/// pass through to whatever is behind the notch.
public enum PromptKeyPolicy {
    /// Returns `true` when the surface is expanded so the panel is made key
    /// and the text field can take focus. Returns `false` when collapsed,
    /// leaving the panel non-key for click-through.
    public static func shouldMakeKey(isExpanded: Bool) -> Bool {
        isExpanded
    }
}
