import SwiftUI
import AppKit

extension View {
    /// Setzt beim Hover einen macOS-Cursor (z.B. .pointingHand)
    func hoverCursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

enum CustomCursors {
    static func diagonalResize() -> NSCursor {
        let base = NSCursor.resizeUpDown.image
        let size = base.size

        let rotated = NSImage(size: size)
        rotated.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let transform = NSAffineTransform()
        transform.translateX(by: size.width / 2, yBy: size.height / 2)
        transform.rotate(byDegrees: 45)
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()

        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        rotated.unlockFocus()

        return NSCursor(image: rotated, hotSpot: NSPoint(x: size.width/2, y: size.height/2))
    }
} 
