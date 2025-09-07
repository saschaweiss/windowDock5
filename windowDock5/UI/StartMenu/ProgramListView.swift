import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProgramListView: View {
    @StateObject private var scanner = AppScanner.shared
    @Binding var query: String
    @Binding var selectedIndex: Int

    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?

    private var filteredApps: [AppItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return scanner.apps }
        return scanner.apps.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: NICHT überlagert, steht physisch vor der Liste
            FocusableSearchField("Programme durchsuchen", text: $query) { launchSelected() }
                .textFieldStyle(.plain)
                .controlSize(.large)
                .frame(height: 34)
                .padding(.horizontal, 0)
                .padding(.vertical, 0)
                .focused($searchFocused)                    // 👈 neu: bindet den Fokus an unser State
                .onTapGesture { searchFocused = true }

            Divider()
                .padding(.vertical, 0)
                .padding(.horizontal, 0)
                .allowsHitTesting(false)

            // Inhalt: normale ScrollView – keine Overlays, keine zIndex-Tricks
            ScrollViewReader { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredApps.enumerated()), id: \.offset) { idx, app in
                            appRow(app: app, selected: idx == selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { launch(appURL: app.url) }
                                .onHover { inside in if inside { selectedIndex = idx } }
                                .onDrag { dragItemProvider(for: app) } preview: {
                                    let img = app.icon(size: 64)
                                    Image(nsImage: img)
                                        .interpolation(.high)
                                        .resizable()
                                        .frame(width: 64, height: 64)
                                        .cornerRadius(12)
                                        .shadow(radius: 8)
                                        .padding(2)
                                        .background(Color.clear)
                                }
                        }
                    }
                    .padding(.top, 4)
                }
                .contentMargins(0)
                .onHover { inside in
                    if !inside { selectedIndex = -1 }
                }
            } 
        }
        .frame(minWidth: 220)
        .padding(.top, 0)
        .padding(.horizontal, 0)
        .contentMargins(0)
        .onAppear {
            selectedIndex = -1
            DispatchQueue.main.async { searchFocused = true }
            installKeyMonitor()
            if scanner.apps.isEmpty {
                scanner.scanSync()
                scanner.scanAsync()
            }
        }
        .onDisappear {
            selectedIndex = -1
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }   // 👈 sauber abbauen
            keyMonitor = nil
        }
    }
    
    private func installKeyMonitor() {
        // Doppelt installieren vermeiden
        if keyMonitor != nil { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            // Modifier/Steuer-Tasten durchreichen:
            if ev.modifierFlags.contains(.command) ||
               ev.modifierFlags.contains(.control) ||
               ev.modifierFlags.contains(.option) {
                return ev
            }

            // Navigationstasten nicht fressen:
            switch ev.keyCode {
            case 123,124,125,126: // ← → ↓ ↑
                return ev
            default: break
            }

            // Wenn gerade nicht das Suchfeld fokussiert ist:
            if !searchFocused {
                searchFocused = true
            }

            // Text erzeugende Tasten abfangen und in query schreiben
            if let chars = ev.charactersIgnoringModifiers, !chars.isEmpty {
                switch ev.keyCode {
                case 51: // Backspace
                    if !query.isEmpty { query.removeLast() }
                    return nil
                case 36: // Return
                    launchSelected()
                    return nil
                case 53: // Escape
                    // optional: Startmenü schließen oder Query leeren
                    // StartMenuController.shared.hide()
                    return nil
                default:
                    query.append(contentsOf: chars)
                    return nil   // Event verbrauchen, wir haben's schon verarbeitet
                }
            }

            return ev
        }
    }

    // MARK: - Row
    @ViewBuilder
    func appRow(app: AppItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon(size: 24))
                .interpolation(.high)
            Text(displayName(for: app))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
    }

    // MARK: - Drag
    private func dragItemProvider(for app: AppItem) -> NSItemProvider {
        let utid = UTType.windowsDockAppIdentifier.identifier
        let provider = NSItemProvider()
        let name = displayName(for: app)
        provider.suggestedName = name

        // JSON-Payload
        let payload: [String: Any] = [
            "bundleID": app.bundleID as Any,
            "path": app.url.path,
            "name": name
        ]
        let jsonData   = try? JSONSerialization.data(withJSONObject: payload, options: [])

        // 1) CUSTOM-UTI: Data-Representation (primär)
        if let data = jsonData {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.windowsDockAppIdentifier.identifier,
                visibility: .all
            ) { completion in
                print("📤 Providing custom UTI DATA (\(data.count) bytes)")
                completion(data, nil)
                return nil
            }
        }

        // 2) (Optional) Fallback als Data/String nochmal registrieren
        let jsonString = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        provider.registerItem(forTypeIdentifier: UTType.windowsDockAppIdentifier.identifier) { completion, _, _ in
            completion?(jsonString.data(using: .utf8)! as NSData, nil)   // ✅ jetzt DATA, nicht NSString
        }

        // 3) TEXT-Fallback (bundleID oder Pfad)
        let fallback = app.bundleID ?? app.url.path
        provider.registerItem(forTypeIdentifier: UTType.plainText.identifier) { completion, _, _ in
            print("📤 Providing TEXT fallback: \(fallback)")
            completion?(fallback as NSString, nil)    // ✅ optional
        }

        // Debug: was tatsächlich registriert wurde
        let regs = provider.registeredTypeIdentifiers
        print("📦 registered types:", regs)
        print("🔎 has custom UTI:", provider.hasItemConformingToTypeIdentifier(utid))

        return provider
    }

    // MARK: - Actions
    private func launchSelected() {
        guard filteredApps.indices.contains(selectedIndex) else { return }
        launch(appURL: filteredApps[selectedIndex].url)
    }

    private func launch(appURL: URL) {
        _ = LaunchService.shared.launch(appURL: appURL)
        Task { @MainActor in
            selectedIndex = -1                 // 👈 Selektion sofort löschen
            StartMenuController.shared.hide()
        }
    }
    
    private func displayName(for app: AppItem) -> String {
        let raw = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fälle wie "", "unbekannt", "(unbekannt)" abfangen
        if raw.isEmpty || raw.lowercased() == "unbekannt" || raw.lowercased() == "(unbekannt)" {
            return app.url.deletingPathExtension().lastPathComponent
        }
        return raw
    }
}

// Dezenter Hover-Hintergrund (ohne Außenabstand)
private struct HoverBackground: View {
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.secondary.opacity(0.1) : .clear)
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.15)) { hovering = inside }
            }
            .padding(0)
    }
}
