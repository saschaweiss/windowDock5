import AppKit
import Combine
import Foundation
import ApplicationServices

@MainActor
public final class WindowEventMonitor {

    // WICHTIG: Singleton explizit am MainActor – sonst Concurrency-Error in striktem Modus
    @MainActor public static let shared = WindowEventMonitor()

    public enum Event: Sendable {
        case changed
        case focused(pid: pid_t)
        case created(pid: pid_t)
        case destroyed(pid: pid_t)
        case miniaturized(pid: pid_t)
        case deminiaturized(pid: pid_t)
    }

    public let events = PassthroughSubject<Event, Never>()

    // AX-Observer werden nur am MainActor benutzt
    private var axObservers: [pid_t: AXObserver] = [:]
    private var cancellables: Set<AnyCancellable> = []
 
    private init() {}

    // MARK: - Lifecycle

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] note in
                guard
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                self?.events.send(.focused(pid: app.processIdentifier))
                self?.events.send(.changed)
            }
            .store(in: &cancellables)

        nc.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.installAX(for: app.processIdentifier)
                self?.events.send(.changed)
            }
            .store(in: &cancellables)

        nc.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.removeAX(for: app.processIdentifier)
                self?.events.send(.changed)
            }
            .store(in: &cancellables)

        nc.publisher(for: NSWorkspace.didHideApplicationNotification)
            .merge(with: nc.publisher(for: NSWorkspace.didUnhideApplicationNotification))
            .sink { [weak self] _ in self?.events.send(.changed) }
            .store(in: &cancellables)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            installAX(for: app.processIdentifier)
        }
    }

    public func stop() {
        cancellables.removeAll()
        for (pid, _) in axObservers {
            removeAX(for: pid)
        }
    }

    // MARK: - AX Observer
    
    // Kleine Box für das refcon (trägt Monitor + pid)
    private final class AXRefcon {
        unowned let monitor: WindowEventMonitor
        let pid: pid_t
        init(monitor: WindowEventMonitor, pid: pid_t) { self.monitor = monitor; self.pid = pid }
    }

    // Wir halten die Refcons stark fest, solange der Observer lebt
    private var axRefcons: [pid_t: AXRefcon] = [:]

    // C-kompatibler Callback ohne Captures
    private static let axCallback: AXObserverCallback = { _, _, notification, info in
        guard let info = info else { return }
        let ref = Unmanaged<AXRefcon>.fromOpaque(info).takeUnretainedValue()
        ref.monitor.handleAX(notification: notification as String, pid: ref.pid)
    }

    private func installAX(for pid: pid_t) {
        guard AXIsProcessTrustedWithOptions(nil) else { return }
        guard axObservers[pid] == nil else { return }

        let appEl = AXUIElementCreateApplication(pid)

        var observer: AXObserver?
        let err = AXObserverCreate(pid, Self.axCallback, &observer)
        guard err == .success, let obs = observer else { return }
        axObservers[pid] = obs

        // refcon vorbereiten und stark festhalten
        let refcon = AXRefcon(monitor: self, pid: pid)
        axRefcons[pid] = refcon
        let refPtr = Unmanaged.passUnretained(refcon).toOpaque()

        // AX möchte CFString-Notification-Namen
        let notifs: [CFString] = [
            kAXWindowCreatedNotification            as CFString,
            kAXUIElementDestroyedNotification       as CFString,
            kAXFocusedWindowChangedNotification     as CFString,
            kAXMainWindowChangedNotification        as CFString,
            kAXWindowMiniaturizedNotification       as CFString,
            kAXWindowDeminiaturizedNotification     as CFString
        ]

        for n in notifs {
            AXObserverAddNotification(obs, appEl, n, refPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    private func removeAX(for pid: pid_t) {
        if let obs = axObservers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        // Refcon wieder freigeben
        axRefcons.removeValue(forKey: pid)
    }

    // MARK: - AX Handler
    private func handleAX(notification n: String, pid: pid_t) {
        // Einmalig die String-Vergleichswerte ableiten
        let created       = kAXWindowCreatedNotification        as String
        let destroyed     = kAXUIElementDestroyedNotification   as String
        let mini          = kAXWindowMiniaturizedNotification   as String
        let demini        = kAXWindowDeminiaturizedNotification as String
        let focusedChange = kAXFocusedWindowChangedNotification as String
        let mainChange    = kAXMainWindowChangedNotification    as String

        switch n {
        case created:       events.send(.created(pid: pid))
        case destroyed:     events.send(.destroyed(pid: pid))
        case mini:          events.send(.miniaturized(pid: pid))
        case demini:        events.send(.deminiaturized(pid: pid))
        case focusedChange,
             mainChange:    events.send(.focused(pid: pid))
        default:            events.send(.changed)
        }
    }

    // MARK: - Actions for taskbar buttons
    @discardableResult
    public func focus(pid: pid_t, windowNumber: Int?, titleHint: String?) -> Bool {
        guard AXIsProcessTrustedWithOptions(nil) else { return false }
        let appEl = AXUIElementCreateApplication(pid)

        guard let wins = axCopyArray(appEl, kAXWindowsAttribute as CFString) else { return false }
        for case let el as AXUIElement in wins {
            var matched = false

            if let wn = windowNumber,
               let n  = axCopyValue(el, "_AXWindowID" as CFString) as? Int,
               n == wn { matched = true }

            if !matched, let t = titleHint,
               let title = axCopyValue(el, kAXTitleAttribute as CFString) as? String,
               title.hasPrefix(t) { matched = true }

            if !matched { continue }

            _ = AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementPerformAction(el, kAXRaiseAction as CFString)

            return NSRunningApplication(processIdentifier: pid)?
                .activate(options: [.activateAllWindows]) ?? false
        }

        // Fallback: App aktivieren
        return NSRunningApplication(processIdentifier: pid)?
            .activate(options: []) ?? false
    }

    @discardableResult
    public func toggleMinimize(pid: pid_t, windowNumber: Int?, titleHint: String?) -> Bool {
        guard AXIsProcessTrustedWithOptions(nil) else { return false }
        let appEl = AXUIElementCreateApplication(pid)

        guard let wins = axCopyArray(appEl, kAXWindowsAttribute as CFString) else { return false }
        for case let el as AXUIElement in wins {
            var matched = false

            if let wn = windowNumber,
               let n  = axCopyValue(el, "_AXWindowID" as CFString) as? Int,
               n == wn { matched = true }

            if !matched, let t = titleHint,
               let title = axCopyValue(el, kAXTitleAttribute as CFString) as? String,
               title.hasPrefix(t) { matched = true }

            if !matched { continue }

            let curMin = (axCopyValue(el, kAXMinimizedAttribute as CFString) as? Bool) ?? false
            _ = AXUIElementSetAttributeValue(
                el,
                kAXMinimizedAttribute as CFString,
                curMin ? kCFBooleanFalse : kCFBooleanTrue
            )
            return true
        }
        return false
    }

    private func axCopyValue(_ el: AXUIElement, _ attr: CFString) -> AnyObject? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr, &v)
        return (err == .success && v != nil) ? (v as AnyObject) : nil
    }

    private func axCopyArray(_ el: AXUIElement, _ attr: CFString) -> [AnyObject]? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr, &v)
        return (err == .success && v != nil) ? (v as! [AnyObject]) : nil
    }
}
