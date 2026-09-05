import Foundation

/// Modifier flags shared with the Carbon registration adapter without taking a
/// dependency on AppKit. Only flags meaningful to global shortcuts are kept.
public struct GlobalShortcutModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let command = GlobalShortcutModifiers(rawValue: 1 << 0)
    public static let option = GlobalShortcutModifiers(rawValue: 1 << 1)
    public static let control = GlobalShortcutModifiers(rawValue: 1 << 2)
    public static let shift = GlobalShortcutModifiers(rawValue: 1 << 3)
}

public struct GlobalShortcut: Hashable, Sendable, Codable {
    public let keyCode: UInt16
    public let modifiers: GlobalShortcutModifiers

    public init(keyCode: UInt16, modifiers: GlobalShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum AssistantShortcutConfigurationError: Equatable, Sendable {
    case duplicateShortcut
    case missingModifier
}

/// `nil` disables a shortcut. Defaults are intentionally distinct and can be
/// restored by the settings UI after a user changes or disables any action.
public struct AssistantShortcutConfiguration: Equatable, Sendable {
    public static let defaults = AssistantShortcutConfiguration(
        selectedText: GlobalShortcut(keyCode: 8, modifiers: [.command, .shift]),
        screenRegion: GlobalShortcut(keyCode: 1, modifiers: [.command, .shift]),
        directPrompt: GlobalShortcut(keyCode: 0, modifiers: [.command, .shift])
    )

    public let selectedText: GlobalShortcut?
    public let screenRegion: GlobalShortcut?
    /// Opens the prompt surface with no captured context — the user just types
    /// and sends. This mirrors the hover/click path (`beginDirectDelivery` with
    /// an `.none` context) but via a global hotkey.
    public let directPrompt: GlobalShortcut?

    public init(
        selectedText: GlobalShortcut?,
        screenRegion: GlobalShortcut?,
        directPrompt: GlobalShortcut? = nil
    ) {
        self.selectedText = selectedText
        self.screenRegion = screenRegion
        self.directPrompt = directPrompt
    }

    public var validationError: AssistantShortcutConfigurationError? {
        let shortcuts = [selectedText, screenRegion, directPrompt].compactMap { $0 }
        guard shortcuts.allSatisfy({ !$0.modifiers.isEmpty }) else {
            return .missingModifier
        }
        guard Set(shortcuts).count == shortcuts.count else {
            return .duplicateShortcut
        }
        return nil
    }
}
