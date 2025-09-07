// Core/Launch/LaunchService.swift
// Starten von Apps (Bundle-ID bevorzugt), robuste Fallbacks.

import AppKit
import Foundation

enum LaunchError: Error {
    case notFound
    case couldNotOpen
}

@MainActor
final class LaunchService {
    static let shared = LaunchService()
    private init() {}

    /// Startet App anhand einer Bundle-ID. Verwendet NSWorkspace; keine Throws.
    @discardableResult
    func launch(bundleID: String) -> Result<Void, LaunchError> {
        guard let url = AppResolver.shared.url(forBundleID: bundleID) else {
            return .failure(.notFound)
        }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
        return .success(())
    }
    
    func launch(appURL url: URL) -> Bool {
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        return true
    }

    /// Startet App anhand eines Anzeigenamens. Versucht zuerst Bundle-ID, sonst heuristisch.
    @discardableResult
    func launch(appNamed name: String) -> Result<Void, LaunchError> {
        // 1) Über Anzeigenamen → URL → Bundle-ID
        if let appURL = AppResolver.shared.findAppURL(byName: name),            // URL aus dem Namen
           let bid    = AppResolver.shared.bundleID(forAppURL: appURL) {         // Bundle-ID aus URL
            return launch(bundleID: bid)                                         // nutzt bereits Result
        }

        // 2) Fallback: /Applications/Name.app bzw. ~/Applications/Name.app
        let candidates: [URL] = [
            URL(fileURLWithPath: "/Applications/\(name).app"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications/\(name).app")
        ]
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            // launch(appURL:) liefert Bool → auf Result mappen
            return launch(appURL: url) ? .success(()) : .failure(.couldNotOpen)
            // Falls dein LaunchError anders heißt: ersetze .openFailed z.B. durch .couldNotOpen
        }

        return .failure(.notFound)
    }
} 
