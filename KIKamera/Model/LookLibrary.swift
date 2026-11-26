import Foundation

struct SavedLook: Codable, Identifiable, Equatable {
    var id = UUID()
    var preset: Preset
    var created = Date()
}

struct SavedStyle: Codable, Identifiable, Equatable {
    var id = UUID()
    var recipe: EditRecipe
    var created = Date()
}

/// Deine gespeicherten Kamera-Looks (z. B. "Nachtmodus") und Bearbeitungs-Stile. Bleiben auf dem iPhone gespeichert.
final class LookLibrary: ObservableObject {
    @Published private(set) var looks: [SavedLook] = []
    @Published private(set) var styles: [SavedStyle] = []

    private struct Store: Codable {
        var looks: [SavedLook]
        var styles: [SavedStyle]
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(Store.self, from: data) {
            looks = store.looks
            styles = store.styles
        }
    }

    private func persist() {
        let store = Store(looks: looks, styles: styles)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Kamera-Looks

    func save(_ preset: Preset, as name: String) {
        var p = preset
        p.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? preset.name : name
        if let i = looks.firstIndex(where: { $0.preset.name.lowercased() == p.name.lowercased() }) {
            looks[i].preset = p
        } else {
            looks.insert(SavedLook(preset: p), at: 0)
        }
        persist()
    }

    func rename(_ look: SavedLook, to name: String) {
        guard let i = looks.firstIndex(where: { $0.id == look.id }), !name.isEmpty else { return }
        looks[i].preset.name = name
        persist()
    }

    func delete(_ look: SavedLook) {
        looks.removeAll { $0.id == look.id }
        persist()
    }

    // MARK: Bearbeitungs-Stile

    func save(_ recipe: EditRecipe, as name: String) {
        var r = recipe.styleOnly
        r.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? recipe.name : name
        if let i = styles.firstIndex(where: { $0.recipe.name.lowercased() == r.name.lowercased() }) {
            styles[i].recipe = r
        } else {
            styles.insert(SavedStyle(recipe: r), at: 0)
        }
        persist()
    }

    func delete(_ style: SavedStyle) {
        styles.removeAll { $0.id == style.id }
        persist()
    }
}
