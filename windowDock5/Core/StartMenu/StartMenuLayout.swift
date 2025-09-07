// StartMenuLayout.swift
import SwiftUI

/// Wrapper-View, die das Grid mitsamt prefs darstellt.
/// Diese Datei trennt „Startmenü-Layout/Chrome“ vom Grid selbst.
struct StartMenuLayout: View {
    @ObservedObject var store: StartMenuStore

    var body: some View {
        // Falls du noch zusätzliche Chrome/Sidebar/Toolbar willst,
        // hier einklinken. Das Grid rendert eigenständig.
        TileGridView(
            store: store.tileStore,
            gridMinTile: store.prefs.gridMinTile,
            gridSpacing: store.prefs.gridSpacing
        )
        .background(.ultraThinMaterial)
        .onAppear {
            // halte TileStore-Spalten synchron zu Prefs
            store.tileStore.columns = store.prefs.maxColumns
        }
    }
} 
