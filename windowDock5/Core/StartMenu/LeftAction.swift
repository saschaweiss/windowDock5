import Foundation

/// Ein einfacher Action-Typ für die linke Spalte.
struct LeftAction: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var systemImage: String?    // optionales SF Symbol
    var perform: () -> Void     // was beim Klick passieren soll

    init(title: String, systemImage: String? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.perform = perform
    }

    // MARK: - Equatable / Hashable
    static func == (lhs: LeftAction, rhs: LeftAction) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
 
