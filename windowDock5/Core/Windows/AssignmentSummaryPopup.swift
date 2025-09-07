import AppKit

@MainActor
enum AssignmentSummaryPopup {
    /// Zeigt einen Dialog mit der Fensterliste pro Bildschirm.
    static func present(groupedByScreen: [String: [WindowInfo]]) {
        // Reihenfolge der Screens stabil machen (wie NSScreen.screens)
        let order = screenOrderMap()

        // Text bauen
        let text = buildSummaryText(grouped: groupedByScreen, order: order)

        // UI erstellen (NSAlert + nicht editierbare TextView als Accessory)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Fensterzuordnung nach App-Start"
        alert.informativeText = "Pro Bildschirm werden die zugehörigen Fenster aufgelistet."

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = text

        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        alert.accessoryView = scroll

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Helpers

    /// Liefert eine Zuordnung ScreenID → Ordnungsindex (1,2,3…) entsprechend NSScreen.screens.
    private static func screenOrderMap() -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, s) in NSScreen.screens.enumerated() {
            map[s.wd_displayIDString] = i + 1
        }
        return map
    }

    private static func buildSummaryText(grouped: [String: [WindowInfo]], order: [String: Int]) -> String {
        // Sortierung der Screens nach Reihenfolge
        let sortedKeys = grouped.keys.sorted { (a, b) -> Bool in
            let ia = order[a] ?? Int.max
            let ib = order[b] ?? Int.max
            if ia != ib { return ia < ib }
            return a < b
        } 

        var lines: [String] = []
        for sid in sortedKeys {
            let index = order[sid] ?? 0
            let header = "Bildschirm \(index == 0 ? sid : String(index)):"
            lines.append(header)

            // Fenster sortieren: zuerst aktiv, dann App-Name, dann Titel
            let items = grouped[sid] ?? []
            let sortedItems = items.sorted { a, b in
                if a.isActive != b.isActive { return a.isActive && !b.isActive }
                let an = appName(for: a) ; let bn = appName(for: b)
                if an != bn { return an.localizedCaseInsensitiveCompare(bn) == .orderedAscending }
                return displayTitle(for: a).localizedCaseInsensitiveCompare(displayTitle(for: b)) == .orderedAscending
            }

            for win in sortedItems {
                let name = appName(for: win)
                let title = displayTitle(for: win)
                // Falls Titel leer oder bereits im Namen enthalten, nur den Namen zeigen
                if title.isEmpty || title == name {
                    lines.append("- \(name)")
                } else {
                    lines.append("- \(name) - \(title)")
                }
            }
            lines.append("") // Leerzeile zwischen Bildschirmen
        }
        return lines.joined(separator: "\n")
    }

    private static func appName(for w: WindowInfo) -> String {
        // Versuche Prozessnamen, sonst Bundle-ID
        if let app = NSRunningApplication(processIdentifier: w.ownerPID),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        return w.bundleID
    }

    private static func displayTitle(for w: WindowInfo) -> String {
        w.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
