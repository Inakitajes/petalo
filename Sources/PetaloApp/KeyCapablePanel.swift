import AppKit

/// Key-capable analog of `NotchPanel`. It may become key so a hosted text
/// view can take focus (for dictation) or a selection view can receive
/// mouse/keyboard input, but it never becomes main and forwards Esc to an
/// `onCancel` closure. The prompt, manual-completion, and region-selection
/// surfaces share this base so `NotchPanel` can stay non-key and keep its
/// transparent-corner click-through contract.
final class KeyCapablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
