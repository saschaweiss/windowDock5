import AppKit
import Foundation

public actor WindowScreenResolver {

    public static let shared = WindowScreenResolver()

    // „Gedächtnis“: hilft minimierten/offscreen Fenstern
    private var lastScreenByWindowKey: [String: String] = [:]   // "wn:bid#123" / "wt:bid#Title"
    private var lastScreenByBundle:   [String: String] = [:]    // "com.app.foo" -> "1"

    public init() {}

    /// Liefert gruppierte Fenster pro ScreenID (String)
    public func assignScreens(_ windows: [WindowInfo]) -> [String: [WindowInfo]] {
        guard !windows.isEmpty else { return [:] }

        let primary = NSScreen.main?.wd_displayIDString ?? "primary"
        var grouped: [String: [WindowInfo]] = [:]

        for var w in windows {
            let key = (w.windowNumber != 0) ? "wn:\(w.bundleID)#\(w.windowNumber)" : "wt:\(w.bundleID)#\(w.title)"
 
            // 1) Direkter Frame-Treffer
            if let sid = screenID(for: w.frame) {
                w.screenID = sid
                grouped[sid, default: []].append(w)
                lastScreenByWindowKey[key] = sid
                lastScreenByBundle[w.bundleID] = sid
                continue
            }

            // 2) Cache (Fenster-Key → Screen)
            if let sid = lastScreenByWindowKey[key] ?? lastScreenByBundle[w.bundleID] {
                w.screenID = sid
                grouped[sid, default: []].append(w)
                continue
            }

            // 3) Fallback: Primary
            w.screenID = primary
            grouped[primary, default: []].append(w)
            lastScreenByBundle[w.bundleID] = primary
        }

        // Ordnung: Aktiv vorne, danach Bundle-Klumpen, dann Titel
        for sid in grouped.keys {
            grouped[sid]!.sort { a, b in
                if a.isActive != b.isActive { return a.isActive && !a.isMinimized }
                if a.bundleID != b.bundleID { return a.bundleID < b.bundleID }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }

        return grouped
    }

    // MARK: helpers

    private func screenID(for rect: CGRect) -> String? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        for s in NSScreen.screens {
            if s.frame.intersects(rect) || s.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                return s.wd_displayIDString
            }
        }
        return nil
    }
}
