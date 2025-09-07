import SwiftUI

@main
struct WindowsDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Kein WindowGroup – die Overlays erstellt der AppDelegate.
        Settings {
            // Falls du eine Settings-Ansicht hast – sonst leer lassen.
            EmptyView()
        }
    }
} 
