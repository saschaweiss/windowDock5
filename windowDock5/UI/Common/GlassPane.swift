// UI/Common/GlassPane.swift
// Ein Glas-Pane, das alle Maus-/Hover-Events abfängt, wenn active == true.

import SwiftUI
import AppKit

struct GlassPane: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> NSView {
        PaneView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PaneView)?.active = active
        nsView.needsDisplay = true
    }

    final class PaneView: NSView {
        var active: Bool = false
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Wenn aktiv, fange ALLE Events ab (keine Weitergabe an darunterliegende Views)
            return active ? self : nil
        }
    }
}
 
