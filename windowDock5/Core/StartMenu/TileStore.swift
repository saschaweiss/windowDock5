import Foundation
import SwiftUI
import OSLog
import AppKit

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "WindowDock", category: "TileStore")

@MainActor
final class TileStore: ObservableObject {
    // MARK: Persistente Daten
    @Published var tiles: [TileItem] = []                 // nur "Top-Level" Reihenfolge (nicht Grid-Slots!)
    @Published var itemsByID: [UUID: TileItem] = [:]      // Lookup (inkl. Kinder)
    @Published var slots: [UUID?] = []                    // Grid-Slots (je Subview = eine Kachel (2×2) oder Platzhalter)

    // MARK: Grid / Layout
    var columns: Int = 20
    let rows: Int = 75
    private var totalSlots: Int { columns * rows }

    // MARK: Drag State
    @Published var isReordering: Bool = false
    @Published var draggingID: UUID?
    @Published var ghostIndex: Int?
    @Published var ghostSpan: Int = 1
    @Published var dropTransactionActive: Bool = false
    private var dragSourceIndex: Int?
    private var dragSourceSpan: Int = 1          // groß standard
    @Published var previewSlots: [UUID?]? = nil     // temporäres Reflow bei Hover
    @Published var hoverContainerID: UUID? = nil    // wenn Maus über Container (für DnD-Zielerkennung)
    @Published var hoverContainerSlot: Int? = nil
    @Published var childSlots: [UUID: [UUID: Int]] = [:]

    // Intern
    private var slotsBeforeDrag: [UUID?]? = nil
    private var persistTask: Task<Void, Never>?
    private var persistSlotsTask: Task<Void, Never>?
    private var slotsSaveDebounce: Task<Void, Never>?

    // MARK: Convenience
    var displaySlots: [UUID?] { previewSlots ?? slots }

    // MARK: Init
    init() {
        reloadTilesFromDisk()
        loadSlotsFromDisk()
        if slots.isEmpty {
            slots = Array(repeating: nil, count: totalSlots)
        }
        reindexFromTiles()
    }

    // MARK: Paths
    private let persistURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir  = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "WindowDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tiles.json")
    }()

    private let slotsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir  = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "WindowDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("slots.json")
    }()

    // MARK: Persistence
    
    @MainActor
    func saveTiles() {
        let snapshot = Array(itemsByID.values)
        let url = persistURL
        persistTask?.cancel()
        persistTask = Task(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                Swift.print("💾 tiles saved (\(snapshot.count))")
            } catch {
                log.error("write tiles failed: \(String(describing: error))")
            }
        }
    }

    func saveSlots() {
        let snapshot = slots
        let url = slotsURL
        persistSlotsTask?.cancel()
        persistSlotsTask = Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                Swift.print("💾 slots saved (\(snapshot.count))")
            } catch {
                log.error("write slots failed: \(String(describing: error))")
            }
        }
    }

    @MainActor
    func reloadTilesFromDisk() {
        guard FileManager.default.fileExists(atPath: persistURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistURL)
            let all = try JSONDecoder().decode([TileItem].self, from: data)

            var map: [UUID: TileItem] = [:]
            for t in all { map[t.id] = t }
            itemsByID = map

            // Top-Level Schätzung: nur Items behalten, deren Kinder es auch gibt
            let childSet: Set<UUID> = Set(all.flatMap { $0.children ?? [] })
            tiles = all.filter { !childSet.contains($0.id) }

        } catch {
            log.error("load tiles failed: \(error)")
            itemsByID = [:]
            tiles = [] // ⬅️ Crash verhindern
        }
    }

    func loadSlotsFromDisk() {
        do {
            guard FileManager.default.fileExists(atPath: slotsURL.path) else { return }
            let data = try Data(contentsOf: slotsURL)
            let decoded = try JSONDecoder().decode([UUID?].self, from: data)
            slots = decoded
        } catch {
            log.error("load slots failed: \(String(describing: error))")
        }
    }

    private func reindexFromTiles() {
        // itemsByID ist führend – stelle sicher, dass tiles konsistent sind.
        if tiles.isEmpty {
            // wenn nichts da → initial leer lassen
        }
    }

    func syncBack() {
        saveTiles()
    }

    // MARK: Öffnen / Finder zeigen / Größe setzen / Entfernen
    func open(_ id: UUID) {
        guard let t = itemsByID[id] else { return }
        if let url = t.fileURL {
            NSWorkspace.shared.open(url)
        } else if let bid = t.bundleID, let appURL = AppResolver.shared.url(forBundleID: bid) {
            NSWorkspace.shared.open(appURL)
        }
    }

    func revealInFinder(_ id: UUID) {
        guard let t = itemsByID[id], let url = t.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func setSize(_ id: UUID, _ new: TileSize) {
        guard var item = itemsByID[id] else { return }

        if item.size == .large && new == .small {
            // (unverändert) Groß -> Klein: Container-Hülle bauen ...
            let child = TileItem(
                id: UUID(),
                title: item.title,
                bundleID: item.bundleID,
                fileURL: item.fileURL,
                size: .small
            )
            itemsByID[child.id] = child
            item.children = [child.id]
            item.size = .large
            itemsByID[item.id] = item
            saveTiles()
            return
        }

        if item.size == .large && new == .large {
            return
        }

        if item.size == .small && new == .large {
            // ✅ Neu: kleines Kind darf groß werden → Promotion ins Main-Grid
            promoteChildToTopLevel(childID: id)
            return
        }
    }
    
    @MainActor
    func promoteChildToTopLevel(childID: UUID) {
        guard var child = itemsByID[childID] else { return }

        // 1) Kein Parent? -> direkt hochstufen & irgendwo frei platzieren
        guard let parentID = containerHolding(childID: childID) else {
            child.size = .large
            itemsByID[childID] = child
            if !tiles.contains(where: { $0.id == childID }) { tiles.append(child) }
            let dst = nearestFreeBlock(around: 0, span: child.size.span, columns: columns)
            placeTopLevel(id: childID, at: dst, span: child.size.span)
            saveTiles(); saveSlots()
            return
        }

        // 2) Prüfen, ob das Kind das EINZIGE im Container ist
        let parent = itemsByID[parentID]

        // 1) valide Kinder aus children (Zombie-IDs rausfiltern)
        let validChildren = Set((parent?.children ?? []).filter { itemsByID[$0] != nil })

        // 2) Kinder, die über Slot-Mapping im Container liegen
        let mappedChildren = Set(childSlots[parentID]?.keys.map { $0 } ?? [])

        // 3) Vereinigung bildet den „echten“ Inhalt des Containers
        let allChildren = validChildren.union(mappedChildren)

        // 4) ist es wirklich das einzige?
        let isOnlyChild = (allChildren.count == 1) && allChildren.contains(childID)

        // 3) Mapping bereinigen (egal in welchem Fall)
        childSlots[parentID]?[childID] = nil
        if childSlots[parentID]?.isEmpty == true { childSlots[parentID] = nil }

        if isOnlyChild {
            // --- 🧹 Container REPLACEN durch das Kind ---
            // a) Lead-Slot des Containers ermitteln
            let containerLead = slots.firstIndex(where: { $0 == parentID })

            // b) Container sauber entfernen
            itemsByID.removeValue(forKey: parentID)
            if let idx = tiles.firstIndex(where: { $0.id == parentID }) {
                tiles.remove(at: idx)
            }

            // c) Kind groß machen & als Top-Level führen
            child.size = .large
            itemsByID[childID] = child
            if !tiles.contains(where: { $0.id == childID }) { tiles.append(child) }

            // d) Exakt an Stelle des Containers einsetzen (oder Fallback)
            if let lead = containerLead {
                // alle bisherigen Vorkommen des Kinds entfernen (defensiv)
                for i in slots.indices where slots[i] == childID { slots[i] = nil }
                // Bereich für den neuen Block freimachen (nur Lead wird gespeichert)
                ensureCapacity(upto: lead + child.size.span)
                for off in 0..<child.size.span {
                    if lead + off < slots.count { slots[lead + off] = nil }
                }
                slots[lead] = childID
            } else {
                let dst = nearestFreeBlock(around: 0, span: child.size.span, columns: columns)
                placeTopLevel(id: childID, at: dst, span: child.size.span)
            }

            saveTiles()
            saveSlots()
            return
        } else {
            // --- altes Verhalten: Kind wird groß & in der Nähe platziert ---
            // Parent-Kindliste updaten
            if var p = parent {
                p.children = p.children?.filter { allChildren.contains($0) }
                itemsByID[parentID] = p
            }

            child.size = .large
            itemsByID[childID] = child
            if !tiles.contains(where: { $0.id == childID }) { tiles.append(child) }

            let around = slots.firstIndex(where: { $0 == parentID }) ?? 0
            let dst = nearestFreeBlock(around: around, span: child.size.span, columns: columns)
            placeTopLevel(id: childID, at: dst, span: child.size.span)

            saveTiles()
            saveSlots()
            return
        }
    }
    
    @MainActor
    private func placeTopLevel(id: UUID, at dst: Int, span: Int) {
        // alle bisherigen Vorkommen der ID entfernen (defensiv)
        for i in slots.indices where slots[i] == id { slots[i] = nil }

        ensureCapacity(upto: dst + span)
        // Block (nur Lead in unserer Speicherung, aber Bereich vorher frei machen)
        for i in 0..<span { if dst + i < slots.count { slots[dst + i] = nil } }

        slots[dst] = id
    }
    
    private func nearestFreeBlock(around: Int, span: Int, columns: Int) -> Int {
        let span = max(1, span)
        let cols = max(1, columns)

        let startRow = max(0, around / cols)
        let startCol = max(0, around % cols)

        @inline(__always)
        func blockFits(row: Int, col: Int) -> Bool {
            guard row >= 0, col >= 0, col + span <= cols else { return false }
            let lead = row * cols + col
            ensureCapacity(upto: lead + span)
            return !(lead < slots.count && slots[lead] != nil)
        }

        let maxRadius = max(8, rows)
        for r in 0...maxRadius {
            let rmin = max(0, startRow - r)
            let rmax = startRow + r
            let cminRaw = max(0, startCol - r)
            let cmaxRaw = startCol + r

            @inline(__always)
            func align(_ c: Int) -> Int { span > 1 ? (c / span) * span : c }

            // an Grid & Span-Gitter anpassen
            var cmin = min(max(0, align(cminRaw)), cols - 1)
            var cmax = min(max(0, align(cmaxRaw)), cols - 1)
            if cmin > cmax { swap(&cmin, &cmax) }                // 🔐 robust: niemals invertierter Bereich

            // 1) obere & untere Ring-Zeile
            for row in Set([rmin, rmax]) {
                var col = cmin
                while col <= cmax {
                    if blockFits(row: row, col: col) { return row * cols + col }
                    col += (span > 1 ? span : 1)
                }
            }

            // 2) linke & rechte Spalte (nur falls wirkliche Innenzeilen existieren)
            if rmin + 1 <= rmax - 1 {                            // 🔐 guard gegen leere Range
                var colL = cmin
                var colR = cmax
                while colL <= cmax || colR >= cmin {
                    for row in (rmin + 1)...(rmax - 1) {         // jetzt geschlossenes Intervall
                        if colL <= cmax, blockFits(row: row, col: colL) { return row * cols + colL }
                        if colR >= cmin, blockFits(row: row, col: colR) { return row * cols + colR }
                    }
                    colL += (span > 1 ? span : 1)
                    colR -= (span > 1 ? span : 1)
                }
            }
        }

        // Fallback: ans Ende anhängen
        let tailRow = max(0, (slots.count + cols - 1) / cols)
        return tailRow * cols
    }

    @MainActor
    func remove(_ id: UUID) {
        // 1) Falls das Tile Kind eines Containers ist → dort austragen
        if let parent = containerHolding(childID: id) {
            if var cont = itemsByID[parent] {
                if var kids = cont.children {
                    kids.removeAll { $0 == id }
                    cont.children = kids
                }
                itemsByID[parent] = cont
            }
            childSlots[parent]?[id] = nil
            if childSlots[parent]?.isEmpty == true { childSlots[parent] = nil }
            // Kind selbst aus dem Dictionary löschen
            itemsByID.removeValue(forKey: id)
            saveTiles()
            return
        }

        // 2) Top-Level: Slot freimachen
        if let idx = slots.firstIndex(where: { $0 == id }) {
            slots[idx] = nil
        }

        // 3) Wenn es ein Container war → seine Kinder ebenfalls entfernen
        if let item = itemsByID[id], item.isContainer {
            for cid in item.children ?? [] {
                itemsByID.removeValue(forKey: cid)
            }
        }

        // 4) Das Tile selbst löschen
        itemsByID.removeValue(forKey: id)
        saveTiles()
    }
    
    @MainActor
    func clearAll() {
        // Alles zurücksetzen
        itemsByID.removeAll()
        slots.removeAll()

        // Laufende/temporäre Zustände
        draggingID = nil
        ghostIndex = nil
        ghostSpan  = 1
        isReordering = false
        previewSlots = nil   // falls du so ein Feld hast; sonst Zeile löschen

        saveSlots()          // wenn vorhanden: aktuellen (leeren) Stand persistieren
    }
    
    @MainActor
    func logAllTiles() {
        Swift.print("📋 Aktuelle Tiles im Store:")

        // Nur belegte Slots in der Reihenfolge des Grids (ohne Duplikate)
        var seen = Set<UUID>()
        let topLevelIDs: [UUID] = slots.compactMap { $0 }.filter { seen.insert($0).inserted }

        if topLevelIDs.isEmpty { Swift.print("   (leer)"); return }

        for id in topLevelIDs {
            guard let tile = itemsByID[id] else {
                Swift.print("   ⚠️ Slot verweist auf unbekannte ID \(id)")
                continue
            }

            if tile.isContainer {
                let kids = tile.children ?? []
                Swift.print("🗂 Container \(tile.id) enthält \(kids.count) Kinder")
                for cid in kids {
                    if let child = itemsByID[cid] {
                        Swift.print("   🔹 Child \(child.id) → \(child.bundleID ?? "nil") @ \(child.fileURL?.path ?? "nil")")
                    } else {
                        Swift.print("   🔸 Child-ID \(cid) nicht gefunden!")
                    }
                }
            } else {
                Swift.print("🔹 Tile \(tile.id) → \(tile.bundleID ?? "nil") @ \(tile.fileURL?.path ?? "nil")")
            }
        }
    }

    // MARK: Container-Hilfen
    func isContainer(_ id: UUID) -> Bool { itemsByID[id]?.isContainer == true }

    /// Liefert die ID des Containers, der `childID` enthält – oder nil.
    @MainActor
    func containerHolding(childID: UUID) -> UUID? {
        for (pid, t) in itemsByID {
            if let kids = t.children, !kids.isEmpty, kids.contains(childID) {
                return pid
            }
        }
        return nil
    }

    /// Ein Container darf max. 4 Kinder enthalten.
    @MainActor
    func ensureContainerCapacity(_ containerID: UUID) -> Bool {
        guard let t = itemsByID[containerID], t.isContainer else { return false }
        return (t.children?.count ?? 0) < 4
    }

    @MainActor
    func insertSmallIntoContainer(containerID: UUID, item new: TileItem, targetSlot: Int?) {
        guard var container = itemsByID[containerID], container.isContainer else { return }
        guard ensureContainerCapacity(containerID) else { return }
        var child = new
        child.size = .small
        removeChildEverywhere(child.id)

        itemsByID[child.id] = child
        if container.children == nil { container.children = [] }
        if !(container.children!.contains(child.id)) { container.children!.append(child.id) }
        itemsByID[containerID] = container

        // zielgerichtet platzieren (nimmt freien Slot falls kollidiert)
        placeChild(child.id, into: containerID, at: clampMiniSlot(targetSlot), preferExact: false)
        saveTiles()
    }

    func moveLargeIntoContainer(containerID: UUID, largeID: UUID, targetSlot: Int?) {
        guard let large = itemsByID[largeID] else { return }
        removeChildEverywhere(largeID)
        insertSmallIntoContainer(containerID: containerID, item: large, targetSlot: targetSlot)
    }

    // MARK: DnD Lifecycle
    @MainActor func beginInternalDrag(id: UUID, span: Int) {
        draggingID = id
        ghostSpan = max(1, span)
        dragSourceIndex = slots.firstIndex(where: { $0 == id })
        dragSourceSpan  = max(1, span)
        isReordering = true
    }

    @MainActor func beginExternalDrag() {
        draggingID = nil
        ghostSpan = TileSize.large.span
        dragSourceIndex = nil
        dragSourceSpan  = TileSize.large.span 
        isReordering = true
    }

    func cancelDrag() {
        if dropTransactionActive { return }
        isReordering = false
        ghostIndex = nil
        draggingID = nil
        dragSourceIndex = nil
    }

    func updateGhost(to slot: Int) {
        ghostIndex = max(0, min(slot, slots.count))
    }

    func ensureSlots(upTo idx: Int) {
        if idx >= slots.count {
            slots.append(contentsOf: Array(repeating: nil, count: idx - slots.count + 1))
        }
    }

    private func nextFreeSlot(in arr: [UUID?], from start: Int) -> Int {
        var i = max(0, start)
        while i < arr.count {
            if arr[i] == nil { return i }
            i += 1
        }
        return i
    }

    // Live-Vorschau (Top-Level Reflow); Container bleiben stehen (werden nicht „aufgebrochen“)
    /*
    func previewReflow(to rawSlot: Int) {
        // defensive bounds
        guard !slots.isEmpty else { return }

        let slot = max(0, min(rawSlot, slots.count - 1))
        var tmp = slots

        // Ghost vorbereiten
        if slot >= tmp.count { tmp.append(nil) }

        // Platz frei schieben, aber ohne Out-of-Bounds
        let free = nextFreeSlot(in: tmp, from: slot)
        if free >= tmp.count {
            tmp.append(contentsOf: Array(repeating: nil, count: free - tmp.count + 1))
        }

        for i in stride(from: free, to: slot, by: -1) {
            guard i - 1 >= 0, i < tmp.count else { continue }
            tmp[i] = tmp[i - 1]
        }

        if slot < tmp.count { tmp[slot] = nil }
        previewSlots = tmp
        ghostIndex = slot
    }
    */
    
    @MainActor func previewReflow(to idx: Int) {
        ghostIndex = max(0, idx)
        isReordering = true
    }

    // MARK: Drop-Aktionen (zentral)
    @MainActor func applyDropIntoContainer(containerID: UUID, identifier: String, targetSlot: Int?) {
        guard var container = itemsByID[containerID], container.isContainer else { return }
        guard ensureContainerCapacity(containerID) else { return }
        let slot = clampMiniSlot(targetSlot)

        // A) interner Move?
        if let u = UUID(uuidString: identifier), let item = itemsByID[u] {
            if u == containerID || item.isContainer { return } // keine Container-in-Container

            if item.size == .large {
                // Top-Level groß → als kleines Kind in Container
                moveLargeIntoContainer(containerID: containerID, largeID: u, targetSlot: slot)
                // Slots freiräumen
                for i in slots.indices where slots[i] == u { slots[i] = nil }
                saveSlots()
                saveTiles()
                return
            } else {
                removeChildEverywhere(u)

                if container.children == nil { container.children = [] }
                if !(container.children!.contains(u)) { container.children!.append(u) }
                itemsByID[containerID] = container

                placeChild(u, into: containerID, at: slot, preferExact: true)
                saveTiles()
                return 
            }
        }

        // B) externer Drop → neues kleines Child erzeugen und platzieren
        let r = resolveDropIdentifier(identifier.trimmingCharacters(in: .whitespacesAndNewlines))
        let child = TileItem(
            id: UUID(), 
            title: {
                if !r.title.isEmpty { return r.title }
                if let bid = r.bundleID,
                   let name = AppScanner.shared.apps.first(where: { $0.bundleID == bid })?.name {
                    return name
                }
                if let name = r.fileURL?.deletingPathExtension().lastPathComponent { return name }
                return "Unbekannt"
            }(),
            bundleID: r.bundleID,
            fileURL: r.fileURL,
            size: .small,
            children: nil
        )
        itemsByID[child.id] = child
        if container.children == nil { container.children = [] }
        container.children!.append(child.id)
        itemsByID[containerID] = container

        placeChild(child.id, into: containerID, at: slot, preferExact: true)   // 👈 zielgerichtet
        saveTiles()
    }
    
    @MainActor func applyDropPayload(identifier: String, suggestedSlot: Int) {
        if suggestedSlot < slots.count, let targetID = slots[suggestedSlot], let target = itemsByID[targetID], target.isContainer {
            return
        }

        // 1) „intern vs. extern“ ausschließlich am Payload entscheiden
        let movingExistingID: UUID? = {
            if let u = UUID(uuidString: identifier), itemsByID[u] != nil { return u }
            return nil
        }()
        let isInternalMove = (movingExistingID != nil)

        let id: UUID = {
            if let u = movingExistingID { return u }
            return resolveOrCreateItem(for: identifier, allowReuse: false)
        }()

        // 👉👉 NEU: Falls es ein internes kleines Child aus einem Container ist,
        //           aus dem alten Container entfernen und auf .large hochstufen,
        //           damit es als Top-Level-Kachel ins Grid kommt.
        if isInternalMove,
           let u = movingExistingID,
           let parent = containerHolding(childID: u) {

            // Slot-Mapping und Parent sauber bereinigen
            childSlots[parent]?[u] = nil
            if childSlots[parent]?.isEmpty == true { childSlots[parent] = nil }

            if var cont = itemsByID[parent] {
                cont.children?.removeAll { $0 == u }
                itemsByID[parent] = cont
            }

            // Größe NICHT ändern – falls irgendwer vorher .large gesetzt hatte, zurück auf .small absichern
            if var item = itemsByID[u], item.size != .small {
                item.size = .small
                itemsByID[u] = item
            }

            // Als Top-Level führen, damit es im Grid erscheint
            if let item = itemsByID[u], !tiles.contains(where: { $0.id == u }) {
                tiles.append(item)
            }

            saveTiles()
        }

        // 2) Span (nach evtl. Hochstufung neu lesen)
        let span = max(1, itemsByID[id]?.size.span ?? TileSize.large.span)

        // 3) Kapazität
        ensureCapacity(upto: suggestedSlot + span)

        // 4) Alle bisherigen Vorkommen der ID kompromisslos leeren
        for i in slots.indices where slots[i] == id { slots[i] = nil }

        // 5) Zielbereich freiräumen (defensiv)
        ensureCapacity(upto: suggestedSlot + span)
        for i in 0..<span { slots[suggestedSlot + i] = nil }

        // 6) Lead-Slot setzen
        slots[suggestedSlot] = id

        // 7) State zurücksetzen
        ghostIndex = nil
        draggingID = nil
        dragSourceIndex = nil
        isReordering = false
    }
    
    @MainActor
    private func moveSmallChild(_ childID: UUID, to newContainerID: UUID) {
        guard var target = itemsByID[newContainerID], target.isContainer else { return }
        // aus altem Parent raus
        if let parent = containerHolding(childID: childID), var old = itemsByID[parent] {
            old.children?.removeAll { $0 == childID }
            itemsByID[parent] = old
        }
        // in Ziel rein
        guard ensureContainerCapacity(newContainerID) else { return }
        if target.children == nil { target.children = [] }
        if !(target.children!.contains(childID)) {
            target.children!.append(childID)
        }
        itemsByID[newContainerID] = target
        saveTiles()
    }
    
    @MainActor private func resolveOrCreateItem(for identifier: String, allowReuse: Bool) -> UUID {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        // 0) UUID direkt?
        if let u = UUID(uuidString: raw), let existing = itemsByID[u] {
            return allowReuse ? u : duplicateItem(from: existing)
        }

        // 1) Identifier in App-/Datei-Info auflösen
        let r = resolveDropIdentifier(raw)

        // 2) Wiederverwendung nur, wenn explizit erlaubt
        if allowReuse {
            if let bid = r.bundleID,
               let hit = itemsByID.values.first(where: { $0.bundleID == bid && !($0.isContainer) }) {
                return hit.id
            }
            if let url = r.fileURL,
               let hit = itemsByID.values.first(where: { $0.fileURL?.path == url.path && !($0.isContainer) }) {
                return hit.id
            }
        }

        // 3) Immer NEU (Top-Level groß)
        let new = makeLargeTile(from: ResolvedApp(title: r.title, bundleID: r.bundleID, fileURL: r.fileURL))
        itemsByID[new.id] = new
        if !tiles.contains(where: { $0.id == new.id }) { tiles.append(new) }
        saveTiles()
        return new.id
    }
    
    @MainActor private func duplicateItem(from src: TileItem) -> UUID {
        // Duplikat ist immer ein eigenständiges Top-Level-Item (groß)
        let copy = TileItem(id: UUID(), title: src.title, bundleID: src.bundleID, fileURL: src.fileURL, size: .large, children: nil)
        itemsByID[copy.id] = copy
        if !tiles.contains(where: { $0.id == copy.id }) { tiles.append(copy) }
        saveTiles()
        return copy.id
    }

    @MainActor
    func finishDropCleanup() {
        dropTransactionActive = false
        isReordering = false
        ghostIndex = nil
        draggingID = nil
        dragSourceIndex = nil
        hoverContainerID = nil
        hoverContainerSlot = nil
    }
    
    // Freien Mini-Slot (0..3) in einem Container finden (wenn belegt, nimm nächsten freien)
    @MainActor
    private func firstFreeMiniSlot(in containerID: UUID, preferred: Int?) -> Int {
        let want = clampMiniSlot(preferred)
        let used = Set(childSlots[containerID]?.values.map { $0 } ?? [])
        if !used.contains(want) { return want }
        for s in 0...3 where !used.contains(s) { return s }
        return want
    }

    /// Entfernt ein Kind wirklich überall:
    /// - aus `children` ALLER Container
    /// - aus `childSlots` ALLER Container
    @MainActor
    private func removeChildEverywhere(_ childID: UUID) {
        for (pid, var t) in itemsByID where t.isContainer {
            let oldCount = t.children?.count ?? 0
            t.children?.removeAll { $0 == childID }
            if (t.children?.count ?? 0) != oldCount {
                itemsByID[pid] = t
            }
            if childSlots[pid]?[childID] != nil {
                childSlots[pid]?[childID] = nil
                if childSlots[pid]?.isEmpty == true { childSlots[pid] = nil }
            }
        }
    }
    
    @MainActor
    func moveID(_ id: UUID, to rawSlot: Int) {
        // entferne alte Position, füge an Ziel-Index ein (dein bestehender Code ist ok,
        // wichtig ist nur, dass es _wirklich_ verschiebt und Speicherslots updated)
        // ...
    }

    @MainActor
    func insertExternal(_ new: TileItem, at rawSlot: Int) {
        // dein bestehender Insert-Code; wichtig: KEIN Label „new:“ im Aufruf
        // ...
    }

    @MainActor
    func moveInternalLarge(id: UUID, to rawSlot: Int) {
        // Muss existieren und „groß“ sein (Top-Level)
        guard let item = itemsByID[id], item.size == .large else {
            Swift.print("❌ moveInternalLarge: item \(id) fehlt oder ist nicht .large")
            return
        }

        let before = slots
        let dst = max(0, min(rawSlot, max(0, slots.count)))

        // Alle Vorkommen entfernen (defensiv)
        if !slots.isEmpty {
            for i in slots.indices where slots[i] == id { slots[i] = nil }
        }

        // Zielslot sicherstellen
        ensureSlots(upTo: dst)

        if slots[dst] == nil {
            slots[dst] = id
        } else {
            // rechts freischieben
            if slots.last != nil { slots.append(nil) }
            var i = slots.count - 1
            while i > dst { slots[i] = slots[i - 1]; i -= 1 }
            slots[dst] = id
        }

        // Vorschau/Drag abschalten, damit nichts „verdeckt“
        previewSlots = nil
        ghostIndex   = nil
        isReordering = false
        draggingID   = nil

        Swift.print("✅ moveInternalLarge: \(id) → slot \(dst)")
        Swift.print("   slots(before): \(before)")
        Swift.print("   slots(after):  \(slots)")

        saveSlots()
    }

    @MainActor
    func commitExternalInsert(_ new: TileItem, at rawSlot: Int) {
        let before = slots

        itemsByID[new.id] = new
        if !tiles.contains(where: { $0.id == new.id }) { tiles.append(new) }

        let dst = max(0, min(rawSlot, max(0, slots.count)))
        ensureSlots(upTo: dst)

        if slots[dst] == nil {
            slots[dst] = new.id
        } else {
            if slots.last != nil { slots.append(nil) }
            var i = slots.count - 1
            while i > dst { slots[i] = slots[i - 1]; i -= 1 }
            slots[dst] = new.id
        }

        previewSlots = nil
        ghostIndex   = nil
        isReordering = false
        draggingID   = nil

        Swift.print("✅ commitExternalInsert: \(new.id) → slot \(dst)")
        Swift.print("   slots(before): \(before)")
        Swift.print("   slots(after):  \(slots)")

        saveTiles()
        saveSlots()
    }

    // MARK: Factory / Resolver
    struct ResolvedApp {
        var title: String
        var bundleID: String?
        var fileURL: URL?
    }
    
    private func makeTile(from r: ResolvedApp) -> TileItem {
        TileItem(
            id: UUID(),
            title: r.title,
            bundleID: r.bundleID,
            fileURL: r.fileURL,
            size: .small,
            children: nil    // KEIN Container per default
        )
    }

    private func makeLargeTile(from r: ResolvedApp) -> TileItem {
        let computedTitle: String = {
            if !r.title.isEmpty { return r.title }
            if let bid = r.bundleID,
               let name = AppScanner.shared.apps.first(where: { $0.bundleID == bid })?.name {
                return name
            }
            if let name = r.fileURL?.deletingPathExtension().lastPathComponent {
                return name
            }
            return "Unbekannt"
        }()

        return TileItem(
            id: UUID(),
            title: computedTitle,      // <— Fallback wirklich nutzen
            bundleID: r.bundleID,
            fileURL: r.fileURL,
            size: .large,              // große Vollkachel
            children: nil              // KEIN Container
        )
    }

    private func resolveDropIdentifier(_ raw: String) -> (title: String, bundleID: String?, fileURL: URL?) {
        var title = raw
        var bid: String? = nil
        var url: URL? = nil

        // A) Vollständiger Pfad?  (/Applications/Calculator.app)
        if raw.hasPrefix("/") {
            let u = URL(fileURLWithPath: raw)
            url = u
            bid = AppResolver.shared.bundleID(forAppURL: u)              // URL -> String?
            title = u.deletingPathExtension().lastPathComponent
            return (title, bid, url)
        }

        // B) Eindeutige Bundle-ID (foo.bar.App)
        if raw.contains(".") {
            let b = raw
            bid = b
            if let u = AppResolver.shared.url(forBundleID: b) {          // String -> URL?
                url = u
                title = u.deletingPathExtension().lastPathComponent
            }
            return (title, bid, url)
        }

        // C) App-Name -> versuche Auflösung
        if let u = AppResolver.shared.findAppURL(byName: raw) {          // Name -> URL?
            url = u
            bid = AppResolver.shared.bundleID(forAppURL: u)              // URL -> String?
            title = u.deletingPathExtension().lastPathComponent
            return (title, bid, url)
        }

        // Fallback
        return (title, nil, nil)
    }
    
    private func clampMiniSlot(_ i: Int?) -> Int {
        guard let i else { return 0 }
        return min(max(0, i), 3) // 0..3
    }

    /// Reorder children so that `childID` appears at `slot` (0..3) in reading order.
    @MainActor
    private func placeChild(_ childID: UUID, into containerID: UUID, at slot: Int, preferExact: Bool) {
        guard let cont = itemsByID[containerID], cont.isContainer else { return }

        // Kind sicher im Container halten (keine Duplikate)
        if var kids = cont.children {
            if !kids.contains(childID) {
                kids.append(childID)
                var c = cont; c.children = kids
                itemsByID[containerID] = c
            }
        } else {
            var c = cont; c.children = [childID]
            itemsByID[containerID] = c
        }

        // Mapping vorbereiten
        if childSlots[containerID] == nil { childSlots[containerID] = [:] }

        let desired = clampMiniSlot(slot)
        let target: Int = preferExact
            ? desired
            : firstFreeMiniSlot(in: containerID, preferred: desired)

        // schon dort? fertig
        if childSlots[containerID]?[childID] == target {
            saveTiles(); return
        }

        if preferExact {
            // EXAKTEN Slot erzwingen → ggf. sauberer Swap
            let previousOfChild = childSlots[containerID]?[childID]
            let occupant = childSlots[containerID]?.first(where: { $0.value == target })?.key

            // setze das Kind auf den Ziel-Slot
            childSlots[containerID]?[childID] = target

            if let occ = occupant, occ != childID {
                if let old = previousOfChild {
                    // klassischer Swap
                    childSlots[containerID]?[occ] = old
                } else {
                    // Kind hatte noch keinen Slot → Occupant in wirklich freien Slot verschieben
                    let free = (0...3).first { s in
                        s != target && childSlots[containerID]?.contains(where: { $0.value == s }) != true
                    } ?? firstFreeMiniSlot(in: containerID, preferred: 0)
                    childSlots[containerID]?[occ] = free
                }
            }
        } else {
            // „nimm freien Slot“-Variante wie bisher
            // Falls der target (freier) trotzdem besetzt wäre (theoretisch), nutze Swap-Logik
            if let occ = childSlots[containerID]?.first(where: { $0.value == target })?.key, occ != childID {
                let old = childSlots[containerID]?[childID]
                childSlots[containerID]?[childID] = target
                if let old { childSlots[containerID]?[occ] = old }
            } else {
                childSlots[containerID]?[childID] = target
            }
        }

        saveTiles()
    }
}

extension TileStore {
    @MainActor func ensureCapacity(upto n: Int) {
        if slots.count < n {
            slots.append(contentsOf: Array(repeating: nil, count: n - slots.count))
        }
    }
    
    /// Berechnet den Index im Grid für einen Drop-Punkt.
    /// Achtung: hier NICHT auf displaySlots gehen, sondern auf die Slots-Liste im Store.
    func indexFor(point p: CGPoint, columns: Int, tileSize: CGFloat, spacing: CGFloat, inset: CGSize) -> Int {
        let cell = tileSize + spacing
        let col = max(0, min(columns - 1, Int(floor((p.x - inset.width) / cell))))
        let row = max(0, Int(floor((p.y - inset.height) / cell)))
        return max(0, row * columns + col)
    }
    
    func usedRows(columns: Int, minRows: Int = 0) -> Int {
        guard columns > 0 else { return max(minRows, 0) }
        // bis zur letzten belegten Zelle zählen
        if let last = displaySlots.lastIndex(where: { $0 != nil }) {
            let cells = last + 1
            let rows  = (cells + columns - 1) / columns
            return min(max(rows, minRows), 100)
        } else {
            return max(minRows, 0)
        }
    }

    func contentHeight(columns: Int, tileSize: CGFloat, spacing: CGFloat, inset: CGSize, minRows: Int = 0) -> CGFloat {
        let rows = usedRows(columns: columns, minRows: minRows)
        guard rows > 0 else { return inset.height * 2 }
        // rows * tile + (rows - 1) * spacing + vertikale Insets
        return CGFloat(rows) * tileSize + CGFloat(max(0, rows - 1)) * spacing + inset.height * 2
    }
    
    /// Liefert nur so viele Slots, wie tatsächlich gebraucht werden:
    /// bis zum letzten belegten Index (+ kleiner Puffer).
    var effectiveDisplaySlots: [UUID?] { slots }
    
    @MainActor
    func occupyingTopLevelID(at raw: Int, columns: Int) -> UUID? {
        guard !slots.isEmpty, raw >= 0 else { return nil }
        let rows = max(1, (slots.count + columns - 1) / columns)
        let tgtRow = raw / max(1, columns)
        let tgtCol = raw % max(1, columns)

        // Scanne nur Lead-Slots (non-nil)
        for i in 0..<min(slots.count, rows * columns) {
            guard let lead = slots[i] else { continue }
            let span = max(1, itemsByID[lead]?.size.span ?? 1)
            let r0 = i / columns
            let c0 = i % columns
            let r1 = r0 + span - 1
            let c1 = c0 + span - 1
            if tgtRow >= r0, tgtRow <= r1, tgtCol >= c0, tgtCol <= c1 {
                return lead
            }
        }
        return nil
    }
}

extension TileStore.ResolvedApp {
    init(title: String? = nil, bundleID: String?, fileURL: URL?) {
        self.title = title ?? "Unbekannt"
        self.bundleID = bundleID
        self.fileURL = fileURL
    }
}
