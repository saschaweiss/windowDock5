// Core/StartMenu/TileItem.swift
import Foundation

// MARK: - TileSize

public enum TileSize: Int, Codable, CaseIterable, Equatable {
    case small = 1
    case large = 2

    public var displayName: String {
        switch self {
        case .small: return "Klein"
        case .large: return "Groß"
        }
    }

    /// Wie viele Grid-Einheiten eine Kachel belegt.
    public var span: Int {
        switch self {
        case .small: return 1
        case .large: return 2
        }
    }
}

// MARK: - TileItem

/// Ein Eintrag im Grid. Große Kacheln (`size == .large`) können als **Container**
/// 0–4 Kinder aufnehmen. Kleine Kacheln (`.small`) sind normale 1×1 Tiles.
public struct TileItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var bundleID: String?
    public var fileURL: URL?
    public var size: TileSize         // 1x1 oder 2x2
    public var children: [UUID]?

    public var isContainer: Bool { children != nil }
 
    public init(
        id: UUID = UUID(),
        title: String,
        bundleID: String? = nil,
        fileURL: URL? = nil,
        size: TileSize = .large,
        children: [UUID]? = nil
    ) {
        self.id = id
        self.title = title
        self.bundleID = bundleID
        self.fileURL = fileURL
        self.size = size
        self.children = children
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, bundleID, fileURL, size, children
    }

    /// Robust gegen ältere gespeicherte Daten (z.B. `size` als String).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        self.id       = try c.decode(UUID.self, forKey: .id)
        self.title    = try c.decode(String.self, forKey: .title)
        self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)

        // fileURL kann als URL oder als String gespeichert worden sein
        if let url = try? c.decode(URL.self, forKey: .fileURL) {
            self.fileURL = url
        } else if let urlStr = try? c.decode(String.self, forKey: .fileURL) {
            self.fileURL = URL(string: urlStr)
        } else {
            self.fileURL = nil
        }

        // size: erst normal, dann Fallbacks (String/Int) für alte Saves
        if let s = try? c.decode(TileSize.self, forKey: .size) {
            self.size = s
        } else if let sStr = try? c.decode(String.self, forKey: .size) {
            switch sStr.lowercased() {
            case "small": self.size = .small
            case "large": self.size = .large
            default:      self.size = .large
            }
        } else if let raw = try? c.decode(Int.self, forKey: .size),
                  let s = TileSize(rawValue: raw) {
            self.size = s
        } else {
            self.size = .large
        }

        self.children = try c.decodeIfPresent([UUID].self, forKey: .children)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(fileURL, forKey: .fileURL)  // URL wird korrekt encodiert
        try c.encode(size, forKey: .size)                 // als RawValue (Int)
        try c.encodeIfPresent(children, forKey: .children)
    }
}
