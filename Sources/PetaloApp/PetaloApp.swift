import AppKit
import SwiftUI

import PetaloCore

@main
struct PetaloApplication: App {
    @NSApplicationDelegateAdaptor(PetaloAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PetaloSettingsView(shortcutController: appDelegate.shortcutController)
        }
    }
}

@MainActor
final class PetaloAppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var instanceLock: SingleInstanceLock?
    private var assistantCoordinator: ContextualAssistantCoordinator?
    lazy var shortcutController = GlobalShortcutController { [weak self] action in
        self?.assistantCoordinator?.invoke(action)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.register(defaults: [
            "screenSelectionMode": ScreenSelectionMode.pointer.rawValue,
        ])

        do {
            let lockDirectory = try Self.lockDirectory()
            guard let lock = try SingleInstanceLock.acquire(
                at: lockDirectory.appendingPathComponent("app.lock")
            ) else {
                NSLog("Petalo: another instance owns the application lock; exiting.")
                NSApp.terminate(nil)
                return
            }
            instanceLock = lock
        } catch {
            NSLog("Petalo failed to acquire its application lock: %@", String(describing: error))
            NSApp.terminate(nil)
            return
        }

        let panelController = NotchPanelController()
        self.panelController = panelController
        let coordinator = ContextualAssistantCoordinator(notchPanelController: panelController)
        assistantCoordinator = coordinator
        panelController.submitHandler = { [weak coordinator] instruction in
            coordinator?.submit(instruction: instruction)
        }
        panelController.cancelHandler = { [weak coordinator] in
            coordinator?.cancel()
        }
        panelController.show()
        shortcutController.registerStoredShortcuts()
    }

    private static func lockDirectory() throws -> URL {
        let baseDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseDirectory.appendingPathComponent("Petalo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
