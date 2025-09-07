import SwiftUI

struct LeftColumnView: View {
    enum DisplayMode { case iconsOnly, iconsWithLabels }

    let tileStore: TileStore
    let actions: [LeftAction]
    var displayMode: DisplayMode = .iconsWithLabels   // ⬅️ Default unverändert
    var iconSize: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            
            // "Grid leeren"
            Button {
                tileStore.clearAll()
            } label: {
                
            }
            .buttonStyle(.borderedProminent)
            .padding(2)
            .controlSize(.small)

            Divider()
 
            // Links: Aktionen
            ForEach(actions) { action in
                Button(action: { action.perform() }) {
                    HStack(spacing: 8) {
                        Image(systemName: action.systemImage!)
                            .resizable()
                            .scaledToFit()
                            .frame(width: iconSize, height: iconSize)
                            .foregroundStyle(.primary)

                        if displayMode == .iconsWithLabels {
                            Text(action.title)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.plain)
                .padding(2)
                .contentShape(Rectangle())
                .help(action.title) // Tooltip liefert den Titel auch bei Icons-only
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 0)
        .padding(.vertical, 12)
    }
}
