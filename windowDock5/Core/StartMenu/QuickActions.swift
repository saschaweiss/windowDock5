// Core/StartMenu/QuickActions.swift
import AppKit

enum QuickAction: CaseIterable, Identifiable {
    case power
    case sleep
    case files
    case settings

    var id: String { key }
    var key: String {
        switch self {
        case .power: return "power"
        case .sleep: return "sleep"
        case .files: return "files"
        case .settings: return "settings"
        }
    }

    var title: String {
        switch self {
        case .power: return "Ein/Aus"
        case .sleep: return "Standby"
        case .files: return "Dateien"
        case .settings: return "Einstellungen"
        }
    } 

    var systemImage: String {
        switch self {
        case .power: return "power"
        case .sleep: return "moon.zzz"
        case .files: return "folder.fill"
        case .settings: return "gearshape.fill"
        }
    }

    func perform() {
        switch self {
        case .files:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        case .settings:
            if let url = URL(string: "x-apple.systempreferences:") {
                NSWorkspace.shared.open(url)
            }
        case .sleep:
            // Sandbox-sicherer Direkt-Sleep ist nicht erlaubt.
            // Optional: Nutzer informieren. Menü schließen.
            NSSound.beep()
        case .power:
            // Ausschalten/Neustart erfordert Privilegien → nicht in Sandbox.
            NSSound.beep()
        }
    }
}
