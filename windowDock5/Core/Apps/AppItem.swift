import AppKit

@MainActor
struct AppItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let bundleID: String?

    // wird später befüllt
    var name: String = "(unbekannt)"

    init(url: URL) {
        self.url = url
        self.bundleID = Bundle(url: url)?.bundleIdentifier
    }

    @MainActor
    mutating func loadDisplayName() {
        self.name = AppResolver.displayName(for: url, bundle: Bundle(url: url))
    }

    func icon(size: CGFloat = 32) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.isTemplate = false
        img.size = NSSize(width: size, height: size)
        return img
    }
} 
