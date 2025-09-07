import SwiftUI
import AppKit

struct ResizeCornerHandle: View {
    var hitSize: CGFloat = 16
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .leading) {        // ← spacing entfernt
            Color.clear
            Rectangle()
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
        .frame(width: hitSize, height: hitSize)
        .contentShape(Rectangle())

        // Doppelklick: direkt auf dem Main-Thread ausführen
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                StartMenuController.shared.toggleMaximizeOrRestore()
            }
        )
 
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.translation.width
                    let dy = -v.translation.height
                    StartMenuController.shared.userResize(delta: CGSize(width: dx, height: dy))
                }
                .onEnded { _ in
                    StartMenuController.shared.commitResize()
                }
        )
    }

    private func handleDoubleClick() {
        StartMenuController.shared.toggleMaximizeOrRestore()
    }
}
