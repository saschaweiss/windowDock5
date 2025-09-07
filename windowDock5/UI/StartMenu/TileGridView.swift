import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Monitore (Datei-Ebene, robust)

final class MouseUpMonitor {
    @MainActor static let shared = MouseUpMonitor()
    private var local: Any?
    private var global: Any?
    private var onUp: (() -> Void)?
    private var inDrop = false

    func start(onUp: @escaping () -> Void) {
        stop()
        self.onUp = onUp
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] ev in
            guard let self else { return ev }
            if !self.inDrop { self.onUp?() }
            return ev
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            guard let self else { return }
            if !self.inDrop { self.onUp?() }
        }
    }

    func beginDrop() { inDrop = true }
    func endDrop()   { inDrop = false }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil; global = nil; onUp = nil; inDrop = false
    }
}

final class DragEndMonitor {
    private var local: Any?
    private var global: Any?
    private let onMouseUp: () -> Void

    init(onMouseUp: @escaping () -> Void) {
        self.onMouseUp = onMouseUp
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] ev in
            self?.onMouseUp(); return ev
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            self?.onMouseUp()
        }
    }
    deinit {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
    }
}

// MARK: - Keys, Enums, Utils (Datei-Ebene)

private struct TileFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private enum CellKind: Equatable {
    case empty
    case tile(UUID)
    case ghost
}

// Hilfs-Extension für sichere NSDragOperation-Logik
private extension NSDragOperation {
    func intersection(_ ops: [NSDragOperation]) -> NSDragOperation {
        var out: NSDragOperation = []
        for o in ops where self.contains(o) { out.insert(o) }
        return out
    }
    var first: NSDragOperation? {
        for bit: NSDragOperation in [.copy, .move, .link, .generic, .delete] where self.contains(bit) { return bit }
        return nil
    }
}

// MARK: - Masonry Layout (Datei-Ebene, defensiv)

struct SpanGridLayout: Layout {
    let columns: Int
    let spacing: CGFloat
    /// Optional: feste Zellkante (unit). Wenn gesetzt, wird NICHT skaliert.
    let unitOverride: CGFloat?

    struct Cache { var frames: [CGRect] = []; var size: CGSize = .zero; var unit: CGFloat = 0 }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let width = proposal.width, columns > 0 else { return .zero }

        let pxSpacing  = max(0, spacing)
        let colSpacing = pxSpacing * CGFloat(max(0, columns - 1))
        let unit       = unitOverride ?? ((width - colSpacing) / CGFloat(columns))
        let unitStep   = unit + pxSpacing

        cache.frames.removeAll(keepingCapacity: true)
        cache.frames.reserveCapacity(subviews.count)
        cache.unit = unit

        // 2D-Occupancy (row-major). Wächst bei Bedarf.
        var occ: [[Bool]] = [] // occ[row][col]
        @inline(__always) func ensureRows(_ rows: Int) {
            if rows > occ.count {
                occ.append(contentsOf: Array(repeating: Array(repeating: false, count: columns), count: rows - occ.count))
            }
        }
        @inline(__always) func canPlace(row: Int, col: Int, span: Int) -> Bool {
            guard col >= 0, span >= 1, col + span <= columns else { return false }
            ensureRows(row + span)
            for r in row..<(row + span) {
                for c in col..<(col + span) {
                    if occ[r][c] { return false }
                }
            }
            return true
        }
        @inline(__always) func markPlaced(row: Int, col: Int, span: Int) {
            ensureRows(row + span)
            for r in row..<(row + span) {
                for c in col..<(col + span) {
                    occ[r][c] = true
                }
            }
        }

        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)

        // harte Obergrenze für die Row-Suche: „sicher aber endlich“
        let hardRowCap = max( min(subviews.count * max(1, columns), 10_000), 64)

        for (i, sv) in subviews.enumerated() {
            let span = min(max(1, sv[TileSpanKey.self]), max(1, columns))

            var placed = false
            var row    = 0

            searchRows: while !placed && row < hardRowCap {
                ensureRows(row + span)
                var col = 0

                while col + span <= columns {
                    // große Kacheln nur auf Vielfache von span starten lassen
                    let startCol = (span > 1) ? (col / span) * span : col
                    if startCol + span > columns { break }

                    if canPlace(row: row, col: startCol, span: span) {
                        let x = CGFloat(startCol) * unitStep
                        let y = CGFloat(row)      * unitStep
                        let w = unit * CGFloat(span) + pxSpacing * CGFloat(max(0, span - 1))
                        let h = w

                        let f = CGRect(x: x, y: y, width: w, height: h)
                        _ = subviews[i].sizeThatFits(.init(width: w, height: h))
                        frames.append(f)
                        markPlaced(row: row, col: startCol, span: span)
                        placed = true
                        break searchRows
                    }

                    // bei span>1 in Blöcken springen, sonst normal
                    col += (span > 1 ? span : 1)
                }

                row += 1
            }

            // Fallback (sollte praktisch nie greifen, verhindert aber „unendliche“ Suche)
            if !placed {
                let row = occ.count
                let startCol = 0
                ensureRows(row + span)
                let x = CGFloat(startCol) * unitStep
                let y = CGFloat(row)      * unitStep
                let w = unit * CGFloat(span) + pxSpacing * CGFloat(max(0, span - 1))
                let h = w
                let f = CGRect(x: x, y: y, width: w, height: h)
                _ = subviews[i].sizeThatFits(.init(width: w, height: h))
                frames.append(f)
                markPlaced(row: row, col: startCol, span: span)
            }
        }

        cache.frames = frames

        // echte letzte belegte Zeile finden
        let usedRows = (occ.lastIndex { $0.contains(true) }?.advanced(by: 1)) ?? 0
        let totalHeight = usedRows > 0 ? CGFloat(usedRows) * unitStep - pxSpacing : 0
        let contentWidth = CGFloat(columns) * unit + colSpacing
        cache.size = CGSize(width: contentWidth, height: max(0, totalHeight))
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for (sv, f) in zip(subviews, cache.frames) {
            sv.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                     anchor: .topLeading,
                     proposal: .init(width: f.width, height: f.height))
        }
    }
}

private struct TileSpanKey: LayoutValueKey { static let defaultValue: Int = 1 }
private extension View { func tileSpan(_ span: Int) -> some View { layoutValue(key: TileSpanKey.self, value: max(1, span)) } }

private struct TileGhost: View {
    let span: Int
    let base: CGFloat
    let spacing: CGFloat
    var body: some View {
        let s = CGFloat(max(1, span))
        let side = base * s + (s - 1) * max(0, spacing)
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(style: .init(lineWidth: 2, dash: [6,6]))
            .foregroundColor(.secondary.opacity(0.6))
            .frame(width: side, height: side)
            .allowsHitTesting(false)
    }
}

// MARK: - Render-Sequenz (Datei-Ebene, robust)

private func buildRenderSequence(slots: [UUID?], itemsByID: [UUID: TileItem], totalSlots: Int) -> [(slot: Int, kind: CellKind, span: Int)] {
    let count = max(totalSlots, 0)
    var seq: [(slot: Int, kind: CellKind, span: Int)] = []
    var i = 0
    while i < count {
        if i < slots.count, let id = slots[i], let tile = itemsByID[id] {
            let s = max(1, tile.size.span)
            seq.append((slot: i, kind: .tile(id), span: s))
            i += s
        } else {
            seq.append((slot: i, kind: .empty, span: 1))
            i += 1
        }
    }
    return seq
}

// MARK: - View

struct TileGridView: View {
    @ObservedObject var store: TileStore
    @State private var tileFrames: [UUID: CGRect] = [:]
    @State private var dragEndMonitor: DragEndMonitor?
    @State private var debugLoc: CGPoint? = nil

    let gridMinTile: CGFloat
    let gridSpacing: CGFloat

    private var dropTypes: [UTType] { [ .windowsDockAppIdentifier, .text, .plainText ] }

    init(store: TileStore, gridMinTile: CGFloat, gridSpacing: CGFloat) {
        self.store = store
        self.gridMinTile = gridMinTile
        self.gridSpacing = gridSpacing
    }

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
        .onAppear {
            if store.isReordering && dragEndMonitor == nil {
                dragEndMonitor = DragEndMonitor { Task { @MainActor in store.cancelDrag() } }
            }
        }
        .onChange(of: store.isReordering, initial: false) { _, newValue in
            if newValue && dragEndMonitor == nil {
                dragEndMonitor = DragEndMonitor { Task { @MainActor in store.cancelDrag() } }
            } else if !newValue {
                dragEndMonitor = nil
            }
        }
    }
}

private extension TileGridView {
    private static var _trimmedIconCache: [UUID: NSImage] = [:]
    
    func padSlotsToFullRows(_ slots: [UUID?], cols: Int, atLeastRows: Int) -> [UUID?] {
        guard cols > 0 else { return slots }
        // mindestens so viele Reihen wie Daten + ein paar Extra-Reihen fürs freie Ablegen
        let currentRows = Int(ceil(Double(max(slots.count, 1)) / Double(cols)))
        let targetRows  = max(currentRows, atLeastRows)
        let targetCount = targetRows * cols
        if slots.count >= targetCount { return slots }
        var padded = slots
        padded.append(contentsOf: Array(repeating: nil, count: targetCount - slots.count))
        return padded
    }
    
    @ViewBuilder
    func makeGridContent(seq: [(slot: Int, kind: CellKind, span: Int)], tileSide: CGFloat, spacing: CGFloat, inset: CGSize, cols: Int) -> some View {
        let step = tileSide + spacing
        let lastSlotExclusive = seq.reduce(0) { max($0, $1.slot + $1.span) }
        let rows = max(1, Int(ceil(Double(lastSlotExclusive) / Double(max(1, cols)))))
        let contentHeight = CGFloat(rows) * step - spacing
        let contentWidth  = CGFloat(max(1, cols)) * tileSide + spacing * CGFloat(max(0, cols - 1))

        ZStack(alignment: .topLeading) {
            #if DEBUG
                DebugGridOverlay(cell: step).allowsHitTesting(false)
            #endif

            ForEach(seq, id: \.slot) { entry in
                let slot = max(0, entry.slot)
                let span = max(1, entry.span)
                let row  = slot / max(1, cols)
                let col  = slot % max(1, cols)
                let w = tileSide * CGFloat(span) + spacing * CGFloat(max(0, span - 1))
                let h = w
                let x = CGFloat(col) * step
                let y = CGFloat(row) * step

                Group {
                    switch entry.kind {
                    case .empty:
                        Color.clear.frame(width: w, height: h)
                    case .tile(let id):
                        if let tile = store.itemsByID[id] {
                            tileCell(tile: tile, base: tileSide, spacing: spacing)
                                .frame(width: w, height: h)
                                .accessibilityIdentifier("tile_\(tile.id.uuidString)")
                                .padding(0)
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: TileFrameKey.self, value: [tile.id: proxy.frame(in: .named("GridSpace"))])
                                    }
                                )
                        } else {
                            Color.clear.frame(width: w, height: h)
                        }
                    case .ghost:
                        EmptyView() // wird nicht mehr hier gezeichnet
                    }
                }
                .offset(x: x, y: y)
                .padding(0)
            }

            // ✅ Ghost-Overlay – immer sichtbar, unabhängig von Belegung
            if store.isReordering, let gi = store.ghostIndex {
                let eff = max(1, store.draggingID.flatMap { store.itemsByID[$0]?.size.span } ?? store.ghostSpan)
                let row = gi / max(1, cols)
                let col = gi % max(1, cols)
                let w = tileSide * CGFloat(eff) + spacing * CGFloat(max(0, eff - 1))
                let h = w
                let x = CGFloat(col) * step
                let y = CGFloat(row) * step
                TileGhost(span: eff, base: tileSide, spacing: spacing)
                    .frame(width: w, height: h)
                    .offset(x: x, y: y)
                    .zIndex(999)
                    .allowsHitTesting(false)
            }
        }
        .padding(0)
        .frame(width: contentWidth, height: max(0, contentHeight), alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: "GridSpace")
        .onPreferenceChange(TileFrameKey.self) { frames in
            self.tileFrames = frames          // 👈 merken
        }
    }

    func content(in size: CGSize) -> some View {
        let spacing   = floor(0.0)
        let inset     = CGSize(width: 8, height: 12)

        let usableWidth = max(0, size.width - inset.width * 2)
        let baseTile    = floor(max(1, gridMinTile))

        let colsSmall = Int(floor((usableWidth + spacing) / (baseTile + spacing)))
        let cols      = (store.columns > 0) ? min(store.columns, colsSmall) : colsSmall
        let tileSide  = baseTile

        // sichtbare Reihen
        let innerHeight = max(0, size.height - inset.height * 2)
        let rowsVisible = max(1, Int(floor((innerHeight + spacing) / (tileSide + spacing))))
        let totalSlots  = max(rowsVisible * max(1, cols), store.effectiveDisplaySlots.count)

        // Scroll-Entscheidung
        let neededByData: CGFloat = {
            let count = totalSlots
            let rows  = Int(ceil(Double(count) / Double(max(1, cols))))
            let cell  = tileSide + spacing
            return (rows > 0 ? CGFloat(rows) * cell - spacing : 0) + inset.height * 2
        }()
        let needsScroll = neededByData > size.height + 0.5

        let seq = buildRenderSequence(
            slots: store.effectiveDisplaySlots,
            itemsByID: store.itemsByID,
            totalSlots: totalSlots
        )
        let visibleRows = max(1, totalSlots / max(1, cols))

        // Gemeinsame Overlay-Logik, die IM SELBEN Koordinatensystem wie das Grid sitzt
        @ViewBuilder
        func gridWithDropOverlay() -> some View {
            makeGridContent(seq: seq, tileSide: tileSide, spacing: spacing, inset: inset, cols: cols)
                .overlay(alignment: .topLeading) {
                    DropHost(
                        acceptedUTIs: ["com.saschaweiss.windowDock5.app-identifier","public.plain-text"],
                        store: store,
                        columns: cols,
                        tileSize: tileSide,
                        gridSpacing: spacing,
                        inset: inset,
                        onUpdate: { p in
                            // 1) Container unter der Fläche?
                            if let hit = containerHit(at: p, cols: cols, tileSide: tileSide, spacing: spacing),
                               store.ensureContainerCapacity(hit.id) {
                                store.hoverContainerID   = hit.id
                                store.hoverContainerSlot = hit.slot
                                store.ghostIndex         = nil
                                return
                            } else {
                                store.hoverContainerID   = nil
                                store.hoverContainerSlot = nil
                            }

                            // 2) Normaler Grid-Ghost
                            let raw = store.indexFor(point: CGPoint(x: max(0, p.x), y: max(0, p.y)),
                                                     columns: cols, tileSize: tileSide,
                                                     spacing: spacing, inset: inset)
                            let span = (store.draggingID.flatMap { store.itemsByID[$0]?.size.span } ?? store.ghostSpan)
                            let eff  = max(1, span)
                            let capped = min(max(0, raw), max(0, totalSlots - eff))
                            var row  = capped / cols
                            var col  = capped % cols
                            if eff > 1 { col = (col / eff) * eff; row = (row / eff) * eff }
                            row = min(row, max(0, visibleRows - eff))
                            col = min(col, max(0, cols - eff))
                            store.previewReflow(to: row * cols + col)
                        },
                        onPerform: { ident, p in
                            Task { @MainActor in
                                // 1) Container-Drop?
                                if let hit = containerHit(at: p, cols: cols, tileSide: tileSide, spacing: spacing),
                                   store.ensureContainerCapacity(hit.id) {
                                    store.applyDropIntoContainer(containerID: hit.id, identifier: ident, targetSlot: hit.slot)
                                    store.finishDropCleanup()
                                    return
                                }
                                // 2) Grid-Drop
                                let raw = store.indexFor(point: CGPoint(x: max(0, p.x), y: max(0, p.y)),
                                                         columns: cols, tileSize: tileSide,
                                                         spacing: spacing, inset: inset)
                                let span = (store.draggingID.flatMap { store.itemsByID[$0]?.size.span } ?? store.ghostSpan)
                                let eff  = max(1, span)
                                var row  = raw / cols
                                var col  = raw % cols
                                if eff > 1 { col = (col / eff) * eff; row = (row / eff) * eff }
                                row = min(row, max(0, visibleRows - eff))
                                col = min(col, max(0, cols - eff))
                                let dst = row * cols + col

                                store.applyDropPayload(identifier: ident, suggestedSlot: dst)
                                store.finishDropCleanup()
                            }
                        }
                    )
                    .allowsHitTesting(true) // wichtig!
                }
        }

        return Group {
            if needsScroll {
                ScrollView(.vertical) {
                    gridWithDropOverlay()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, inset.width)
                .padding(.vertical, inset.height)
            } else {
                gridWithDropOverlay()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, inset.width)
                    .padding(.vertical, inset.height)
            }
        }
    }
        
    @ViewBuilder
    func tileCell(tile: TileItem, base: CGFloat, spacing: CGFloat) -> some View {
        let isSource = (store.draggingID == tile.id)

        if tile.isContainer {
            containerCell(tile: tile, base: base, spacing: spacing)
                .contentShape(Rectangle())
                .saturation(isSource ? 0 : 1)
                .opacity(isSource ? 0.35 : 1)
                .zIndex(1)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TileFrameKey.self, value: [tile.id: proxy.frame(in: .named("GridSpace"))])
                    }
                )
                .contextMenu { tileContextMenu(tile: tile) }
                .onTapGesture {
                    store.open(tile.id)                  // ⬅️ einfacher Klick startet App/Datei
                }
                .onDrag {
                    store.beginInternalDrag(id: tile.id, span: tile.size.span)
                    return NSItemProvider(object: tile.id.uuidString as NSString)
                }
        } else {
            // Einheitlicher Rand für alle Icons – keine äußere Kachel-Padding-Variante mehr
            let span       = CGFloat(max(1, tile.size.span))
            let extent     = base * span + spacing * CGFloat(max(0, Int(span) - 1))
            let iconInset  = max(10, round(base * 0.1))   // z.B. 10% Basis-Kachel, min 4pt

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: extent, height: extent)        // 👈 fix: fill full slot

                tileIconView(tile: tile, base: base, isMini: false, fullExtent: extent, edgeInset: iconInset)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(0)
            .frame(width: extent, height: extent)
            .contentShape(Rectangle())
            .background(Color.clear)
            .saturation(isSource ? 0 : 1)
            .opacity((store.isReordering && isSource) ? 0 : 1)
            .zIndex(1)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TileFrameKey.self, value: [tile.id: proxy.frame(in: .named("GridSpace"))])
                }
            )
            .contextMenu { tileContextMenu(tile: tile) }
            .onDrag {
                store.beginInternalDrag(id: tile.id, span: tile.size.span)
                return NSItemProvider(object: tile.id.uuidString as NSString)
            }
        }
    }

    @ViewBuilder
    func tileContextMenu(tile: TileItem) -> some View {
        Button("Öffnen") { store.open(tile.id) }
        Button("Im Finder zeigen") { store.revealInFinder(tile.id) }
        Divider()
        Menu("Größe") {
            ForEach(Array(TileSize.allCases), id: \.self) { s in
                let isCurrent = (tile.size == s)
                Button {
                    store.setSize(tile.id, s)
                } label: {
                    HStack {
                        Text(s.displayName)
                        Spacer()
                        if isCurrent { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        Divider()
        Button(role: .destructive) { store.remove(tile.id) } label: {
            Label("Von Kacheln lösen", systemImage: "trash")
        }
    }

    // Container (2×2 Mini-Grid), Header defensiv
    @ViewBuilder
    func containerCell(tile: TileItem, base: CGFloat, spacing: CGFloat) -> some View {
        // gesamte Container-Seite
        let span          = max(1, tile.size.span)
        let containerSide = base * CGFloat(span) + spacing * CGFloat(max(0, span - 1))

        // kompaktere Ränder im Container
        let outerPad: CGFloat    = 0
        let miniSpacing: CGFloat = 0

        // verfügbare Innenbreite / Mini-Kachel-Kante
        let inner    = max(1, containerSide - outerPad * 2)
        let miniSide = floor((inner - miniSpacing) / 2)

        // --- NEU: Slots stabil aus Mapping aufbauen ---
        let kids = tile.children ?? []
        let map  = store.childSlots[tile.id] ?? [:]

        // 4 sichtbare Plätze (0..3)
        let slotsArr = Array<UUID?>(repeating: nil, count: 4)

        // a) gemappte Einträge setzen, nur gültige IDs/Slots übernehmen
        let preparedSlots: [UUID?] = {
            var arr = slotsArr
            for (cid, pos) in map {
                if (0...3).contains(pos),
                   kids.contains(cid),
                   store.itemsByID[cid] != nil,
                   arr[pos] == nil {
                    arr[pos] = cid
                }
            }
            // b) restliche Kinder in die noch freien Slots
            for cid in kids where !arr.contains(where: { $0 == cid }) {
                if let i = arr.firstIndex(of: nil) {
                    arr[i] = cid
                }
            }
            return arr
        }()

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.10))

            VStack(alignment: .leading, spacing: 0) {                // ⬅️ kein zusätzlicher Vertikal-Shift
                // Fläche exakt auf die Innenkante pinnen (Top/Leading), damit nichts zentriert wird
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(miniSide), spacing: miniSpacing, alignment: .center),
                        GridItem(.fixed(miniSide), spacing: miniSpacing, alignment: .center)
                    ],
                    alignment: .leading,                             // ⬅️ wichtig: leading!
                    spacing: miniSpacing
                ) {
                    ForEach(0..<4, id: \.self) { idx in
                        if let cid = preparedSlots[idx], let child = store.itemsByID[cid] {
                            miniTileCell(child: child, side: miniSide)
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.07))
                                .frame(width: miniSide, height: miniSide)
                                .overlay {
                                    Image(systemName: "plus").imageScale(.small).foregroundColor(.secondary)
                                }
                        }
                    }
                }
                .frame(width: inner, height: inner, alignment: .topLeading) // ⬅️ fix: volle Breite/Höhe, top-left
                .padding(0)
            }
            .padding(2)
            
            if store.isReordering,
               store.hoverContainerID == tile.id,
               let slot = store.hoverContainerSlot {

                let row = max(0, min(1, slot / 2))
                let col = max(0, min(1, slot % 2))

                // Startpunkt der Mini-Fläche liegt 2pt vom Container-Rand (VStack .padding(2))
                let offX = 2 + CGFloat(col) * (miniSide + miniSpacing)
                let offY = 2 + CGFloat(row) * (miniSide + miniSpacing)

                TileGhost(span: 1, base: miniSide, spacing: 0)
                    .frame(width: miniSide, height: miniSide)
                    .offset(x: offX, y: offY)
                    .allowsHitTesting(false)
                    .zIndex(999)
            }
        }
    }
    
    private func containerHit(at p: CGPoint, cols: Int, tileSide: CGFloat, spacing: CGFloat) -> (id: UUID, slot: Int)? {
        // Finde den Container unter p
        let hitPad: CGFloat = 4
        guard let (cid, frame) = tileFrames.compactMap({ (id, f) -> (UUID, CGRect)? in
            guard let t = store.itemsByID[id], t.isContainer else { return nil }
            return (id, f.insetBy(dx: -hitPad, dy: -hitPad))
        }).first(where: { $0.1.contains(p) }) else {
            return nil
        }

        // 1) Lokale Koordinaten
        var local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)

        // 2) Container-Span holen
        let span = store.itemsByID[cid]?.size.span ?? 2   // Default = 2, weil Container = 2x2

        let outerPad: CGFloat   = 0
        let miniSpacing: CGFloat = 0
        let containerSide = tileSide * CGFloat(span) + spacing * CGFloat(max(0, span - 1))

        let inner    = max(1, containerSide - outerPad * 2)
        let miniSide = floor((inner - miniSpacing) / 2)

        // 3) Mini-Gitter beginnt im containerCell 2pt vom Rand
        local.x = max(0, local.x - 2)
        local.y = max(0, local.y - 2)

        // robust clampen auf die 2×2 Fläche
        let step = miniSide + miniSpacing
        let col = max(0, min(1, Int(floor(local.x / step))))
        let row = max(0, min(1, Int(floor(local.y / step))))

        let slot = row * 2 + col
        return (cid, slot)
    }

    @ViewBuilder
    func miniTileCell(child: TileItem, side: CGFloat) -> some View {
        let isSource = (store.draggingID == child.id)

        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            VStack(spacing: 2) {
                tileIconView(tile: child, base: side, isMini: true)
            }
            .padding(0)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Öffnen") { store.open(child.id) }
            Button("Im Finder zeigen") { store.revealInFinder(child.id) }
            Divider()
            Menu("Größe") {
                // Klein (bleibt klein im Container)
                Button("Klein") {
                    // no-op / optional: sicherstellen, dass es klein bleibt
                    if var item = store.itemsByID[child.id], item.size != .small {
                        item.size = .small
                        store.itemsByID[child.id] = item
                        store.syncBack()
                    }
                }
                // ✅ Groß: Promotion ins Grid neben dem Container
                Button("Groß") {
                    store.setSize(child.id, .large)
                }
            }
            Divider()
            Button(role: .destructive) { store.remove(child.id) } label: {
                Label("Aus Container entfernen", systemImage: "trash")
            }
        }
        .onTapGesture {
            store.open(child.id)
        }
        .onDrag {
            store.beginInternalDrag(id: child.id, span: 1)
            return NSItemProvider(object: child.id.uuidString as NSString)
        }
        .opacity((store.isReordering && isSource) ? 0 : 1)// 👈 identisch zu großen Tiles
        .zIndex(1)
    }
    
    // Helper außerhalb eines ViewBuilders platzieren:
    private func fallbackIcon(side: CGFloat) -> NSImage {
        if let sys = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) {
            return sys
        }
        let s = max(8, side)
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s)).fill()
        img.unlockFocus()
        return img
    }
    
    @ViewBuilder
    func tileIconView(tile: TileItem, base: CGFloat, isMini: Bool, fullExtent: CGFloat? = nil, edgeInset: CGFloat = 0) -> some View {
        let span = CGFloat(max(1, tile.size.span))
        let targetSide: CGFloat = fullExtent ?? (isMini ? base * 0.72 : base * 0.46 * span)

        // 1) Icon laden (Datei/BID → NSImage)
        let raw: NSImage = {
            if let url = tile.fileURL, let img = AppResolver.shared.icon(forFileURL: url, size: targetSide) { return img }
            if let bid = tile.bundleID, let img = AppResolver.shared.icon(forBundleID: bid, size: targetSide) { return img }
            return fallbackIcon(side: targetSide)
        }()

        // 2) Getrimmte Variante aus Cache oder on-the-fly erzeugen
        let trimmed: NSImage = {
            if let cached = TileGridView._trimmedIconCache[tile.id] { return cached }
            let t = raw.wd_trimmedTransparentInsets()   // schneidet eingebauten Rand ab
            TileGridView._trimmedIconCache[tile.id] = t
            return t
        }()

        Image(nsImage: trimmed)
            .renderingMode(.original)
            .interpolation(.high)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .padding(edgeInset)                         // definierter, einheitlicher Innenabstand
            .frame(width: targetSide, height: targetSide)
    }
}

extension View {
    @ViewBuilder
    func ifAvailable<T: View>(_ availability: Bool = {
        if #available(macOS 13.0, *) { return true } else { return false }
    }(), transform: (Self) -> T) -> some View {
        if availability { transform(self) } else { self }
    }
    
    @ViewBuilder
    func dragSource<P: View>(
        id: String,
        begin: (() -> Void)? = nil,
        @ViewBuilder preview: () -> P
    ) -> some View {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            self.draggable(id) { preview() }
        } else {
            self.onDrag {
                begin?()
                return NSItemProvider(object: id as NSString)
            }
        }
        #else
        self.onDrag { NSItemProvider(object: id as NSString) }
        #endif
    }
}

private extension NSImage {
    /// Entfernt transparente Außenränder. Optional: ein paar Punkte Rand stehen lassen.
    func wd_trimmedTransparentInsets(padding: CGFloat = 0) -> NSImage {
        guard let cg = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return self }

        let w = cg.width, h = cg.height, bpr = cg.bytesPerRow
        var minX = w, minY = h, maxX = 0, maxY = 0
        var anyOpaque = false

        // RGBA-A geht von 0 (transparent) bis 255 (voll)
        for y in 0..<h {
            let row = y * bpr
            for x in 0..<w {
                let i = row + x * 4
                let a = ptr[i+3]
                if a != 0 {
                    anyOpaque = true
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        // Nichts opak gefunden → unverändert zurück
        guard anyOpaque, minX <= maxX, minY <= maxY else { return self }

        // Padding wieder hinzufügen (z. B. 0–2 pt)
        let pad = Int(max(0, padding))
        let crop = CGRect(
            x: max(0, minX - pad),
            y: max(0, minY - pad),
            width: min(w - 1, maxX + pad) - max(0, minX - pad) + 1,
            height: min(h - 1, maxY + pad) - max(0, minY - pad) + 1
        )
        guard let clipped = cg.cropping(to: crop) else { return self }
        return NSImage(cgImage: clipped, size: NSSize(width: crop.width, height: crop.height))
    }
}

private struct DropHost: NSViewRepresentable {
    let acceptedUTIs: [String]
    var store: TileStore
    var columns: Int
    var tileSize: CGFloat
    var gridSpacing: CGFloat
    var inset: CGSize
    var onUpdate: (CGPoint) -> Void
    var onPerform: (String, CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        DropCatcher(
            acceptedUTIs: acceptedUTIs,
            store: store,
            columns: columns,
            tileSize: tileSize,
            gridSpacing: gridSpacing,
            inset: inset,
            onUpdate: onUpdate,
            onPerform: onPerform
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? DropCatcher else { return }
        v.store       = store
        v.columns     = max(1, columns)
        v.tileSize    = max(1, tileSize)
        v.gridSpacing = max(0, gridSpacing)
        v.inset       = inset
        v.onUpdate    = onUpdate
        v.onPerform   = onPerform
    }

    private static let textTypes: [NSPasteboard.PasteboardType] = [
        .string,
        NSPasteboard.PasteboardType(UTType.plainText.identifier),
        NSPasteboard.PasteboardType(UTType.text.identifier),
        NSPasteboard.PasteboardType("public.utf8-plain-text"),
        NSPasteboard.PasteboardType("public.utf16-plain-text"),
        NSPasteboard.PasteboardType("public.utf16-external-plain-text"),
        NSPasteboard.PasteboardType("NSStringPboardType")
    ]

    static func normalizeIdentifierFromPlaintext(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        if trimmed.contains("."),
           !trimmed.lowercased().hasSuffix(".wdockappid") {
            return trimmed
        }
        let baseName: String = trimmed.lowercased().hasSuffix(".wdockappid")
            ? String(trimmed.dropLast(".wdockappid".count))
            : trimmed

        let apps = await MainActor.run { AppScanner.shared.apps }
        if let app = apps.first(where: { $0.name.caseInsensitiveCompare(baseName) == .orderedSame }) {
            return app.bundleID ?? app.url.path
        }
        return trimmed
    }

    private static func normalizePromisedFile(at url: URL) async -> String {
        if url.pathExtension.lowercased() == "wdockappid" {
            if let data = try? Data(contentsOf: url),
               let s = String(data: data, encoding: .utf8),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return await normalizeIdentifierFromPlaintext(s)
            }
            let base = url.deletingPathExtension().lastPathComponent
            return await normalizeIdentifierFromPlaintext(base)
        }
        return url.path
    }

    final class DropCatcher: NSView {
        var store: TileStore
        var columns: Int
        var tileSize: CGFloat
        var gridSpacing: CGFloat
        var inset: CGSize
        var onUpdate:  (CGPoint) -> Void
        var onPerform: (String, CGPoint) -> Void

        private var didPerformDrop = false
        override var isFlipped: Bool { true }

        init(acceptedUTIs: [String], store: TileStore, columns: Int, tileSize: CGFloat, gridSpacing: CGFloat, inset: CGSize, onUpdate: @escaping (CGPoint) -> Void, onPerform: @escaping (String, CGPoint) -> Void) {
            self.store       = store
            self.columns     = max(1, columns)
            self.tileSize    = max(1, tileSize)
            self.gridSpacing = max(0, gridSpacing)
            self.inset       = inset
            self.onUpdate    = onUpdate
            self.onPerform   = onPerform
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            var types: [NSPasteboard.PasteboardType] = [
                NSPasteboard.PasteboardType("com.saschaweiss.windowDock5.app-identifier"),
                .fileURL,
                .string,
                NSPasteboard.PasteboardType(UTType.text.identifier),
                NSPasteboard.PasteboardType(UTType.plainText.identifier),
                NSPasteboard.PasteboardType("public.utf8-plain-text")
            ]
            types = Array(Set(types))
            registerForDraggedTypes(types)

            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            didPerformDrop = false
            MouseUpMonitor.shared.beginDrop()
            Task { @MainActor in store.dropTransactionActive = true }
            // Nur wenn kein interner Drag läuft, externen Drag-State setzen
            if store.draggingID == nil {
                store.beginExternalDrag()
            }

            _ = draggingUpdated(sender)
            return negotiatedOp(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let p = convert(sender.draggingLocation, from: nil)
            onUpdate(p)

            if !store.isReordering { store.isReordering = true }
            // ⬇️ Fallback: externer Drag (draggingID == nil) und Ghost noch 1? → auf groß stellen
            if store.draggingID == nil && store.ghostSpan < TileSize.large.span {
                store.ghostSpan = TileSize.large.span
            }
            return negotiatedOp(sender)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let p = convert(sender.draggingLocation, from: nil)   // ⬅️ finale Mausposition
            let pb = sender.draggingPasteboard
            // 0) File-URL
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               let appURL = urls.first {
                didPerformDrop = true
                onPerform(appURL.path, p)                         // ⬅️ Position mitgeben
                return true
            }

            // 0b) File-Promise
            if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
               let promise = promises.first {
                let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("WindowDockDrops", isDirectory: true)
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

                didPerformDrop = true
                promise.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: .main) { url, err in
                    Task {
                        if let err { Swift.print("promise error:", err); return }
                        var ident: String?

                        if let data = try? Data(contentsOf: url),
                           let obj  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            ident = (obj["bundleID"] as? String)
                                 ?? (obj["path"]     as? String)
                                 ?? (obj["id"]       as? String)
                        }
                        if ident == nil, let data = try? Data(contentsOf: url),
                           let s = String(data: data, encoding: .utf8) {
                            ident = await DropHost.normalizeIdentifierFromPlaintext(s)
                        }
                        if ident == nil { ident = await DropHost.normalizePromisedFile(at: url) }
                        guard let ident else { return }
                        self.onPerform(ident, p)                   // ⬅️
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                return true
            }

            // 1) ItemProvider / PasteboardItem
            var handled = false
            let customUTI = "com.saschaweiss.windowDock5.app-identifier"
            let textUTIs  = [UTType.plainText.identifier, UTType.text.identifier, "public.utf8-plain-text"]

            sender.enumerateDraggingItems(options: [], for: self, classes: [NSItemProvider.self, NSPasteboardItem.self], searchOptions: [:]) { draggingItem, _, stop in
                guard !handled else { return }

                if let prov = draggingItem.item as? NSItemProvider {
                    if prov.hasItemConformingToTypeIdentifier(customUTI) {
                        self.didPerformDrop = true
                        prov.loadDataRepresentation(forTypeIdentifier: customUTI) { data, _ in
                            if let data,
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let ident = (obj["bundleID"] as? String)
                                       ?? (obj["path"]     as? String)
                                       ?? (obj["id"]       as? String) {
                                DispatchQueue.main.async { self.onPerform(ident, p) }
                            } else if let s = data.flatMap({ String(data: $0, encoding: .utf8) }), !s.isEmpty {
                                DispatchQueue.main.async { self.onPerform(s, p) }
                            }
                        }
                        handled = true; stop.pointee = true; return
                    }
                    for uti in textUTIs where prov.hasItemConformingToTypeIdentifier(uti) {
                        self.didPerformDrop = true
                        prov.loadDataRepresentation(forTypeIdentifier: uti) { data, _ in
                            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            Task {
                                let ident = await DropHost.normalizeIdentifierFromPlaintext(raw)
                                DispatchQueue.main.async { self.onPerform(ident, p) }
                            }
                        }
                        handled = true; stop.pointee = true; return
                    }
                }

                if let item = draggingItem.item as? NSPasteboardItem {
                    let custom = NSPasteboard.PasteboardType(customUTI)
                    if let data = item.data(forType: custom) {
                        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let ident = (obj["bundleID"] as? String)
                                    ?? (obj["path"]     as? String)
                                    ?? (obj["id"]       as? String) {
                            self.didPerformDrop = true
                            self.onPerform(ident, p)
                            handled = true; stop.pointee = true; return
                        }
                        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                            self.didPerformDrop = true
                            self.onPerform(s, p)
                            handled = true; stop.pointee = true; return
                        }
                    }
                    if let t = item.availableType(from: DropHost.textTypes),
                       let raw = item.string(forType: t)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !raw.isEmpty {
                        Task {
                            let ident = await DropHost.normalizeIdentifierFromPlaintext(raw)
                            self.onPerform(ident, p)
                        }
                        self.didPerformDrop = true
                        handled = true; stop.pointee = true; return
                    }
                }
            }
            if handled { return true }

            // 2) Letzter Text-Fallback – schon vorhanden, aber logge Resultat
            for t in DropHost.textTypes {
                if let s0 = pb.string(forType: t), !s0.isEmpty {
                    Task {
                        let ident = await DropHost.normalizeIdentifierFromPlaintext(s0)
                        Swift.print("✅ fallback text(\(t.rawValue)) →", ident)
                        self.onPerform(ident, p)
                    }
                    didPerformDrop = true
                    return true
                }
            }
            
            // 3) ALLERLETZTER Fallback: vollständigen Pasteboard-Dump versuchen
            if let items = pb.pasteboardItems, !items.isEmpty {
                for item in items {
                    for t in item.types {
                        if let s = item.string(forType: t), !s.isEmpty {
                            Task {
                                let ident = await DropHost.normalizeIdentifierFromPlaintext(s)
                                Swift.print("✅ ultimate fallback(\(t.rawValue)) →", ident)
                                self.onPerform(ident, p)
                            }
                            didPerformDrop = true
                            return true
                        }
                    }
                }
            }

            Swift.print("🔴 performDragOperation: no usable payload")
            return false
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            Task { @MainActor in
                MouseUpMonitor.shared.endDrop()
                if !didPerformDrop {
                    // Drop kam nicht zustande → Flag löschen & normalen Cancel erlauben
                    store.dropTransactionActive = false
                    store.cancelDrag()
                }
            }
        }

        private func negotiatedOp(_ sender: NSDraggingInfo) -> NSDragOperation {
            let mask = sender.draggingSourceOperationMask
            let want: NSDragOperation = (store.draggingID == nil) ? .copy : .move
            if mask.contains(want) { return want }
            if mask.contains(.copy) { return .copy }
            if mask.contains(.move) { return .move }
            return mask.intersection([.copy, .move, .link]).first ?? []
        }

        private func cellIndex(for p: CGPoint) -> Int {
            let cellF = tileSize + gridSpacing
            let cell  = max(1, Int(floor(cellF)))             // Integer-Schritt erzwingen

            // identisch zur Grid-Logik: erst Padding abziehen, dann *floor*, nicht runden
            let relX = max(0.0, Double(p.x - inset.width))
            let relY = max(0.0, Double(p.y - inset.height))

            let col = max(0, min(columns - 1, Int(floor(relX / Double(cell)))))
            let row = max(0, Int(floor(relY / Double(cell))))

            return row * columns + col
        }
    }
}

private struct DebugGridOverlay: View {
    let cell: CGFloat
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, size in
                // Vertikale Linien
                var x: CGFloat = 0
                while x <= w + 0.5 {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    ctx.stroke(path, with: .color(.red.opacity(0.25)), lineWidth: 1)
                    x += cell
                }
                // Horizontale Linien
                var y: CGFloat = 0
                while y <= h + 0.5 {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                    ctx.stroke(path, with: .color(.blue.opacity(0.20)), lineWidth: 1)
                    y += cell
                }
            }
        }
    }
}
