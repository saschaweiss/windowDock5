import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TaskbarView: View {
    let screen: NSScreen?
    let barHeight: CGFloat
    
    // Store injizieren (ein Store pro Taskbar-Instanz/Screen)
    @State private var safeScreenID: String = "primary"
    
    var body: some View {
        ZStack {
            // Hintergrund so, wie du ihn willst
            Rectangle().fill(Color.black.opacity(0.95)).ignoresSafeArea()

            HStack(spacing: 0) {
                // START
                if let screen {
                    StartButton(screen: screen, logoSize: 18, width: 56)
                        .frame(width: 56)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                } else {
                    Color.clear.frame(width: 56)
                }

                Divider().opacity(0.15)
                // Spacer zwischen Fenstern und Tray
                Spacer(minLength: 0)

                // --- TRAY / UHR (Platzhalter) --------------------------------
                HStack(spacing: 8) {
                    // TODO: Uhr / Status
                }
                .frame(height: barHeight)
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: barHeight)
    }
}
 
struct TaskbarStripView: View {
    let barHeight: CGFloat
    var body: some View {
        HStack(spacing: 8) {
            StartButtonView()
                .frame(width: 48, height: 48)     // ⬅️ Button-Größe hier steuern
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)            // ⬅️ Leistenhintergrund
    }
}
