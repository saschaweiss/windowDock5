// UI/Taskbar/WindowsStartButtonStyle.swift
// Windows-10-artiger Button: dunkler Hintergrund, Hover/Pressed-Highlight, voller Hit-Bereich.

import SwiftUI
import AppKit   // 👈 wichtig für .cursor

struct WindowsStartButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WindowsStartButtonView(configuration: configuration)
    }
}

private struct WindowsStartButtonView: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed

        return configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // volle Hit-Area
            .contentShape(Rectangle())
            .background(
                ZStack {
                    // Grundfarbe (Taskbar-ähnlich dunkel)
                    Color.black.opacity(0.15)

                    // Hover-Layer
                    Rectangle().fill(Color.white.opacity(hovering ? 0.10 : 0.0))

                    // Pressed-Layer
                    Rectangle().fill(Color.white.opacity(pressed ? 0.18 : 0.0))
                }
            )
            .overlay(
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1),
                alignment: .top
            )
            .onHover { hovering = $0 }
            .hoverCursor(.pointingHand) // 👈 AppKit-Variante
            .animation(Animation.easeInOut(duration: 0.12), value: hovering)
            .animation(Animation.easeInOut(duration: 0.12), value: pressed)
    }
}
