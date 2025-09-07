//
//  WindowsInventory.swift
//  Created for per-display window snapshotting (App-Store mode: CG+AX)
//  macOS 15.6
//

import Foundation
import AppKit
import ApplicationServices

// MARK: - Public Model

public struct WindowInfo: Hashable {
    public let bundleID: String
    public let pid: pid_t
    public let windowNumber: Int?      // AX/CG "window number" (WN)
    public let wid: Int?               // CGS Window ID (from CG; nil for AX-only/minimized)
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
    public let isActive: Bool
    public let isFullscreen: Bool
    public let displayID: CGDirectDisplayID
    public let sources: Set<String>    // e.g., ["CG","AX"]

    public init(bundleID: String,
                pid: pid_t,
                windowNumber: Int?,
                wid: Int?,
                title: String,
                frame: CGRect,
                isMinimized: Bool,
                isActive: Bool,
                isFullscreen: Bool,
                displayID: CGDirectDisplayID,
                sources: Set<String>) {
        self.bundleID = bundleID
        self.pid = pid
        self.windowNumber = windowNumber
        self.wid = wid
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isActive = isActive
        self.isFullscreen = isFullscreen
        self.displayID = displayID
        self.sources = sources
    }
}

// MARK: - Config (lokal, zentral steuerbar)

public struct WindowGraphConfig {
    public enum Mode { case appStore /* CG+AX */, pro /* +SLS (nicht in dieser Datei) */ }
    public var mode: Mode = .appStore
    public var includeTransientWindows: Bool = false
    public var overlapThresholdPercent: Double = 0.05     // 5%
    public var overlapMinPixels: Int = 1024               // 1024 px²
    public var minWindowSize: CGSize = .init(width: 12, height: 12)
    public var hysteresisPercentPoints: Double = 0.10     // 10 pp
    public var persistCache: Bool = true
    public var cacheStoreURL: URL = DefaultCache.url

    public init() {}
}

private enum DefaultCache {
    static var url: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "WindowGraph", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("windowgraph-cache.plist")
    }
}

// MARK: - Public API

public enum WindowsInventory {

    /// Nimmt einen Snapshot auf und druckt **pro Display** eine Tabelle auf stdout.
    @discardableResult
    public static func snapshotAndPrint(config: WindowGraphConfig = .init()) -> [WindowInfo] {
        var cache = DisplayCache.load(from: config.cacheStoreURL)
        let infos = snapshot(config: config, cache: &cache)
        if config.persistCache { cache.save(to: config.cacheStoreURL) }
        ConsolePrinter.printByDisplay(infos: infos)
        return infos
    }

    /// Erzeugt die per-Display deduplizierte Fensterliste (App-Store Modus: CG+AX).
    public static func snapshot(config: WindowGraphConfig = .init(),
                                cache: inout DisplayCache) -> [WindowInfo] {

        // 1) Collect
        let cg = CGCollector.collect(minSize: config.minWindowSize)
        let ax = AXCollector.collect(includeTransient: config.includeTransientWindows)

        // 2) Normalize/Index
        let cgIndex = cg.indexedByWID()
        let axIndexWN = ax.indexedByPIDWN()

        // 3) Build Raw pool
        var raws: [RawWin] = []
        raws.reserveCapacity(cg.count + ax.count + 8)
        raws.append(contentsOf: cg)
        raws.append(contentsOf: AXCollector.mergeAXWithCGHints(ax: ax, cgByWID: cgIndex))

        // 4) Group & Score (dedupe)
        let grouped = Grouper.group(raws: raws)
        let merged = Merger.merge(groups: grouped)

        // 5) Display assignment (App-Store: Overlap→Cache→Fallback; minimized/zero: Cache→Fallback)
        let assigner = DisplayAssigner(config: config, cache: cache)
        let finalInfos = merged.map { assigner.assignDisplay(for: $0) }

        // 6) Update cache (last stable display only for visible & stable picks)
        cache.update(with: finalInfos)

        // 7) Sort stable for printing (by display, then bundle, then title)
        return finalInfos.sorted(by: Sorters.byDisplayBundleTitle)
    }
}

// MARK: - Internal Raw Model

private struct RawWin: Hashable {
    enum Source: String { case CG, AX }
    let source: Source
    let pid: pid_t
    let bundleID: String
    let wid: Int?            // CG-only
    let wn: Int?             // AX/CG window number when available
    let titleNorm: String
    let titleRaw: String
    let frame: CGRect        // can be .zero for minimized AX
    let isMinimized: Bool
    let isActive: Bool
    let isFullscreen: Bool
}

private extension Array where Element == RawWin {
    func indexedByWID() -> [Int: RawWin] {
        reduce(into: [:]) { dict, r in if let w = r.wid { dict[w] = r } }
    }
}

private extension Array where Element == AXCollector.AXRaw {
    func indexedByPIDWN() -> [String: AXCollector.AXRaw] {
        reduce(into: [:]) { $0["\($1.pid)#\($1.wn ?? -1)"] = $1 }
    }
}

// MARK: - Collectors

private enum CGCollector {
    struct CGRaw {
        let pid: pid_t
        let bundleID: String
        let wid: Int
        let wn: Int?
        let title: String
        let frame: CGRect
        let isOnScreen: Bool
        let isActive: Bool
    }

    static func collect(minSize: CGSize) -> [RawWin] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [RawWin] = []
        out.reserveCapacity(info.count)

        for item in info {
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let alpha = item[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else { continue }

            let boundsDict = item[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let frame = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0, width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            guard frame.width >= minSize.width, frame.height >= minSize.height else { continue }

            let pid = item[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard pid > 0 else { continue }

            let ownerName = item[kCGWindowOwnerName as String] as? String ?? ""
            let title = (item[kCGWindowName as String] as? String)?.trimmed() ?? ""
            let bundleID = RunningApps.bundleID(forPID: pid) ?? ownerName
            let wid = item[kCGWindowNumber as String] as? Int ?? 0
            let wn: Int? = (item[kCGWindowNumber as String] as? Int) // same as wid for many apps; AX may differ

            let isActive = RunningApps.isAppActive(pid: pid)

            out.append(RawWin(source: .CG,
                              pid: pid,
                              bundleID: bundleID,
                              wid: wid,
                              wn: wn,
                              titleNorm: Title.normalize(title.isEmpty ? ownerName : title),
                              titleRaw: title.isEmpty ? ownerName : title,
                              frame: frame,
                              isMinimized: false,
                              isActive: isActive,
                              isFullscreen: false))
        }
        return out
    }
}

private enum AXCollector {

    struct AXRaw: Hashable {
        let pid: pid_t
        let bundleID: String
        let wn: Int?
        let title: String
        let frame: CGRect    // .zero for minimized/offscreen often
        let isMinimized: Bool
        let isActive: Bool
        let isFullscreen: Bool
    }

    static func collect(includeTransient: Bool) -> [AXRaw] {
        var out: [AXRaw] = []
        for app in NSWorkspace.shared.runningApplications where app.isFinishedLaunching && app.processIdentifier > 0 {
            guard let ax = axApp(for: app.processIdentifier) else { continue }

            // active / fullscreen hints (best effort)
            let isActive = app.isActive

            guard let windows = axCopyArray(ax, kAXWindowsAttribute as CFString) else { continue }
            for wObj in windows {
                guard let w = wObj as? AXUIElement else { continue }

                // Role/Subrole filter (transients raus, wenn nicht gewünscht)
                if !includeTransient && !AXFilters.isPrimaryWindow(w) { continue }

                let minimized = axCopyBool(w, kAXMinimizedAttribute as CFString) ?? false
                let title = (axCopyString(w, kAXTitleAttribute as CFString) ?? "").trimmed()
                let wn = axCopyInt(w, "AXWindowNumber" as CFString) // private-ish but commonly present
                let rect = axCopyRect(w, kAXFrameAttribute as CFString) ?? .zero
                let isFullscreen = axCopyBool(w, "AXFullScreen" as CFString) ?? false

                let bundleID = app.bundleIdentifier ?? app.localizedName ?? "Unknown"
                out.append(AXRaw(pid: app.processIdentifier,
                                 bundleID: bundleID,
                                 wn: wn,
                                 title: title,
                                 frame: rect,
                                 isMinimized: minimized,
                                 isActive: isActive,
                                 isFullscreen: isFullscreen))
            }
        }
        return out
    }

    /// Mappt AX-Rohdaten in RawWin und reichert mit CG-WID an, wenn das AX-Fenster anhand (PID, WN) einem CG-Fenster zuordenbar ist.
    static func mergeAXWithCGHints(ax: [AXRaw], cgByWID: [Int: RawWin]) -> [RawWin] {
        // In App-Store-Modus können wir WID nicht direkt von AX bekommen;
        // wir nutzen (PID,WN)-Heuristik über die CG-Menge: baue sekundären Index PID→[RawWin]
        var byPID: [pid_t: [RawWin]] = [:]
        for (_, cg) in cgByWID { byPID[cg.pid, default: []].append(cg) }

        var out: [RawWin] = []
        out.reserveCapacity(ax.count)

        for a in ax {
            let candidates = byPID[a.pid] ?? []
            let matchWID = candidates.first(where: { cg in
                // gleiche WN, oder – wenn nicht vorhanden – sehr ähnliche Titel + hohe IOU
                if let awn = a.wn, let cwn = cg.wn, awn == cwn { return true }
                let titleClose = Title.normalize(a.title) == cg.titleNorm
                let iou = Geometry.iou(a.frame, cg.frame)
                return titleClose && iou >= 0.8
            })?.wid

            out.append(RawWin(source: .AX,
                              pid: a.pid,
                              bundleID: a.bundleID,
                              wid: matchWID,
                              wn: a.wn,
                              titleNorm: Title.normalize(a.title.isEmpty ? a.bundleID : a.title),
                              titleRaw: a.title.isEmpty ? a.bundleID : a.title,
                              frame: a.frame,
                              isMinimized: a.isMinimized,
                              isActive: a.isActive,
                              isFullscreen: a.isFullscreen))
        }
        return out
    }

    // MARK: AX helpers

    private static func axApp(for pid: pid_t) -> AXUIElement? {
        let ax = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &focused)
        if err == .success { return ax }
        return nil
    }

    private static func axCopyArray(_ el: AXUIElement, _ attr: CFString) -> [AnyObject]? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return v as? [AnyObject]
    }

    private static func axCopyString(_ el: AXUIElement, _ attr: CFString) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return v as? String
    }

    private static func axCopyBool(_ el: AXUIElement, _ attr: CFString) -> Bool? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return v as? Bool
    }

    private static func axCopyInt(_ el: AXUIElement, _ attr: CFString) -> Int? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        if let num = v as? NSNumber { return num.intValue }
        return v as? Int
    }

    private static func axCopyRect(_ el: AXUIElement, _ attr: CFString) -> CGRect? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        if let value = v {
            var rect = CGRect.zero
            if AXValueGetType(value as! AXValue) == .cgRect {
                AXValueGetValue(value as! AXValue, .cgRect, &rect)
                return rect
            }
        }
        return nil
    }
}

private enum AXFilters {
    static func isPrimaryWindow(_ w: AXUIElement) -> Bool {
        // role == window && subrole ∈ {AXStandardWindow, AXDialog}
        func attr(_ key: CFString) -> String? {
            var v: AnyObject?
            guard AXUIElementCopyAttributeValue(w, key, &v) == .success else { return nil }
            return v as? String
        }
        let role = attr(kAXRoleAttribute as CFString) ?? ""
        guard role == kAXWindowRole as String else { return false }
        let sub = attr(kAXSubroleAttribute as CFString) ?? ""
        return sub == (kAXStandardWindowSubrole as String) || sub == "AXDialog"
    }
}

// MARK: - Grouping / Scoring / Merging

private enum Grouper {
    /// Liefert Gruppen potenzieller Duplikate in deterministischer Reihenfolge.
    static func group(raws: [RawWin]) -> [[RawWin]] {
        // G1: gleiche WID
        var byWID: [Int: [RawWin]] = [:]
        var widless: [RawWin] = []
        for r in raws {
            if let w = r.wid { byWID[w, default: []].append(r) } else { widless.append(r) }
        }
        var groups: [[RawWin]] = byWID.values.map { $0 }

        // G2: (PID, WN)
        var used = Set<RawWin>(groups.flatMap { $0 })
        let byPIDWN = Dictionary(grouping: widless, by: { "\($0.pid)#\($0.wn ?? -1)" })
        for (_, arr) in byPIDWN {
            let residual = arr.filter { !used.contains($0) }
            if residual.count > 1 { groups.append(residual); used.formUnion(residual) }
        }

        // G3: (PID, TitleNorm) mit Frame-Nähe/Zero-Symmetrie
        let byPIDTitle = Dictionary(grouping: widless.filter { !used.contains($0) }, by: { "\($0.pid)#\($0.titleNorm)" })
        for (_, arr) in byPIDTitle {
            let residual = arr
            guard residual.count > 1 else { continue }
            // split nach IOU/Zero
            var bucket: [RawWin] = []
            for r in residual {
                if bucket.isEmpty { bucket.append(r); continue }
                let iou = Geometry.iou(bucket[0].frame, r.frame)
                let bothZero = bucket[0].frame.equalTo(.zero) && r.frame.equalTo(.zero)
                if iou >= 0.8 || bothZero { bucket.append(r) }
            }
            if bucket.count > 1 { groups.append(bucket); used.formUnion(bucket) }
        }

        // G4: restliche Singles als eigene Gruppen
        let singles = raws.filter { !used.contains($0) }
        groups.append(contentsOf: singles.map { [$0] })

        return groups
    }
}

private enum Merger {
    static func merge(groups: [[RawWin]]) -> [MergedWin] {
        groups.map { mergeGroup($0) }
    }

    struct MergedWin: Hashable {
        let pid: pid_t
        let bundleID: String
        let wid: Int?
        let wn: Int?
        let title: String
        let frame: CGRect
        let isMinimized: Bool
        let isActive: Bool
        let isFullscreen: Bool
        let sources: Set<String>
    }

    private static func mergeGroup(_ g: [RawWin]) -> MergedWin {
        // Score: WID(1000) + source(CG:300 AX:200) + geom(area>0:200) + state + title + fullscreen hint
        func score(_ r: RawWin) -> Int {
            var s = 0
            if r.wid != nil { s += 1000 }
            s += (r.source == .CG) ? 300 : 200
            if r.frame.area > 0 { s += 200 }
            if !r.isMinimized { s += 60 }
            if r.isActive { s += 40 }
            if !r.titleNorm.isEmpty { s += 20 }
            if r.isFullscreen { s += 10 }
            return s
        }

        let sorted = g.sorted {
            let s1 = score($0), s2 = score($1)
            if s1 != s2 { return s1 > s2 }
            // tie-breaker: hasWID, source CG>AX, area, !minimized, active, titleNorm, pid
            if ($0.wid != nil) != ($1.wid != nil) { return $0.wid != nil }
            if $0.source != $1.source { return $0.source == .CG }
            if $0.frame.area != $1.frame.area { return $0.frame.area > $1.frame.area }
            if $0.isMinimized != $1.isMinimized { return !$0.isMinimized }
            if $0.isActive != $1.isActive { return $0.isActive }
            if $0.titleNorm != $1.titleNorm { return $0.titleNorm < $1.titleNorm }
            return $0.pid < $1.pid
        }

        let best = sorted.first!
        // Merge: fehlende Felder aus Runner-Ups ergänzen
        var title = best.titleRaw
        var frame = best.frame
        var isMin = best.isMinimized
        var isAct = best.isActive
        var isFS = best.isFullscreen
        var wid = best.wid
        var wn = best.wn
        var sources = Set([best.source.rawValue])

        for r in sorted.dropFirst() {
            sources.insert(r.source.rawValue)
            if title.isEmpty { title = r.titleRaw }
            if frame.area == 0, r.frame.area > 0 { frame = r.frame }
            if wid == nil, let w = r.wid { wid = w }
            if wn == nil, let n = r.wn { wn = n }
            // Minimized/Active/Fullscreen – „true“ gewinnt, außer minimized: „true“ überschreibt „false“
            isMin = isMin || r.isMinimized
            isAct = isAct || r.isActive
            isFS  = isFS  || r.isFullscreen
        }

        let finalTitle = title.isEmpty ? best.bundleID : title
        return MergedWin(pid: best.pid,
                         bundleID: best.bundleID,
                         wid: wid,
                         wn: wn,
                         title: finalTitle,
                         frame: frame,
                         isMinimized: isMin,
                         isActive: isAct,
                         isFullscreen: isFS,
                         sources: sources)
    }
}

// MARK: - Display assignment

private struct DisplayAssigner {
    let cfg: WindowGraphConfig
    var cache: DisplayCache

    init(config: WindowGraphConfig, cache: DisplayCache) {
        self.cfg = config
        self.cache = cache
    }

    func assignDisplay(for mw: Merger.MergedWin) -> WindowInfo {
        let screens = NSScreen.screens
        let displayForVisible: CGDirectDisplayID? = (!mw.isMinimized && mw.frame.area > 0)
        ? pickByOverlap(frame: mw.frame, screens: screens)
        : nil

        let display: CGDirectDisplayID = displayForVisible
            ?? fromCache(pid: mw.pid, wn: mw.wn, wid: mw.wid, bundleID: mw.bundleID)
            ?? NSScreen.main?.displayID ?? 0

        return WindowInfo(bundleID: mw.bundleID,
                          pid: mw.pid,
                          windowNumber: mw.wn,
                          wid: mw.wid,
                          title: mw.title,
                          frame: mw.frame,
                          isMinimized: mw.isMinimized,
                          isActive: mw.isActive,
                          isFullscreen: mw.isFullscreen,
                          displayID: display,
                          sources: mw.sources)
    }

    private func fromCache(pid: pid_t, wn: Int?, wid: Int?, bundleID: String) -> CGDirectDisplayID? {
        if let w = wid, let d = cache.lastScreenByWID[w] { return d }
        if let n = wn, let d = cache.lastScreenByPIDWN["\(pid)#\(n)"] { return d }
        if let d = cache.lastScreenByBundle[bundleID] { return d }
        return nil
    }

    private func pickByOverlap(frame: CGRect, screens: [NSScreen]) -> CGDirectDisplayID? {
        guard frame.area > 0 else { return nil }
        let thresholdPx = max(Int(Double(frame.area) * cfg.overlapThresholdPercent), cfg.overlapMinPixels)

        var best: (id: CGDirectDisplayID, overlap: Int) = (0, 0)
        for s in screens {
            let id = s.displayID
            let inter = Int(Geometry.intersectionArea(frame, s.frame))
            if inter >= thresholdPx, inter > best.overlap { best = (id, inter) }
        }
        return best.overlap > 0 ? best.id : nil
    }
}

// MARK: - Cache (persistenter Display-Verlauf)

public struct DisplayCache: Codable {
    public var lastScreenByWID: [Int: CGDirectDisplayID] = [:]
    public var lastScreenByPIDWN: [String: CGDirectDisplayID] = [:] // "pid#wn"
    public var lastScreenByBundle: [String: CGDirectDisplayID] = [:]

    static func load(from url: URL) -> DisplayCache {
        guard let data = try? Data(contentsOf: url) else { return DisplayCache() }
        do { return try PropertyListDecoder().decode(DisplayCache.self, from: data) }
        catch { return DisplayCache() }
    }

    func save(to url: URL) {
        do {
            let data = try PropertyListEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            // bewusst leise: Cache darf nie die App stören
        }
    }

    mutating func update(with infos: [WindowInfo]) {
        for w in infos {
            // Hysterese: nur sichtbare Fenster mit stabilem Display übernehmen
            if w.frame.area > 0 && !w.isMinimized {
                if let wid = w.wid { lastScreenByWID[wid] = w.displayID }
                if let wn = w.windowNumber { lastScreenByPIDWN["\(w.pid)#\(wn)"] = w.displayID }
                lastScreenByBundle[w.bundleID] = w.displayID
            }
        }
    }
}

// MARK: - Console printer (pro Display gruppiert)

private enum ConsolePrinter {
    static func printByDisplay(infos: [WindowInfo]) {
        let screensByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { ($0.displayID, $0) })
        let grouped = Dictionary(grouping: infos, by: { $0.displayID })

        // Reihenfolge: nach physikalischer Reihenfolge der NSScreen.screens
        let order = NSScreen.screens.map { $0.displayID }

        for did in order {
            let screen = screensByID[did]
            let entries = grouped[did] ?? []

            let header = "=== Display D:\(String(format: "0x%X", did)) \(screenDesc(screen)) ==="
            print(header)
            print("PID | WID | WN | BundleID              | Title                        | min act fs | x     y     w     h     | Source | Hints")
            print("----|-----|----|------------------------|------------------------------|------------|---------------------------|--------|---------------------------")

            var visible = 0, minimized = 0, fullscreen = 0
            for e in entries.sorted(by: Sorters.byBundleTitlePID) {
                if e.isMinimized { minimized += 1 } else { visible += 1 }
                if e.isFullscreen { fullscreen += 1 }
                let hints = hintString(for: e)
                print(String(format: "%4d | %@ | %@ | %@ | %@ |  %@  %@  %@ | %@ | %@",
                             e.pid,
                             e.wid != nil ? String(format: "%4d", e.wid!) : "   -",
                             e.windowNumber != nil ? String(format: "%2d", e.windowNumber!) : " -",
                             e.bundleID.fixed(22),
                             e.title.fixed(28),
                             e.isMinimized ? " T " : " F ",
                             e.isActive    ? " T " : " F ",
                             e.isFullscreen ? " T " : " F ",
                             frameCols(e.frame),
                             e.sources.sorted().joined(separator: "+").fixed(6) + " | " + hints))
            }

            print("Summary: total=\(entries.count), visible=\(visible), minimized=\(minimized), fullscreen=\(fullscreen)\n")
        }
    }

    private static func screenDesc(_ s: NSScreen?) -> String {
        guard let s = s else { return "(Unknown)" }
        let f = s.frame
        let scale = s.backingScaleFactor
        let name = s.localizedName.isEmpty ? "Display" : s.localizedName
        return "(\(name), \(Int(f.width))×\(Int(f.height)), scale \(String(format: "%.1f", scale)))"
    }

    private static func frameCols(_ f: CGRect) -> String {
        String(format: "%5.0f %5.0f %5.0f %5.0f", f.origin.x, f.origin.y, f.size.width, f.size.height)
    }

    private static func hintString(for e: WindowInfo) -> String {
        if e.frame.area == 0 || e.isMinimized {
            if e.wid != nil { return "from=cache(lastWID)" }
            else if e.windowNumber != nil { return "from=cache(lastPID#WN)" }
            else { return "from=cache(lastBundle)" }
        }
        return "overlap"
    }
}

// MARK: - Utilities

private enum RunningApps {
    static func bundleID(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
    static func isAppActive(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isActive ?? false
    }
}

private enum Title {
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "— Edited", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum Geometry {
    static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        return inter.width * inter.height
    }
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        if a.equalTo(.zero) || b.equalTo(.zero) { return 0 }
        let inter = intersectionArea(a, b)
        if inter == 0 { return 0 }
        let union = a.area + b.area - inter
        return inter / union
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}

private enum Sorters {
    static func byDisplayBundleTitle(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        if lhs.displayID != rhs.displayID { return lhs.displayID < rhs.displayID }
        return byBundleTitlePID(lhs, rhs)
    }
    static func byBundleTitlePID(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        if lhs.bundleID != rhs.bundleID { return lhs.bundleID < rhs.bundleID }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.pid < rhs.pid
    }
}
 
private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func fixed(_ len: Int) -> String {
        if count == len { return self }
        if count < len { return self + String(repeating: " ", count: len - count) }
        // truncate with ellipsis
        let end = index(startIndex, offsetBy: max(0, len - 1))
        return String(self[..<end]) + "…"
    }
}
 
