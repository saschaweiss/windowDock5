import AppKit

@MainActor
final class AppScanner: ObservableObject {
    static let shared = AppScanner()

    @Published private(set) var apps: [AppItem] = []
    private var isScanning = false

    private init() {}

    /// Startet (idempotent) einen Async-Scan. Ergebnisse kommen inkrementell rein.
    func scanAsync() {
        guard !isScanning else { return }
        isScanning = true
        apps.removeAll(keepingCapacity: true) 

        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            var batch: [AppItem] = []
            let fm = FileManager.default

            for dir in roots {
                guard let items = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .localizedNameKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for url in items where url.pathExtension == "app" {
                    let item = await MainActor.run { () -> AppItem in
                        var it = AppItem(url: url)
                        it.loadDisplayName()   // <- hier wirklich aufrufen
                        return it
                    }  // <- nur die URL übergeben
                    batch.append(item)

                    if batch.count % 20 == 0 {
                        let push = batch
                        batch.removeAll(keepingCapacity: true)
                        await MainActor.run {
                            self.apps.append(contentsOf: push)
                            self.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        }
                    }
                }
            }

            // Rest flushen
            if !batch.isEmpty {
                let push = batch
                await MainActor.run {
                    self.apps.append(contentsOf: push)
                    self.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            }

            await MainActor.run { self.isScanning = false }
        }
    }
}

// MARK: - Name-Resolver (robust, ohne ".app"-Fehler)
private extension AppScanner {
    func resolveDisplayName(for url: URL, bundle: Bundle?) -> String {
        // 1) Lokalisierten Finder-Namen bevorzugen
        if let values = try? url.resourceValues(forKeys: [.localizedNameKey]),
           let loc = values.localizedName, !loc.isEmpty {
            return stripAppSuffix(loc)
        }
        // 2) CFBundleDisplayName / CFBundleName
        if let s = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stripAppSuffix(s)
        }
        if let s = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stripAppSuffix(s)
        }
        // 3) Dateiname ohne .app
        let last = url.deletingPathExtension().lastPathComponent
        let cleaned = stripAppSuffix(last)
        return cleaned.isEmpty ? last : cleaned
    }

    func stripAppSuffix(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasSuffix(".app") else { return trimmed }
        return String(trimmed.dropLast(4))
    }
}

extension AppScanner {
    func scanSync() {
        apps.removeAll(keepingCapacity: true)

        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        let fm = FileManager.default
        var result: [AppItem] = []

        for dir in roots {
            if let items = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: [.isDirectoryKey, .localizedNameKey],
                                                       options: [.skipsHiddenFiles]) {
                for url in items where url.pathExtension == "app" {
                    result.append(AppItem(url: url))
                }
            }
        }

        // Finder-artige Sortierung
        apps = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
