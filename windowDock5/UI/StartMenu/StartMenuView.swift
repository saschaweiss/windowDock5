import SwiftUI
import AppKit

struct StartMenuView: View {
    @ObservedObject var startStore: StartMenuStore
    @ObservedObject var tileStore: TileStore
    let prefs: StartMenuPrefs

    var body: some View {
        HStack(spacing: 0) {
            // LINKE SPALTE (Power, Tools, etc.)
            LeftColumnView(
                tileStore: tileStore,
                actions: {
                    startStore.quickActions.map { qa in
                        LeftAction(title: qa.title, systemImage: qa.systemImage) {
                            qa.perform()
                        }
                    }
                }(),
                displayMode: .iconsOnly, 
                iconSize: 18
            )
            .frame(width: 38)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider().padding(0)

            // MITTE – Programmliste
            ProgramListView(
                query: $startStore.query,
                selectedIndex: $startStore.selectedIndex
            )
            .frame(width: 300)
            .frame(maxHeight: .infinity, alignment: .top)
 
            Divider()

            // RECHTS – Grid (mit Prefs)
            TileGridView(
                store: tileStore,
                gridMinTile: prefs.gridMinTile,
                gridSpacing: prefs.gridSpacing
            )
            .padding(.top, 22)
        }
        .padding(0)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
        )
        // ⬇️ Resize-Handle oben rechts, 2 px Inset
        .overlay(alignment: .topTrailing) {
            ResizeHandleTopRight().padding(.top, 2).padding(.trailing, 2).zIndex(9999)
        }
        .onAppear {
            StartMenuController.shared.configure(
                startStore: startStore,
                tileStore:  tileStore,
                prefs:      prefs
            )
        }
    }
}

// MARK: - Kleiner Handle oben rechts (Drag-Resize + Doppelklick)
private struct ResizeHandleTopRight: View {
    @State private var began = false

    var body: some View {
        // Konstanten klar getrennt -> hilft dem Type-Checker
        let sq: CGFloat = 3
        let gp: CGFloat = 1

        ZStack(alignment: .topTrailing) {
            CornerResizeGlyphTopRight(square: sq, gap: gp, rows: 3, color: .white)
                .allowsHitTesting(false)
        }
        .frame(width: 16, height: 16)   // Hotzone
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    let mouse = NSEvent.mouseLocation
                    if !began {
                        began = true
                        StartMenuController.shared.beginResizeTopRight()
                    }
                    StartMenuController.shared.updateResizeTopRight(to: mouse)
                }
                .onEnded { _ in
                    began = false
                    StartMenuController.shared.commitResize()
                }
        )
        .onTapGesture(count: 2) {
            StartMenuController.shared.toggleMaximizeOrRestore()
        }
        .onHover { inside in
            if inside { CustomCursors.diagonalResize().set() } else { NSCursor.arrow.set() }
        }
    }
}

/// Treppen-Icon: 3 Zeilen, jeweils 2 Quadrate, nach rechts versetzt.
/// Beispiel-Layout (█ = Quadrat):
/// Zeile 0: █ █
/// Zeile 1:   █ █
/// Zeile 2:     █ █
private struct CornerResizeGlyphTopRight: View {
    let square: CGFloat
    let gap: CGFloat
    let rows: Int          // erwartet 3 für 3/2/1
    var color: Color = .white

    var body: some View {
        // maximale Spaltenzahl = rows (für 3/2/1 → 3)
        let colsMax = rows
        let width  = CGFloat(colsMax) * square + CGFloat(colsMax - 1) * gap
        let height = CGFloat(rows)    * square + CGFloat(rows    - 1) * gap

        ZStack(alignment: .topTrailing) {
            ForEach(0..<rows, id: \.self) { r in
                // Anzahl Quadrate in dieser Zeile: rows - r  (3, 2, 1)
                let count = rows - r
                ForEach(0..<count, id: \.self) { j in
                    Rectangle()
                        .fill(color)
                        .frame(width: square, height: square)
                        // rechtsbündig: j=0 ganz rechts, weitere nach links
                        .offset(
                            x: -CGFloat(j) * (square + gap),
                            y:  CGFloat(r) * (square + gap)
                        )
                }
            }
        }
        .frame(width: width, height: height, alignment: .topTrailing)
        .allowsHitTesting(false)
    }
}
