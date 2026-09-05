import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

import PetaloCore

enum AssistantShortcutAction: UInt32 {
    case selectedText = 1
    case screenRegion = 2
    case directPrompt = 3
}

/// Carbon hotkeys are system-registered and do not require Accessibility. The
/// registrar owns no event monitor, so it cannot observe ordinary typing.
private final class GlobalShortcutRegistrar {
    enum RegistrationError: Error {
        case systemRejected(OSStatus)
    }

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef?] = []
    private let onAction: (AssistantShortcutAction) -> Void

    init(onAction: @escaping (AssistantShortcutAction) -> Void) {
        self.onAction = onAction
    }

    deinit {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(_ configuration: AssistantShortcutConfiguration) throws {
        unregisterAll()
        guard configuration.validationError == nil else { return }
        try installEventHandlerIfNeeded()

        let requested: [(AssistantShortcutAction, GlobalShortcut?)] = [
            (.selectedText, configuration.selectedText),
            (.screenRegion, configuration.screenRegion),
            (.directPrompt, configuration.directPrompt),
        ]
        for (action, shortcut) in requested {
            guard let shortcut else { continue }
            var hotKey: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x5343_4F50, id: action.rawValue) // "SCOP"
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                carbonModifiers(for: shortcut.modifiers),
                identifier,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            guard status == noErr else {
                unregisterAll()
                throw RegistrationError.systemRejected(status)
            }
            hotKeys.append(hotKey)
        }
    }

    private func unregisterAll() {
        for hotKey in hotKeys {
            if let hotKey {
                UnregisterEventHotKey(hotKey)
            }
        }
        hotKeys = []
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { throw RegistrationError.systemRejected(status) }
    }

    private static let eventHandlerCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              let action = AssistantShortcutAction(rawValue: identifier.id) else {
            return noErr
        }
        let registrar = Unmanaged<GlobalShortcutRegistrar>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            registrar.onAction(action)
        }
        return noErr
    }

    private func carbonModifiers(for modifiers: GlobalShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

@MainActor
final class GlobalShortcutController: ObservableObject {
    @Published private(set) var configuration: AssistantShortcutConfiguration
    @Published private(set) var registrationError: String?

    private let defaults: UserDefaults
    private let registrar: GlobalShortcutRegistrar
    private static let selectedTextKey = "contextualAssistant.selectedTextShortcut"
    private static let screenRegionKey = "contextualAssistant.screenRegionShortcut"
    private static let directPromptKey = "contextualAssistant.directPromptShortcut"
    private static let selectedTextDisabledKey = "contextualAssistant.selectedTextShortcutDisabled"
    private static let screenRegionDisabledKey = "contextualAssistant.screenRegionShortcutDisabled"
    private static let directPromptDisabledKey = "contextualAssistant.directPromptShortcutDisabled"

    init(
        defaults: UserDefaults = .standard,
        onAction: @escaping (AssistantShortcutAction) -> Void
    ) {
        self.defaults = defaults
        configuration = Self.load(from: defaults)
        registrar = GlobalShortcutRegistrar(onAction: onAction)
    }

    func registerStoredShortcuts() {
        do {
            try registrar.register(configuration)
            registrationError = nil
        } catch {
            registrationError = Self.message(for: error)
        }
    }

    func set(_ shortcut: GlobalShortcut?, for action: AssistantShortcutAction) {
        let candidate: AssistantShortcutConfiguration
        switch action {
        case .selectedText:
            candidate = AssistantShortcutConfiguration(
                selectedText: shortcut,
                screenRegion: configuration.screenRegion,
                directPrompt: configuration.directPrompt
            )
        case .screenRegion:
            candidate = AssistantShortcutConfiguration(
                selectedText: configuration.selectedText,
                screenRegion: shortcut,
                directPrompt: configuration.directPrompt
            )
        case .directPrompt:
            candidate = AssistantShortcutConfiguration(
                selectedText: configuration.selectedText,
                screenRegion: configuration.screenRegion,
                directPrompt: shortcut
            )
        }
        apply(candidate)
    }

    func restoreDefaults() {
        apply(.defaults)
    }

    private func apply(_ candidate: AssistantShortcutConfiguration) {
        if let validationError = candidate.validationError {
            registrationError = Self.message(for: validationError)
            return
        }
        let previous = configuration
        do {
            try registrar.register(candidate)
            configuration = candidate
            Self.save(candidate, to: defaults)
            registrationError = nil
        } catch {
            // The previous shortcuts remain best-effort active if the new
            // registration conflicts with another application.
            try? registrar.register(previous)
            registrationError = Self.message(for: error)
        }
    }

    private static func load(from defaults: UserDefaults) -> AssistantShortcutConfiguration {
        AssistantShortcutConfiguration(
            selectedText: defaults.bool(forKey: selectedTextDisabledKey)
                ? nil
                : decode(defaults.data(forKey: selectedTextKey)) ?? AssistantShortcutConfiguration.defaults.selectedText,
            screenRegion: defaults.bool(forKey: screenRegionDisabledKey)
                ? nil
                : decode(defaults.data(forKey: screenRegionKey)) ?? AssistantShortcutConfiguration.defaults.screenRegion,
            directPrompt: defaults.bool(forKey: directPromptDisabledKey)
                ? nil
                : decode(defaults.data(forKey: directPromptKey)) ?? AssistantShortcutConfiguration.defaults.directPrompt
        )
    }

    private static func save(_ configuration: AssistantShortcutConfiguration, to defaults: UserDefaults) {
        save(
            configuration.selectedText,
            dataKey: selectedTextKey,
            disabledKey: selectedTextDisabledKey,
            to: defaults
        )
        save(
            configuration.screenRegion,
            dataKey: screenRegionKey,
            disabledKey: screenRegionDisabledKey,
            to: defaults
        )
        save(
            configuration.directPrompt,
            dataKey: directPromptKey,
            disabledKey: directPromptDisabledKey,
            to: defaults
        )
    }

    private static func save(
        _ shortcut: GlobalShortcut?,
        dataKey: String,
        disabledKey: String,
        to defaults: UserDefaults
    ) {
        defaults.set(shortcut == nil, forKey: disabledKey)
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: dataKey)
        } else {
            defaults.removeObject(forKey: dataKey)
        }
    }

    private static func decode(_ data: Data?) -> GlobalShortcut? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(GlobalShortcut.self, from: data)
    }

    private static func message(for error: AssistantShortcutConfigurationError) -> String {
        switch error {
        case .duplicateShortcut:
            "Two Petalo actions cannot share the same shortcut."
        case .missingModifier:
            "Global shortcuts must include Command, Option, Control, or Shift."
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let GlobalShortcutRegistrar.RegistrationError.systemRejected(status):
            "macOS could not register this shortcut (error \(status)). Choose another one."
        default:
            "Petalo could not register this shortcut. Choose another one."
        }
    }
}

private extension GlobalShortcut {
    var settingsLabel: String {
        let prefix = [
            modifiers.contains(.control) ? "⌃" : "",
            modifiers.contains(.option) ? "⌥" : "",
            modifiers.contains(.shift) ? "⇧" : "",
            modifiers.contains(.command) ? "⌘" : "",
        ].joined()
        let keyLabels: [UInt16: String] = [0: "A", 1: "S", 8: "C"]
        return prefix + (keyLabels[keyCode] ?? "Key \(keyCode)")
    }
}

struct GlobalShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut?
    let onRecord: (GlobalShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(title: shortcut?.settingsLabel ?? "Disabled")
        button.onRecord = onRecord
        return button
    }

    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.idleTitle = shortcut?.settingsLabel ?? "Disabled"
        view.title = view.isRecording ? "Press shortcut…" : view.idleTitle
        view.onRecord = onRecord
    }
}

final class ShortcutRecorderButton: NSButton {
    var onRecord: ((GlobalShortcut) -> Void)?
    fileprivate var isRecording = false
    fileprivate var idleTitle: String

    init(title: String) {
        idleTitle = title
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            isRecording = false
            title = idleTitle
            return
        }
        let modifiers = GlobalShortcutModifiers(event: event)
        guard !modifiers.isEmpty else { return }
        isRecording = false
        onRecord?(GlobalShortcut(keyCode: event.keyCode, modifiers: modifiers))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}

private extension GlobalShortcutModifiers {
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: GlobalShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
