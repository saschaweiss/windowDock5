import AppKit
import Foundation

@MainActor
final class AppResolver {
    static let shared = AppResolver()
    private init() {}

    // Caches
    private let iconCache = NSCache<NSString, NSImage>()
    private var nameToBundle: [String: String] = [:]   // "Safari" -> "com.apple.Safari"
    private var bundleToURL: [String: URL] = [:]
    private var urlToBundle: [URL: String] = [:]

    // MARK: - Bundle-ID ↔︎ URL

    func bundleID(forAppURL url: URL) -> String? {
        if let hit = urlToBundle[url] { return hit }

        if let bid = Bundle(url: url)?.bundleIdentifier {
            urlToBundle[url] = bid
            bundleToURL[bid] = url
            return bid
        }
        return nil
    }
 
    func url(forBundleID id: String) -> URL? {
        if let hit = bundleToURL[id] { return hit }

        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            bundleToURL[id] = u
            urlToBundle[u] = id
            return u
        }
        return nil
    }
    
    func findAppURL(byName name: String) -> URL? {
        // schneller Cache-Hit?
        if let hit = bundleToURL.first(where: { $0.value.lastPathComponent == "\(name).app" })?.value {
            return hit
        }

        // einfache Heuristik: /Applications & ~/Applications
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/\(name).app"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/\(name).app")
        ]

        for url in candidates where fm.fileExists(atPath: url.path) {
            if let bid = Bundle(url: url)?.bundleIdentifier {
                bundleToURL[bid] = url
                urlToBundle[url] = bid
            }
            return url
        }

        // Fallback: Workspace fragt nach *irgendeiner* App mit diesem Namen (langsamer, optional)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
            ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/\(name).app")) {
            let bid = Bundle(url: url)?.bundleIdentifier
            bundleToURL[bid ?? ""] = url
            urlToBundle[url] = bid
            return url
        }
        return nil
    }

    // MARK: - Display-Name
    static func displayName(for url: URL, bundle: Bundle? = nil) -> String {
        if let res = try? url.resourceValues(forKeys: [.localizedNameKey]),
           let ln = res.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ln.isEmpty { return stripAppSuffix(ln) }

        if let b = bundle ?? Bundle(url: url) {
            if let s = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return stripAppSuffix(s) }
            if let s = (b.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return stripAppSuffix(s) }
        }

        let finder = FileManager.default.displayName(atPath: url.path)
        let cleaned = stripAppSuffix(finder).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? url.deletingPathExtension().lastPathComponent : cleaned
    }
    
    func name(forBundleID id: String) -> String? {
        guard let u = url(forBundleID: id) else { return nil }
        return AppResolver.displayName(for: u)
    }
    
    static func name(forBundleID id: String) -> String? {
        shared.name(forBundleID: id)
    }

    private static func stripAppSuffix(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(".app") else { return trimmed }
        return (trimmed as NSString).deletingPathExtension
    }

    // MARK: - Icons

    func icon(forBundleID bid: String, size: CGFloat) -> NSImage? {
        if let url = AppResolver.shared.url(forBundleID: bid) {
            return icon(forFileURL: url, size: size)
        }
        return nil
    }

    func icon(forFileURL fileURL: URL, size: CGFloat) -> NSImage? {
        let key = ("file:\(fileURL.path):\(Int(size))") as NSString
        if let cached = iconCache.object(forKey: key) { return cached }

        let img = NSWorkspace.shared.icon(forFile: fileURL.path)
        img.isTemplate = false
        img.size = NSSize(width: size, height: size)

        iconCache.setObject(img, forKey: key)
        return img
    }

    // MARK: - Helpers

    private func candidates(for name: String) -> [String] {
        let n = name.lowercased()
        switch n {
        case "safari": return ["com.apple.Safari"]
        case "mail", "apple mail": return ["com.apple.mail"]
        case "finder": return ["com.apple.finder"]
        case "terminal": return ["com.apple.Terminal"]
        case "musik", "music", "apple music": return ["com.apple.Music"]
        case "fotos", "photos": return ["com.apple.Photos"]
        case "notizen", "notes": return ["com.apple.Notes"]
        case "xcode": return ["com.apple.dt.Xcode"]
        case "einstellungen", "systemeinstellungen", "system settings", "systemeinst.":
            return ["com.apple.systempreferences"]
        default:
            let studly = name.replacingOccurrences(of: " ", with: "")
            return ["com.apple.\(studly)", "com.\(studly).app"]
        }
    }

    private func searchApplicationsFolderForExactName(_ name: String) -> URL? {
        let fm = FileManager.default
        let dirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true)
        ]
        for dir in dirs where (try? dir.checkResourceIsReachable()) == true {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in items where url.pathExtension == "app" {
                    let base = url.deletingPathExtension().lastPathComponent
                    if base.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                        return url
                    }
                }
            }
        }
        return nil
    }
}

@MainActor
extension AppResolver {
    func icon(forBundleID bundleID: String) -> NSImage? {
        icon(forBundleID: bundleID, size: 22)
    }

    /// convenience: akzeptiert CGSize und mapped auf die größere Kante
    func icon(forBundleID bundleID: String, size: CGSize) -> NSImage? {
        icon(forBundleID: bundleID, size: max(size.width, size.height))
    }
}
