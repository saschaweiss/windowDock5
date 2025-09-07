import SwiftUI

struct SettingsView: View {
    var body: some View {
        // Platzhalter – Inhalte definieren wir später
        VStack(alignment: .leading, spacing: 16) {
            Text("Einstellungen")
                .font(.title2)
                .bold()

            Text("Hier kommen später die Optionen für Taskleiste und Startmenü hin.")
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 360) // angenehme Default-Größe
    }
}

// Optional: Preview für schnelle Iteration
#Preview {
    SettingsView()
}
 
