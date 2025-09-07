// UI/Taskbar/WindowsLogo.swift
import SwiftUI

struct WindowsLogo: View {
    var size: CGFloat = 18
    var color: Color = .white.opacity(0.92)

    var body: some View {
        // vier Kacheln mit definierter Lücke – komplett innerhalb der gewünschten Größe
        let gap  = size * 0.18
        let tile = (size - gap) / 2
 
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                Rectangle().fill(color).frame(width: tile, height: tile)
                Rectangle().fill(color).frame(width: tile, height: tile)
            }
            HStack(spacing: gap) {
                Rectangle().fill(color).frame(width: tile, height: tile)
                Rectangle().fill(color).frame(width: tile, height: tile)
            }
        }
        .frame(width: size, height: size, alignment: .center) // ← zentriert
        .accessibilityHidden(true)
    }
}
