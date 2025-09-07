import Foundation
import UniformTypeIdentifiers

enum AppConfig {
    // Eindeutiger Bundle-Identifier (sollte mit Info.plist übereinstimmen)
    static let bundleIdentifier: String = {
        Bundle.main.bundleIdentifier ?? "com.saschaweiss.windowDock5"
    }()

    // Custom UTI für Drag&Drop (z.B. von Programmliste → Kacheln)
    static let appIdentifierUTI: String = "\(bundleIdentifier).app-identifier"

    // App-Name (für Anzeigen oder Logging)
    static let displayName: String = "WindowsDock"

    // Weitere zentrale Konstanten
    static let minTileSize: CGFloat = 90
    static let tileSpacing: CGFloat = 10
    static let leftBarWidth: CGFloat = 28
}
 
