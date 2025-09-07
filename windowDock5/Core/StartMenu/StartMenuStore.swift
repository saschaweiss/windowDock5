import Foundation
import SwiftUI

/// State/Logic rund ums Startmenü (sichtbar/unsichtbar, Prefs, etc.).
/// Hält eine Referenz auf den TileStore (Grid-Daten).
@MainActor
final class StartMenuStore: ObservableObject {
    @Published var prefs = StartMenuPrefs()
    @Published var isVisible: Bool = false
    
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0
    
    var quickActions: [QuickAction] {
        [
            .init(title: "Startmenü ausblenden", systemImage: "xmark.circle") {
                Task { @MainActor in StartMenuController.shared.hide() }
            },
            .init(title: "Neu laden", systemImage: "arrow.clockwise") {
                Task { @MainActor in
                    // your reload code
                }
            }
        ]
    } 

    struct QuickAction {
        let title: String
        let systemImage: String?   // allow nil if you want text-only
        let perform: () -> Void
    }

    /// Dein Grid-Store (Container-/Mini-Grid-Logik steckt dort bereits)
    let tileStore: TileStore

    init(tileStore: TileStore = TileStore(), prefs: StartMenuPrefs = .load()) {
        self.tileStore = tileStore
        self.prefs = prefs
    }

    // MARK: - Window / Visibility

    func toggle() {
        isVisible.toggle()
    }

    func show() {
        isVisible = true
    }

    func hide() {
        isVisible = false
    }

    func applyFrame(_ frame: CGRect) {
        let p = prefs
        p.lastFrame = frame
        p.save()
        prefs = p
    }
    
    func savePrefs() {
        prefs.save()
    }

    // MARK: - Grid Tuning (lebt in Prefs, UI kann’s binden)

    func setGridMinTile(_ v: CGFloat) {
        guard v > 32, v < 300 else { return }
        let p = prefs
        p.gridMinTile = v
        p.save()
        prefs = p
    }

    func setGridSpacing(_ v: CGFloat) {
        guard v >= 0, v < 64 else { return }
        let p = prefs
        p.gridSpacing = v
        p.save()
        prefs = p
    }

    func setMaxColumns(_ n: Int) {
        let clamped = max(1, min(40, n))
        let p = prefs
        p.maxColumns = clamped
        p.save()
        prefs = p

        // Gib’s dem TileStore weiter, falls du dort mitspielst
        tileStore.columns = clamped
    }
}
