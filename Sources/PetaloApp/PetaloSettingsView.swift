import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

import PetaloCore

struct PetaloSettingsView: View {
    @ObservedObject var shortcutController: GlobalShortcutController
    @AppStorage("screenSelectionMode") private var screenSelectionMode = ScreenSelectionMode.pointer.rawValue
    @AppStorage("glassFrostRadiusNotch") private var notchFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityNotch") private var notchTintOpacity = NotchGlassStyle.defaultTintOpacity
    @AppStorage("glassFrostRadiusPill") private var pillFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityPill") private var pillTintOpacity = NotchGlassStyle.defaultTintOpacity
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?
    @State private var accessibilityAllowed = false
    @State private var screenRecordingAllowed = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch Petalo at login", isOn: Binding(
                    get: { loginItemEnabled },
                    set: updateLoginItem
                ))
                Picker("Show Petalo on", selection: $screenSelectionMode) {
                    Text("Screen with pointer").tag(ScreenSelectionMode.pointer.rawValue)
                    Text("Screen with focused window").tag(ScreenSelectionMode.focusedWindow.rawValue)
                    Text("All displays").tag(ScreenSelectionMode.allDisplays.rawValue)
                }
            } header: {
                Text("General")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
                shortcutRow(
                    title: "Ask about selected text",
                    action: .selectedText,
                    shortcut: shortcutController.configuration.selectedText
                )
                shortcutRow(
                    title: "Ask about screen region",
                    action: .screenRegion,
                    shortcut: shortcutController.configuration.screenRegion
                )
                shortcutRow(
                    title: "Ask ChatGPT directly",
                    action: .directPrompt,
                    shortcut: shortcutController.configuration.directPrompt
                )
                Button("Restore default shortcuts") {
                    shortcutController.restoreDefaults()
                }
                if let registrationError = shortcutController.registrationError {
                    Text(registrationError).foregroundStyle(.red)
                }
            } header: {
                Text("Contextual assistant")
            } footer: {
                Text("Record a shortcut with Command, Option, Control, or Shift. Disabled actions do not register a global shortcut.")
            }

            Section {
                permissionRow(
                    title: "Accessibility",
                    isAllowed: accessibilityAllowed,
                    openAnchor: "Privacy_Accessibility"
                )
                permissionRow(
                    title: "Screen Recording",
                    isAllowed: screenRecordingAllowed,
                    openAnchor: "Privacy_ScreenCapture"
                )
                Button("Refresh permission status", action: refreshPermissionStatus)
            } header: {
                Text("Privacy permissions")
            } footer: {
                Text("Petalo requests Accessibility only for selected text and Screen Recording only after you invoke a region capture.")
            }

            Section {
                appearanceControls(frost: $notchFrostRadius, tint: $notchTintOpacity)
            } header: {
                Text("Appearance · Notch display")
            } footer: {
                Text("The band beside the camera stays black; Tint sets how dark the glass below it fades.")
            }

            Section {
                appearanceControls(frost: $pillFrostRadius, tint: $pillTintOpacity)
            } header: {
                Text("Appearance · External displays")
            } footer: {
                Text("Frosted diffuses what shows through the glass; Tint darkens its base.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionText)
                Button("Quit Petalo") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear(perform: refreshPermissionStatus)
    }

    @ViewBuilder
    private func appearanceControls(frost: Binding<Double>, tint: Binding<Double>) -> some View {
        Slider(value: frost, in: NotchGlassStyle.frostRadiusRange) {
            Text("Frosted")
        } minimumValueLabel: {
            Image(systemName: "circle").foregroundStyle(.secondary).accessibilityLabel("Clear glass")
        } maximumValueLabel: {
            Image(systemName: "circle.fill").foregroundStyle(.secondary).accessibilityLabel("Frosted glass")
        }
        Slider(value: tint, in: NotchGlassStyle.tintOpacityRange) {
            Text("Tint")
        } minimumValueLabel: {
            Image(systemName: "sun.max").foregroundStyle(.secondary).accessibilityLabel("Transparent tint")
        } maximumValueLabel: {
            Image(systemName: "moon.fill").foregroundStyle(.secondary).accessibilityLabel("Dark tint")
        }
        if frost.wrappedValue != NotchGlassStyle.defaultFrostRadius
            || tint.wrappedValue != NotchGlassStyle.defaultTintOpacity {
            Button("Reset to default appearance") {
                frost.wrappedValue = NotchGlassStyle.defaultFrostRadius
                tint.wrappedValue = NotchGlassStyle.defaultTintOpacity
            }
        }
    }

    private static var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemEnabled = enabled
            errorMessage = nil
        } catch {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = "Could not update the login item."
        }
    }

    @ViewBuilder
    private func shortcutRow(
        title: String,
        action: AssistantShortcutAction,
        shortcut: GlobalShortcut?
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            GlobalShortcutRecorder(shortcut: shortcut) { recorded in
                shortcutController.set(recorded, for: action)
            }
            .frame(width: 120, height: 24)
            Button("Disable") {
                shortcutController.set(nil, for: action)
            }
            .disabled(shortcut == nil)
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, isAllowed: Bool, openAnchor: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(isAllowed ? "Allowed" : "Not allowed")
                .foregroundStyle(isAllowed ? .green : .secondary)
            Button("Open") {
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?\(openAnchor)"
                ) else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func refreshPermissionStatus() {
        accessibilityAllowed = AXIsProcessTrusted()
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    }
}
