import AppKit

final class KeyPanel: NSPanel {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
    // KEIN acceptsFirstMouse hier – das gibt es nur auf NSView.
}
 
