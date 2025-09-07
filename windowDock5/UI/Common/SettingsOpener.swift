import AppKit

enum SettingsOpener {
    static func open() {
        DispatchQueue.main.async {
            if #available(macOS 13.0, *) {
                // Ventura+: "Settings"
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                // Monterey und älter: "Preferences"
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
 
