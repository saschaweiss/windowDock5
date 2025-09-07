// UI/Common/ReorderableGrid.swift
// Stabiles Reorder-Grid (SwiftUI-only) mit:
//  - Binding-Daten (jitter-frei)
//  - Live-Slot + Ghost (gezogene Kachel folgt Maus; Kachel aus Grid ausgeblendet)
//  - Debounce: Move nur, wenn Ziel-ID wechselt
//  - Idempotente Moves aus der Arbeitskopie
//  - Moves ohne Implicit Animation; nur Slot/Ghost weich
// macOS 14+

import SwiftUI
import UniformTypeIdentifiers
import AppKit

public struct ReorderableGrid<T: Identifiable & Hashable, V: View>: View {
    @Binding private var items: [T]

    // Arbeitskopie, die während des Drags gerendert wird
    @State private var working: [T]? = nil

    private let columns: [GridItem]
    private let dragUTI: UTType
    private let content: (T) -> V

    // Drag-State
    @State private var dragItem: T?
    @State private var targetedID: T.ID? = nil       // vor WELCHEM Item liegt der Slot?
    @State private var lastAppliedTargetID: T.ID?    // zuletzt angewendetes Ziel -> Debounce
    @State private var targetAtEnd: Bool = false

    // Ghost (Maus-Folge)
    @State private var screenPoint: CGPoint? = nil
    @State private var localPoint: CGPoint? = nil
    @State private var mouseMonitorGlobal: Any? = nil
    @State private var mouseMonitorLocal: Any? = nil

    // Externer Drag-Status (z. B. um anderen UI-Bereich zu „muten“)
    private let draggingExternal: Binding<Bool>?

    // Slot-Optik
    private let slotHeight: CGFloat = 68
    private let slotCorner: CGFloat = 8

    public init(
        _ items: Binding<[T]>,
        columns: [GridItem],
        dragUTI: UTType = .text,
        dragging: Binding<Bool>? = nil,
        @ViewBuilder content: @escaping (T) -> V
    ) {
        self._items = items
        self.columns = columns
        self.dragUTI = dragUTI
        self.draggingExternal = dragging
        self.content = content
    }

    // Darstellung ohne die gezogene Kachel
    private var display: [T] {
        let base = working ?? items
        guard let drag = dragItem else { return base }
        return base.filter { $0 != drag }
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 12) {
                // Grid
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(display, id: \.id) { item in
                        // Slot vor Ziel
                        if dragItem != nil, targetAtEnd == false, equals(targetedID, item.id) {
                            SlotView(height: slotHeight, corner: slotCorner)
                                .transition(.opacity.combined(with: .scale))
                        }

                        content(item)
                            .onDrag {
                                beginDrag(with: item)
                                return provider(for: item)
                            }
                            .onDrop(of: [dragUTI.identifier],
                                    delegate: ItemDropDelegate(
                                        targetID: item.id,
                                        items: $items,
                                        working: $working,
                                        dragItem: $dragItem,
                                        targetedID: $targetedID,
                                        lastAppliedTargetID: $lastAppliedTargetID,
                                        targetAtEnd: $targetAtEnd,
                                        endDrag: endDrag,
                                        applyMove: applyMove
                                    )
                            )
                    }
                }
                // Container-Drop: commit bei Drop „zwischen den Zellen“
                .onDrop(of: [dragUTI.identifier],
                        delegate: ContainerDropDelegate(
                            items: $items,
                            working: $working,
                            dragItem: $dragItem,
                            targetedID: $targetedID,
                            lastAppliedTargetID: $lastAppliedTargetID,
                            targetAtEnd: $targetAtEnd,
                            endDrag: endDrag
                        )
                )

                // Tail-Slot am Ende
                if dragItem != nil {
                    SlotView(height: slotHeight, corner: slotCorner, dashed: true)
                        .opacity(targetAtEnd ? 1 : 0.35)
                        .onDrop(of: [dragUTI.identifier],
                                delegate: TailDropDelegate(
                                    items: $items,
                                    working: $working,
                                    dragItem: $dragItem,
                                    targetedID: $targetedID,
                                    lastAppliedTargetID: $lastAppliedTargetID,
                                    targetAtEnd: $targetAtEnd,
                                    endDrag: endDrag,
                                    applyMove: applyMoveToEnd
                                )
                        )
                }
            }

            // Ghost-Overlay
            if let drag = dragItem, let p = localPoint {
                content(drag)
                    .scaleEffect(1.05)
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 10)
                    .opacity(0.95)
                    //.allowsHitTesting(false)
                    .position(p)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .background(MouseToLocalBridge(screenPoint: $screenPoint, localPoint: $localPoint))
        // Nur Slot/Ghost weich animieren; Moves selbst laufen ohne Animation (siehe applyMove)
        .animation(.easeInOut(duration: 0.10), value: targetedID)
        .animation(.easeInOut(duration: 0.10), value: targetAtEnd)
        .onDisappear { endDrag() }
    }

    // MARK: - Drag lifecycle
 
    private func beginDrag(with item: T) {
        if working == nil { working = items }
        dragItem = item
        targetedID = item.id
        lastAppliedTargetID = nil
        targetAtEnd = false
        startMouseTracking()
        draggingExternal?.wrappedValue = true

        // MouseUp-Notbremse: wenn kein performDrop feuert
        mouseMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            if dragItem != nil { endDrag(); return nil }
            return event
        }
    }

    private func endDrag() {
        stopMouseTracking()
        if let m = mouseMonitorLocal { NSEvent.removeMonitor(m) }
        mouseMonitorLocal = nil
        dragItem = nil
        working = nil
        targetedID = nil
        lastAppliedTargetID = nil
        targetAtEnd = false
        draggingExternal?.wrappedValue = false
    }

    // MARK: - Mouse tracking

    private func startMouseTracking() {
        stopMouseTracking()
        mouseMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            screenPoint = NSEvent.mouseLocation
        }
        screenPoint = NSEvent.mouseLocation
    }

    private func stopMouseTracking() {
        if let m = mouseMonitorGlobal { NSEvent.removeMonitor(m) }
        mouseMonitorGlobal = nil
        screenPoint = nil
        localPoint = nil
    }

    private func provider(for item: T) -> NSItemProvider {
        let idString = String(describing: item.id)
        let data = Data(idString.utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: dragUTI.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    // MARK: - Moves (idempotent & ohne Implicit Animation)

    private func applyMove(to targetID: T.ID) {
        guard let drag = dragItem else { return }
        var arr = working ?? items
        guard let from = arr.firstIndex(of: drag),
              let to   = arr.firstIndex(where: { String(describing: $0.id) == String(describing: targetID) }),
              from != to else {
            targetedID = targetID
            return
        }

        // Implicit Animations für den Move **deaktivieren**
        withTransaction(Transaction(animation: nil)) {
            arr.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            working = arr
        }
        targetedID = targetID
        lastAppliedTargetID = targetID
        targetAtEnd = false
    }

    private func applyMoveToEnd() {
        guard let drag = dragItem else { return }
        var arr = working ?? items
        guard let from = arr.firstIndex(of: drag) else { return }
        let endIndex = arr.count - 1
        if from == endIndex { return }

        withTransaction(Transaction(animation: nil)) {
            arr.move(fromOffsets: IndexSet(integer: from), toOffset: arr.count)
            working = arr
        }
        targetedID = nil
        lastAppliedTargetID = nil
        targetAtEnd = true
    }

    // ID-Vergleich generisch
    private func equals(_ lhs: T.ID?, _ rhs: T.ID) -> Bool {
        guard let l = lhs else { return false }
        return String(describing: l) == String(describing: rhs)
    }
}

// MARK: - DropDelegates (entprellt)

private struct ItemDropDelegate<T: Identifiable & Hashable>: DropDelegate {
    let targetID: T.ID
    @Binding var items: [T]
    @Binding var working: [T]?
    @Binding var dragItem: T?
    @Binding var targetedID: T.ID?
    @Binding var lastAppliedTargetID: T.ID?
    @Binding var targetAtEnd: Bool
    let endDrag: () -> Void
    let applyMove: (T.ID) -> Void

    func dropEntered(info: DropInfo) {
        guard dragItem != nil else { return }
        // Debounce: Nur reagieren, wenn sich die Ziel-ID geändert hat
        if let last = lastAppliedTargetID,
           String(describing: last) == String(describing: targetID) {
            targetedID = targetID
            targetAtEnd = false
            return
        }
        applyMove(targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if let arr = working { items = arr }
        endDrag()
        return true
    }

    func dropExited(info: DropInfo) {
        // Nur Hover-Flags löschen; Drag läuft weiter
        targetedID = nil
        targetAtEnd = false
    }

    func validateDrop(info: DropInfo) -> Bool { true }
}

private struct TailDropDelegate<T: Identifiable & Hashable>: DropDelegate {
    @Binding var items: [T]
    @Binding var working: [T]?
    @Binding var dragItem: T?
    @Binding var targetedID: T.ID?
    @Binding var lastAppliedTargetID: T.ID?
    @Binding var targetAtEnd: Bool
    let endDrag: () -> Void
    let applyMove: () -> Void

    func dropEntered(info: DropInfo) {
        guard dragItem != nil else { return }
        // Debounce: Ziel „Ende“ ist ein eigener Zustand → wende nur einmal an
        if targetAtEnd == true { return }
        applyMove()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if let arr = working { items = arr }
        endDrag()
        return true
    }

    func dropExited(info: DropInfo) {
        targetedID = nil
        targetAtEnd = false
    }

    func validateDrop(info: DropInfo) -> Bool { true }
}

private struct ContainerDropDelegate<T: Identifiable & Hashable>: DropDelegate {
    @Binding var items: [T]
    @Binding var working: [T]?
    @Binding var dragItem: T?
    @Binding var targetedID: T.ID?
    @Binding var lastAppliedTargetID: T.ID?
    @Binding var targetAtEnd: Bool
    let endDrag: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        // Commit, auch wenn keine Zielkachel getroffen wurde
        if let arr = working { items = arr }
        endDrag()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: .move) }
    func dropExited(info: DropInfo) { /* noop */ }
    func validateDrop(info: DropInfo) -> Bool { true }
}

// MARK: - Slot-View

private struct SlotView: View {
    let height: CGFloat
    let corner: CGFloat
    var dashed: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 4] : [])
            )
            .foregroundStyle(Color.accentColor.opacity(0.8))
            .frame(height: height)
            .shadow(color: Color.accentColor.opacity(0.3), radius: 6)
            .transition(.opacity)
    }
}

// MARK: - Maus → lokale Koordinaten Bridge

private struct MouseToLocalBridge: NSViewRepresentable {
    @Binding var screenPoint: CGPoint?
    @Binding var localPoint: CGPoint?

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let sp = screenPoint, let win = nsView.window else {
            DispatchQueue.main.async { self.localPoint = nil }
            return
        }
        let winPoint = win.convertPoint(fromScreen: sp)     // Screen → Window
        let lp = nsView.convert(winPoint, from: nil)        // Window → Local
        DispatchQueue.main.async {
            self.localPoint = lp
        }
    }
}
