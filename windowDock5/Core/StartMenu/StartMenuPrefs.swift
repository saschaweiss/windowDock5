// StartMenuPrefs.swift
import Foundation
import CoreGraphics

/// Benutzerpräferenzen fürs Startmenü.
/// Minimal gehalten – nur das, was das Grid wirklich braucht.
/// Persistiert via UserDefaults.
final class StartMenuPrefs: ObservableObject, Codable, Equatable {

    /// minimaler "Unit"-Kachelrand (Basis für 1×1)
    @Published var gridMinTile: CGFloat = 48

    /// Abstand zwischen Kacheln
    @Published var gridSpacing: CGFloat = 8

    /// maximale Spalten (logisch). 10 fühlt sich wie Windows an.
    @Published var maxColumns: Int = 20

    /// Fenstergröße & -position (optional persistiert)
    @Published var lastFrame: CGRect?

    /// Versionsbump, falls sich künftig Defaults ändern
    var schemaVersion: Int = 1
    
    @Published var menuWidth: CGFloat?      // optional, falls du die Größe persistieren willst
    @Published var menuHeight: CGFloat?
    @Published var taskbarHeight: CGFloat?  // Höhe deiner eigenen Taskbar (für "ankleben")
    @Published var sideInset: CGFloat?      // linker Randabstand

    // MARK: - Persistence
    private static let defaultsKey = "StartMenuPrefs.v1"

    static func load() -> StartMenuPrefs {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(StartMenuPrefs.self, from: data) {
            return decoded
        }
        return StartMenuPrefs()
    }

    func save() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(self) {
            ud.set(data, forKey: Self.defaultsKey)
        } 
    }

    // MARK: - Codable
    private enum CodingKeys: String, CodingKey {
        case gridMinTile, gridSpacing, maxColumns, lastFrame, schemaVersion
        case menuWidth, menuHeight, taskbarHeight, sideInset
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gridMinTile   = try c.decode(CGFloat.self, forKey: .gridMinTile)
        gridSpacing   = try c.decode(CGFloat.self, forKey: .gridSpacing)
        maxColumns    = try c.decode(Int.self,    forKey: .maxColumns)
        lastFrame     = try c.decodeIfPresent(CGRect.self, forKey: .lastFrame)
        schemaVersion = try c.decode(Int.self,    forKey: .schemaVersion)
        menuWidth     = try c.decodeIfPresent(CGFloat.self, forKey: .menuWidth)
        menuHeight    = try c.decodeIfPresent(CGFloat.self, forKey: .menuHeight)
        taskbarHeight = try c.decodeIfPresent(CGFloat.self, forKey: .taskbarHeight)
        sideInset     = try c.decodeIfPresent(CGFloat.self, forKey: .sideInset)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gridMinTile, forKey: .gridMinTile)
        try c.encode(gridSpacing, forKey: .gridSpacing)
        try c.encode(maxColumns,  forKey: .maxColumns)
        try c.encodeIfPresent(lastFrame, forKey: .lastFrame)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(menuWidth,  forKey: .menuWidth)
        try c.encodeIfPresent(menuHeight, forKey: .menuHeight)
        try c.encodeIfPresent(taskbarHeight, forKey: .taskbarHeight)
        try c.encodeIfPresent(sideInset, forKey: .sideInset)
    }

    // MARK: - Initializer
    init() {}

    // MARK: - Equatable
    static func == (lhs: StartMenuPrefs, rhs: StartMenuPrefs) -> Bool {
        lhs.gridMinTile == rhs.gridMinTile &&
        lhs.gridSpacing == rhs.gridSpacing &&
        lhs.maxColumns == rhs.maxColumns &&
        lhs.lastFrame == rhs.lastFrame &&
        lhs.schemaVersion == rhs.schemaVersion
    }
}
