import Foundation
import CoreGraphics
import Darwin // dlopen/dlsym

enum SLS {
    // Load the private framework lazily at runtime (opt out of actor-safety)
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    // C signatures of the functions we need
    typealias SLSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
    typealias SLSCopyAllWindowsFn          = @convention(c) (Int32) -> CFArray?
    typealias SLSCopyWindowsWithOptsFn     = @convention(c) (Int32, UInt32) -> CFArray?   // fallback name/shape on some OSes
    typealias SLSCopySpacesForWindowsFn    = @convention(c) (Int32, UInt32, CFArray) -> CFArray?
    typealias SLSGetWindowBoundsFn         = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    typealias SLSWindowIsOnscreenFn        = @convention(c) (Int32, UInt32) -> Bool
    typealias SLSGetWindowOwnerFn          = @convention(c) (Int32, UInt32) -> Int32
    typealias CGSDefaultConnectionFn       = @convention(c) () -> Int32

    // MARK: - Symbol lookup (non-fatal, tries alternatives)

    nonisolated(unsafe) private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let s = dlsym(h, name) else { return nil }
        return unsafeBitCast(s, to: type)
    } 

    nonisolated(unsafe) private static func anySym<T>(_ names: [String], _ type: T.Type) -> T? {
        for n in names {
            if let f: T = sym(n, type) { return f }
        }
        return nil
    }

    // Resolved function pointers (optional – may be nil on some systems)
    nonisolated(unsafe) private static let _SLSCopyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFn? =
        anySym(["SLSCopyManagedDisplaySpaces"], SLSCopyManagedDisplaySpacesFn.self)

    // window listing: try a few variants; some OSes only expose SLSCopyWindowsWithOptions
    nonisolated(unsafe) private static let _SLSCopyAllWindows: SLSCopyAllWindowsFn? =
        anySym(["SLSCopyAllWindows"], SLSCopyAllWindowsFn.self)
    nonisolated(unsafe) private static let _SLSCopyWindowsWithOptions: SLSCopyWindowsWithOptsFn? =
        anySym(["SLSCopyWindowsWithOptions", "SLSCopyWindows"], SLSCopyWindowsWithOptsFn.self)

    nonisolated(unsafe) private static let _SLSCopySpacesForWindows: SLSCopySpacesForWindowsFn? =
        anySym(["SLSCopySpacesForWindows"], SLSCopySpacesForWindowsFn.self)
    nonisolated(unsafe) private static let _SLSGetWindowBounds: SLSGetWindowBoundsFn? =
        anySym(["SLSGetWindowBounds"], SLSGetWindowBoundsFn.self)
    nonisolated(unsafe) private static let _SLSWindowIsOnscreen: SLSWindowIsOnscreenFn? =
        anySym(["SLSWindowIsOnscreen"], SLSWindowIsOnscreenFn.self)
    nonisolated(unsafe) private static let _SLSGetWindowOwner: SLSGetWindowOwnerFn? =
        anySym(["SLSGetWindowOwner"], SLSGetWindowOwnerFn.self)
    nonisolated(unsafe) private static let _CGSDefaultConnection: CGSDefaultConnectionFn? =
        anySym(["_CGSDefaultConnection"], CGSDefaultConnectionFn.self)

    nonisolated(unsafe) static let cid: Int32 = _CGSDefaultConnection?() ?? 0

    struct DisplaySpaces {
        let displayUUID: String
        let spaceIDs: [UInt64]
    }

    // MARK: Managed display spaces
    static func managedDisplaySpaces() -> [DisplaySpaces] {
        guard let f = _SLSCopyManagedDisplaySpaces,
              let arr = f(cid) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let uuid = d["Display Identifier"] as? String,
                  let spaces = d["Spaces"] as? [[String: Any]] else { return nil }
            let ids: [UInt64] = spaces.compactMap { $0["id64"] as? UInt64 }
            return DisplaySpaces(displayUUID: uuid, spaceIDs: ids)
        }
    }

    // MARK: Windows → ids / bounds / owner / onscreen
    /// Safe list of *all* WindowIDs. Falls back to CoreGraphics if SkyLight symbol is missing.
    static func allWindows() -> [UInt32] {
        if let f = _SLSCopyAllWindows, let a = f(cid) as? [NSNumber] {
            return a.map { $0.uint32Value }
        }
        if let g = _SLSCopyWindowsWithOptions, let a = g(cid, 0x7 /* all kinds */) as? [NSNumber] {
            return a.map { $0.uint32Value }
        }
        // Fallback: CG – not perfect for spaces/minimized, but avoids crashes
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { dict in
            if let n = dict[kCGWindowNumber as String] as? NSNumber { return n.uint32Value }
            if let n = dict[kCGWindowNumber as String] as? Int { return UInt32(n) }
            return nil
        }
    }

    static func spacesFor(wids: [UInt32]) -> [UInt32: [UInt64]] {
        guard let f = _SLSCopySpacesForWindows, !wids.isEmpty else { return [:] }
        let cf = (wids.map { NSNumber(value: $0) } as NSArray) as CFArray
        guard let anyArr = f(cid, 0x7, cf) else { return [:] }

        var out: [UInt32: [UInt64]] = [:]
        let count = CFArrayGetCount(anyArr)
        for i in 0..<count {
            let wid = wids[i]
            let any = unsafeBitCast(CFArrayGetValueAtIndex(anyArr, i), to: AnyObject.self)
            if let n = any as? NSNumber {
                let v = n.uint64Value
                if v != 0 { out[wid] = [v] }
            } else if let arr = any as? [NSNumber] {
                out[wid] = arr.map { $0.uint64Value }
            }
        }
        return out
    }

    static func bounds(for wid: UInt32) -> CGRect? {
        guard let f = _SLSGetWindowBounds else { return nil }
        var r = CGRect.null
        return f(cid, wid, &r) == 0 ? r : nil
    }

    static func isOnscreen(_ wid: UInt32) -> Bool {
        guard let f = _SLSWindowIsOnscreen else { return true } // assume true if missing
        return f(cid, wid)
    }

    static func ownerPID(for wid: UInt32) -> pid_t? {
        guard let f = _SLSGetWindowOwner else { return nil }
        let val = f(cid, wid)
        // sanity guard: SkyLight ABI differs across builds; ignore nonsense
        if val <= 0 || val > 1_000_000 { return nil }
        return pid_t(val)
    }

    /// Aktive Space-IDs (pro Display) als Set.
    static func activeSpaces() -> Set<UInt64> {
        var out = Set<UInt64>()
        // -> C-Funktion über unseren gelösten Zeiger aufrufen (braucht cid)
        guard let f = _SLSCopyManagedDisplaySpaces,
              let arr = f(cid) as? [[String: Any]] else {
            return out
        }

        for dsp in arr {
            // macOS 14/15: "Current Space"
            if let cur = dsp["Current Space"] as? [String: Any],
               let sid = (cur["id64"] as? UInt64) ?? (cur["ManagedSpaceID"] as? UInt64) {
                out.insert(sid)
                continue
            }
            // ältere Builds: "CurrentSpace"
            if let cur = dsp["CurrentSpace"] as? [String: Any],
               let sid = (cur["id64"] as? UInt64) ?? (cur["ManagedSpaceID"] as? UInt64) {
                out.insert(sid)
            }
        }
        return out
    }
}
