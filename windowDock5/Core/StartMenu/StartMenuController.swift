import SwiftUI
import AppKit

@MainActor
final class StartMenuController: NSWindowController, NSWindowDelegate, ObservableObject {
    static let shared = StartMenuController(window: nil)

    // KEINE IUOs mehr
    private var prefs: StartMenuPrefs = StartMenuPrefs.load()
    private var rootHosting: NSHostingView<AnyView>?
    // ⚠️ WICHTIG: keine eigene `window`-Property! Die von NSWindowController wird verwendet.

    // Dismiss-Monitore
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?

    // Stores & Prefs werden injiziert (keine Singletons hier erzwingen)
    private var injectedStartStore: StartMenuStore?
    private var injectedTileStore: TileStore?

    private var resizeStartFrame: NSRect?
    private var resizeAnchorOrigin: NSPoint?   // unten links (Frame.origin)
    private let minMenuSize = CGSize(width: 620, height: 360)
    
    private let defaultMenuSize = CGSize(width: 900, height: 700)

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    // Call once from App start:
    func configure(startStore: StartMenuStore, tileStore: TileStore, prefs: StartMenuPrefs) {
        self.injectedStartStore = startStore
        self.injectedTileStore = tileStore
        self.prefs = prefs

        // Falls das Host-View schon existiert, aktualisieren wir dessen RootView
        if let host = rootHosting {
            host.rootView = AnyView(
                StartMenuView(startStore: startStore, tileStore: tileStore, prefs: prefs)
            )
        }
    }
    
    @MainActor
    func toggle(at hostingView: NSView?) {
        let win = ensureWindow()
        if win.isVisible { hide(); return }

        // 1) Screen vom Button-Host, 2) unter Maus, 3) Main, 4) first
        let screenCandidate = hostingView?.window?.screen
            ?? StartMenuController.screen(containing: NSEvent.mouseLocation)
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = screenCandidate else { return }
        present(on: screen)
    }
    
    func toggle(on screen: NSScreen) {
        if self.window?.isVisible == true {
            hide()
        } else {
            present(on: screen)
        }
    }
    
    func atMouse() {
        let loc = NSEvent.mouseLocation   // global
        // Bildschirm finden, der den Punkt enthält
        let screen = NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
        show(on: screen)
    }

    /// Startmenü an aktueller Mausposition am *richtigen* Monitor anzeigen/ausblenden
    func toggleAtMouse() {
        let mouse = NSEvent.mouseLocation
        if isVisible {
            hide()
        } else {
            present(at: mouse)
        }
    }

    /// Auf dem Screen öffnen, der den globalen Punkt enthält
    func present(at globalPoint: NSPoint) {
        // Fix: korrekten Screen anhand des globalen Punkts ermitteln
        guard let screen = StartMenuController.screen(containing: globalPoint)
            ?? NSScreen.main
            ?? NSScreen.screens.first else { return }
        present(on: screen)
    }
    
    /// Auf einem konkreten Screen öffnen
    @MainActor
    func present(on screen: NSScreen) {
        let win = ensureWindow()

        // Stores müssen vorher via `configure(...)` gesetzt sein
        guard let startStore = injectedStartStore,
              let tileStore  = injectedTileStore else {
            assertionFailure("StartMenuController.configure(...) vor present(on:) aufrufen!")
            return
        }

        if rootHosting == nil {
            let view = StartMenuView(startStore: startStore, tileStore: tileStore, prefs: prefs)
                .frame(minWidth: defaultMenuSize.width, minHeight: defaultMenuSize.height)
            let host = NSHostingView(rootView: AnyView(view))   // Host ist <AnyView>
            rootHosting = host
            win.contentView = host
        } else if let host = rootHosting {
            win.contentView = host
        } 

        win.minSize = CGSize(width: 620, height: 360)              // optional: min
        let size   = StartMenuController.menuSizeFromPrefs(prefs)
        win.setContentSize(size)                                   // <- wichtig gegen Schrumpfen

        let origin = StartMenuController.anchorTopOfTaskbarLeft(on: screen, menuSize: size, prefs: prefs)
        let newFrame = NSRect(origin: origin, size: size)

        win.setFrame(newFrame, display: false)

        // 1) App nach vorne
        NSApp.activate(ignoringOtherApps: true)

        // 2) Fenster wirklich Main + Key
        win.makeKeyAndOrderFront(nil)
        win.makeMain()

        // 3) Danach Suchfokus anfordern (wenn die View montiert ist)
        DispatchQueue.main.async {
            // An den SearchField-Halter delegieren (SwiftUI kümmert sich)
            NotificationCenter.default.post(name: .wdRequestSearchFocus, object: nil)
        }

        installDismissMonitors()
    }

    @MainActor
    func hide() {
        self.window?.orderOut(nil)
        removeDismissMonitors()
    }

    @MainActor
    func show(on screen: NSScreen?) {
        ensureWindow()
        guard let win = window else { return }
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }

        // ✅ Stores sauber aus der Injektion holen
        guard let startStore = injectedStartStore,
              let tileStore  = injectedTileStore else {
            assertionFailure("StartMenuController.configure(...) vor show(on:) aufrufen!")
            return
        }

        // ✅ Host nur einmal erzeugen/weiterverwenden
        if rootHosting == nil {
            let view = StartMenuView(startStore: startStore, tileStore: tileStore, prefs: prefs)
            let host = NSHostingView(rootView: AnyView(view))
            rootHosting = host
            win.contentView = host
        } else if let host = rootHosting {
            win.contentView = host
        }

        // ✅ kein Force-unwrap mehr
        let size   = StartMenuController.menuSizeFromPrefs(prefs)
        let origin = StartMenuController.anchorTopOfTaskbarLeft(on: screen, menuSize: size, prefs: prefs)
        let newFrame = NSRect(origin: origin, size: size)

        win.setFrame(newFrame, display: false)

        // 🔸 App nach vorne + Fenster key
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // 🔸 Fokus ins Suchfeld (asynchron)
        DispatchQueue.main.async {
            if let host = self.rootHosting {
                win.makeFirstResponder(host)                 // ✅ Tastatur in SwiftUI
            }
            NotificationCenter.default.post(name: .wdRequestSearchFocus, object: nil)
        }

        installDismissMonitors()

        // letzte Größe speichern
        self.prefs.lastFrame = newFrame
        self.prefs.save()
    }
    
    var isVisible: Bool { window?.isVisible ?? false }
    
    func beginResizeTopRight() {
        guard let w = window else { return }
        resizeStartFrame = w.frame
        resizeAnchorOrigin = w.frame.origin    // Anker unten links beibehalten
    }

    func updateResizeTopRight(to mouse: NSPoint) {
        guard let w = window else { return }
        guard let origin = resizeAnchorOrigin else { return }

        // Zielgröße: Abstand Maus zur Anker-Ecke (unten links)
        var newW = mouse.x - origin.x
        var newH = mouse.y - origin.y

        // Mindestgrößen
        newW = max(minMenuSize.width, newW)
        newH = max(minMenuSize.height, newH)

        // Sichtbaren Bereich respektieren
        if let screen = w.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            // Breite/Höhe so klemmen, dass rechte/obere Kante nicht über vf gehen
            newW = min(newW, vf.maxX - origin.x)
            newH = min(newH, vf.maxY - origin.y)
        }

        let newFrame = NSRect(x: origin.x, y: origin.y, width: newW, height: newH)
        w.setFrame(newFrame, display: true, animate: false)
    }

    func commitResize() {
        guard let w = window else { return }
        // Prefs aktualisieren (falls vorhanden)
        prefs.lastFrame = w.frame
        prefs.save()
        // State räumen
        resizeStartFrame = nil
        resizeAnchorOrigin = nil
    }
    
    /// Für den Resize-Corner: User-Resize während Drag
    func userResize(delta: CGSize) {
        applyUserResize(delta: delta)              // ruft deine bestehende fileprivate-Implementierung
    }

    /// Für Doppelklick im Resize-Corner oder andere Shortcuts
    func toggleMaximizeOrRestore() {
        applyToggleMaximizeOrRestore()             // ruft deine bestehende fileprivate-Implementierung
    }
}

// MARK: - Positionierung & Pref-Helfer ----------------------------------------

private extension StartMenuController {
    private static weak var _current: StartMenuController?
    
    static func screen(containing globalPoint: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(globalPoint, $0.frame, false) }
    }

    static func menuSizeFromPrefs(_ prefs: StartMenuPrefs) -> CGSize {
        // 0) Zentrale Defaults
        let defaults = StartMenuController.shared.defaultMenuSize   // 900x700 (s.o.)
        let minW: CGFloat = 620
        let minH: CGFloat = 320

        // 1) Zuletzt gespeicherte Frame-Größe verwenden – aber "unplausible" ignorieren
        if let last = prefs.lastFrame, last.width >= 200, last.height >= 200 {
            let w = max(minW, last.size.width)
            let h = max(minH, last.size.height)
            return CGSize(width: w, height: h)
        }

        // 2) Fallback: einzelne Breite/Höhe-Werte oder zentrale Defaults
        func cg(_ any: Any?, _ fallback: CGFloat) -> CGFloat {
            switch any {
            case let v as CGFloat: return v
            case let v as Double:  return CGFloat(v)
            case let v as Float:   return CGFloat(v)
            case let v as Int:     return CGFloat(v)
            default:               return fallback
            }
        }

        // 👇 statt 560/560 jetzt die zentralen Defaults
        let w = cg(prefs.menuWidth,  defaults.width)
        let h = cg(prefs.menuHeight, defaults.height)
        return CGSize(width: max(minW, w), height: max(minH, h))
    }

    /// Linksbündig, direkt *oberhalb* der Taskbar positionieren
    static func anchorTopOfTaskbarLeft(on screen: NSScreen, menuSize: CGSize, prefs: StartMenuPrefs) -> NSPoint {
        let vf = screen.visibleFrame

        // Feste, sehr kleine Abstände zum „Look & Feel“: 2 px
        let gap: CGFloat = 2
        let leftInset: CGFloat = 4

        // Höhe der eigenen Taskleiste (Fallback: 56, falls Prefs leer)
        let taskbarH: CGFloat = (prefs.taskbarHeight ?? 38)

        // Zielposition: unten-links, direkt über der Taskleiste mit 2 px Abstand
        var x = vf.minX + leftInset
        var y = vf.minY + taskbarH + gap

        // In den sichtbaren Bereich klemmen, falls das Menü größer ist
        if x + menuSize.width > vf.maxX { x = max(vf.minX, vf.maxX - menuSize.width) }
        if y + menuSize.height > vf.maxY { y = max(vf.minY, vf.maxY - menuSize.height) }

        return CGPoint(x: x, y: y)
    }

    @discardableResult
    func ensureWindow() -> NSWindow {
        if let w = self.window { return w }

        let panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: defaultMenuSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false

        panel.minSize = CGSize(width: 620, height: 360)

        panel.delegate = self
        self.window = panel
        return panel
    }
    
    /// Beim Anzeigen/Initialisieren die aktive Instanz setzen.
    func markAsCurrent() { StartMenuController._current = self }

    // --- Zustände für Resize/Maximieren ---
    private struct Bounds {
        let minSize = CGSize(width: 620, height: 320)           // Untergrenze
    }

    private var bounds: Bounds { Bounds() }
    
    // Merkt sich die "normale" Fenstergröße für Toggle
    private var lastNormalFrame: NSRect? {
        get { _lastNormalFrame }
        set { _lastNormalFrame = newValue }
    }
    private static var _storeLastNormalFrame = [ObjectIdentifier: NSRect]()
    private var _lastNormalFrame: NSRect? {
        get { Self._storeLastNormalFrame[ObjectIdentifier(self)] }
        set { Self._storeLastNormalFrame[ObjectIdentifier(self)] = newValue }
    }
    
    func installDismissMonitors() {
        removeDismissMonitors() // doppelte Registrierung vermeiden
        
        // 1) Lokaler Monitor: Klicks innerhalb der App
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let w = self.window else { return event }
            let loc = event.locationInWindow
            // Punkt in Screen-Koordinaten umrechnen
            let screenPoint = w.convertToScreen(NSRect(origin: loc, size: .zero)).origin
            // Wenn außerhalb unseres Fensters geklickt wurde → schließen
            if !w.frame.contains(screenPoint) {
                self.hide()
            }
            return event
        }

        // 2) Globaler Monitor: Klicks in anderen Apps
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Global liefert schon Screen-Koordinaten über mouseLocation
            guard let self, let w = self.window else { return }
            let pt = NSEvent.mouseLocation
            if !w.frame.contains(pt) {
                self.hide()
            }
        }
    }

    func removeDismissMonitors() {
        if let m = localMouseDownMonitor {
            NSEvent.removeMonitor(m)
            localMouseDownMonitor = nil
        }
        if let m = globalMouseDownMonitor {
            NSEvent.removeMonitor(m)
            globalMouseDownMonitor = nil
        }
    }
}

extension StartMenuController {
    func windowDidBecomeKey(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        guard let win = self.window else { return }
        DispatchQueue.main.async {
            if let host = self.rootHosting {
                win.makeFirstResponder(host)         // ✅ Responder-Kette korrigieren
            }
            NotificationCenter.default.post(name: .wdRequestSearchFocus, object: nil)
        }
    }
}

fileprivate extension StartMenuController {
    func applyUserResize(delta: CGSize) {
        guard let win = self.window else { return }
        let current = win.frame
        let screen  = win.screen ?? NSScreen.main ?? NSScreen.screens.first
        let minW: CGFloat = 320, minH: CGFloat = 320
        var new = current
        new.size.width  = max(minW, current.size.width  + delta.width)
        new.size.height = max(minH, current.size.height + delta.height)
        if let s = screen {
            let vf = s.visibleFrame
            new.size.width  = min(new.size.width,  vf.width)
            new.size.height = min(new.size.height, vf.height)
            if new.maxX > vf.maxX { new.origin.x = vf.maxX - new.width }
            if new.maxY > vf.maxY { new.origin.y = vf.maxY - new.height }
            if new.minX < vf.minX { new.origin.x = vf.minX }
            if new.minY < vf.minY { new.origin.y = vf.minY }
        }
        win.setFrame(new, display: true, animate: false)
    }

    func applyCommitResize() {
        guard let win = self.window else { return }
        prefs.lastFrame = win.frame
        prefs.save()
    }

    func applyToggleMaximizeOrRestore() {
        guard let win = self.window else { return }
        guard let screen = win.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let side     = prefs.sideInset     ?? 8
        let taskbarH = prefs.taskbarHeight ?? 48

        let maxH = max(320, vf.height - taskbarH)
        let isMaxLike = abs(win.frame.width - vf.width) < 2 && abs(win.frame.height - maxH) < 2
        if isMaxLike, let last = prefs.lastFrame {
            win.setFrame(last, display: true, animate: false)
        } else {
            let origin = NSPoint(x: vf.minX + side, y: vf.minY + taskbarH)
            let size   = CGSize(width: vf.width, height: maxH)
            win.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        }
        prefs.lastFrame = win.frame
        prefs.save()
    }
}

extension Notification.Name {
    static let wdRequestSearchFocus = Notification.Name("wdRequestSearchFocus")
}
