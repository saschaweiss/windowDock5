import AppKit
import UniformTypeIdentifiers

public typealias ScreenID = String

extension UTType {
    // eigene, reverse-DNS ID wählen – NUR ASCII, keine Leerzeichen!
    static let windowsDockAppIdentifier = UTType(
        exportedAs: "com.saschaweiss.windowDock5.app-identifier",
        conformingTo: .text // damit Text-Fallback logisch ist
    )
}

// Kleiner Helfer, den dein Code schon verwendet:
extension NSScreen {
    /// Stabiler String für den Display-ID (fallback: "primary")
    var wd_displayIDString: String {
        String(NSScreenNumber(self) ?? 0)
    }
    
    /// Stabile numerische Display-ID (CGDirectDisplayID)
    var wd_displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    
    private func NSScreenNumber(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension String {    
    func normalizedForKey() -> String {
        // trim, whitespace komprimieren, unsichtbare Zeichen raus, lowercased
        let s1 = trimmingCharacters(in: .whitespacesAndNewlines)
        let s2 = s1.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let s3 = s2.filter { !$0.isZeroWidth }
        return s3.lowercased()
    }
    func normalizedVisibleTitle() -> String {
        let s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = s.filter { !$0.isZeroWidth }
        if c.isEmpty { return "" }
        // häufige Nicht-Titel abfangen
        if c == "untitled" || c == "unbenannt" || c == "ohne titel" { return "" }
        return c
    }
    func isTriviallyEmptyForKey() -> Bool {
        normalizedForKey().isEmpty
    }
}

extension Character {
    var isZeroWidth: Bool {
        // grobe Filterung typischer unsichtbarer Unicode-Zeichen
        let scalars = String(self).unicodeScalars
        return scalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F: return true
            default: return false
            }
        }
    }
} 

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return sqrt(dx*dx + dy*dy)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var isEmpty: Bool { width == 0 || height == 0 }
    func coarseCenterKey(grid: CGFloat = 10) -> (Int, Int) {
        let cx = Int((midX / grid).rounded(.towardZero))
        let cy = Int((midY / grid).rounded(.towardZero))
        return (cx, cy)
    } 
    
    func distance(to other: CGPoint) -> CGFloat {
        let dx = minX - other.x
        let dy = minY - other.y
        return sqrt(dx*dx + dy*dy)
    }
}
