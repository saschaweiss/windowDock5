import SwiftUI
import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var previousPolicy: NSApplication.ActivationPolicy?

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
 
    func show() {
        // Falls noch kein Fenster existiert: erstellen
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView())
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false
            w.center()
            w.title = "Einstellungen"
            w.contentView = hosting
            w.delegate = self
            self.window = w
        }

        // Bei .accessory zeigen manche Systeme kein „richtiges“ Fenster → temporär .regular setzen
        if NSApp.activationPolicy() == .accessory {
            previousPolicy = .accessory
            NSApp.setActivationPolicy(.regular)
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Beim Schließen ggf. wieder auf .accessory zurück
    func windowWillClose(_ notification: Notification) {
        if previousPolicy == .accessory {
            NSApp.setActivationPolicy(.accessory)
            previousPolicy = nil
        }
    }
}
