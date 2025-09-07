// UI/Taskbar/StartButtonView.swift
import SwiftUI
import AppKit

struct StartButtonView: View {
    var screen: NSScreen?

    var body: some View {
        Button {
            let hosting = NSApplication.shared.keyWindow?.contentView
            StartMenuController.shared.toggle(at: hosting)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.3x3.fill")
                Text("Start")
                    .font(.system(size: 12, weight: .semibold))
            }
        } 
        .buttonStyle(.plain)
        .frame(height: 56) // Taskbar-Höhe
        .contentShape(Rectangle())
    }

    private func currentMouseScreen() -> NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
    }
}
