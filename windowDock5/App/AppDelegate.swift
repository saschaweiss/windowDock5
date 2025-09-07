import Foundation
import AppKit
import SwiftUI
import Combine
@preconcurrency import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // deine Properties bleiben
    private var startOverlays: [String: NSPanel] = [:]
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.windowsMenu = nil
        NSWindow.allowsAutomaticWindowTabbing = false
        
        let startStore = StartMenuStore()
        let tileStore  = TileStore()
        let prefs      = StartMenuPrefs.load()

        StartMenuController.shared.configure(
            startStore: startStore,
            tileStore:  tileStore,
            prefs:      prefs
        )
        
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts: CFDictionary = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        rebuildStartOverlays()
        
        Task.detached(priority: .userInitiated) {
            let flat = await WindowsInventory.shared.snapshot()
            let final = prepareWindowsForUI(flat)
            let primary = NSScreen.main?.wd_displayIDString ?? "primary"
            let grouped = Dictionary(grouping: final, by: { $0.screenID ?? primary })

            await MainActor.run {
                AssignmentSummaryPopup.present(groupedByScreen: grouped)
            }
        }
        
        Task.detached {
            let list = await WindowsInventory.shared.snapshot()
            let final = prepareWindowsForUI(list)
            let grouped = Dictionary(grouping: final, by: { $0.ownerPID })
            print("Total windows (filtered/deduped): \(final.count)")
            for (pid, wins) in grouped {
                let wns = wins.map { $0.windowNumber }.sorted()
                let titles = wins.map { "\($0.windowNumber)#\($0.title)" }
                print("PID \(pid): \(wins.count) windows  WNs=\(wns)  titles=\(titles)")
            }
        }

        // 2) Ereignisse -> neu snapshotten nur bei Bedarf
        WindowEventMonitor.shared.start()
        WindowEventMonitor.shared.events
            .sink { _ in
                Task.detached {
                    let flat = await WindowsInventory.shared.snapshot()
                    let final = prepareWindowsForUI(flat)
                    let primary = NSScreen.main?.wd_displayIDString ?? "primary"
                    let grouped = Dictionary(grouping: final, by: { $0.screenID ?? primary })
                    // <-- grouped ins UI/Store pushen
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        tearDownOverlays()
    }

    // MARK: - Screens / Overlays

    @objc private func screenParamsChanged() {
        rebuildStartOverlays()
    }

    private func rebuildStartOverlays() {
        tearDownOverlays()

        for screen in NSScreen.screens {
            let sid = screen.wd_displayIDString
            let panel = makeStartPanel(for: screen)

            startOverlays[sid] = panel
            panel.orderFrontRegardless()
        }
    }

    private func tearDownOverlays() {
        for (_, panel) in startOverlays {
            panel.orderOut(nil)
            panel.close()
        }
        startOverlays.removeAll()
    }

    private func makeStartPanel(for screen: NSScreen) -> NSPanel {
        // Höhe der Leiste (gern mit Prefs verknüpfen)
        let barH: CGFloat = StartMenuPrefs.load().taskbarHeight ?? 48

        // Leisten-Frame: screenbreit, am unteren Rand
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: barH)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], // nonactivating = klickbar ohne Fokusklau
            backing: .buffered,
            defer: false,
            screen: screen
        )

        panel.level = .statusBar              // über normalen Fenstern (aber unter Vollbild)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // SwiftUI-Inhalt: Leiste + großer Start-Button links
        let root = TaskbarStripView(barHeight: barH)
            .frame(width: frame.width, height: frame.height)

        let host = NSHostingView(rootView: AnyView(root))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        return panel
    }
}

let deniedBundleIDs: Set<String> = [
    "com.apple.coreservices.uiagent",
    "com.apple.ViewBridgeAuxiliary",
    "com.apple.Spotlight",
    "com.apple.SpotlightHelper",
    "com.apple.WindowServer",
    "com.apple.systemuiserver",
    "com.apple.dock",
    "com.apple.nsattributedstringagent",
    "com.apple.loginwindow"            // ⬅️ neu
]
let deniedTitlePrefixes: [String] = [
    "CursorUIViewService",
    "Open and Save Panel Service",
    "UIElement-",
]

private func isAllowedWindow(_ w: WindowInfo) -> Bool {
    if deniedBundleIDs.contains(w.bundleID) { return false }
    for p in deniedTitlePrefixes where w.title.hasPrefix(p) { return false }
    // banale/unsichtbare Titel nur dann raus, wenn NICHT minimiert
    if !w.isMinimized, w.title.normalizedVisibleTitle().isEmpty { return false }
    return true
}

private func screenIDFromRect(_ rect: CGRect) -> String? {
    guard rect.width > 0, rect.height > 0 else { return nil }
    for s in NSScreen.screens {
        if s.frame.intersects(rect) || s.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) {
            return s.wd_displayIDString
        }
    }
    return NSScreen.main?.wd_displayIDString
}

private func scoreForDedupe(_ w: WindowInfo) -> (Int, Int, Int, Int) {
    let hasScreen = (w.screenID == nil) ? 0 : 1
    let visible   = w.isMinimized ? 0 : 1
    let active    = w.isActive ? 1 : 0
    let area      = Int(max(1, w.frame.width * w.frame.height))
    // besser: mit Screen > sichtbar > aktiv > groß
    return (hasScreen, visible, active, area)
}

/// Liefert alle echten Fenster, dedupliziert pro konkretem Fenster.
/// - lässt minimierte drin
/// - entfernt Begleit-/Servicefenster 
/// - füllt screenID zur Not aus Geometrie
private func prepareWindowsForUI(_ input: [WindowInfo]) -> [WindowInfo] {
    var best: [String: WindowInfo] = [:]
    best.reserveCapacity(input.count)

    for var w in input where isAllowedWindow(w) {
        if w.screenID == nil { w.screenID = screenIDFromRect(w.frame) }

        let key: String
        if w.windowNumber != 0 {
            key = "pid:\(w.ownerPID)#wid:\(w.windowNumber)"
        } else {
            // Fallback-Key falls WID fehlt → (pid + normalisierter Titel + grober Mittelpunkt)
            let cx = Int((w.frame.midX / 10.0).rounded(.towardZero))
            let cy = Int((w.frame.midY / 10.0).rounded(.towardZero))
            key = "pid:\(w.ownerPID)#title:\(w.title.normalizedForKey())#cx:\(cx)#cy:\(cy)"
        }

        if let cur = best[key] {
            if scoreForDedupe(w) > scoreForDedupe(cur) { best[key] = w }
        } else {
            best[key] = w
        }
    }

    return Array(best.values)
}
