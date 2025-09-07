import SwiftUI
import AppKit

struct StartButton: View {
    let screen: NSScreen
    var logoSize: CGFloat = 18
    var horizontalPadding: CGFloat = 10
    var width: CGFloat = 56
    @State private var hostingWindow: NSWindow?

    var body: some View {
        Button {
            if let screen = hostingWindow?.screen {
                StartMenuController.shared.toggle(on: screen)
            } else {
                let mouse = NSEvent.mouseLocation
                StartMenuController.shared.present(at: mouse)
            } 
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.6))          // leicht heller als Taskbar
                WindowsLogo(size: logoSize)
                    .frame(width: logoSize, height: logoSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .buttonStyle(WindowsStartButtonStyle())
        .withHostingWindow { win in
            self.hostingWindow = win
        }
    }
}

extension View {
    func withHostingWindow(_ callback: @escaping (NSWindow?) -> Void) -> some View {
        background(
            WindowAccessor(callback: callback)
        )
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        DispatchQueue.main.async {
            callback(nsView.window)
        }
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
