import Foundation

/// Bearbeitungs-Rezept für einen Clip: Farblook, Schnitt und Tempo.
struct EditRecipe: Codable, Equatable {
    var name: String
    var exposure: Double      // EV, -2 bis +2
    var contrast: Double      // 0.5 bis 1.6, 1 = neutral
    var saturation: Double    // 0 bis 2, 1 = neutral
    var warmth: Double        // -100 bis +100
    var tint: Double          // -100 bis +100
    var vignette: Double      // 0 bis 1
    var grain: Double         // 0 bis 1
    var sharpen: Double       // 0 bis 1
    var fade: Double          // 0 bis 1
    var blackWhite: Bool
    var trimStart: Double     // Sekunden
    var trimEnd: Double?      // Sekunden, nil = bis zum Ende
    var speed: Double         // 0.25 bis 2
    var note: String?

    init(name: String, exposure: Double = 0, contrast: Double = 1, saturation: Double = 1, warmth: Double = 0,
         tint: Double = 0, vignette: Double = 0, grain: Double = 0, sharpen: Double = 0, fade: Double = 0,
         blackWhite: Bool = false, trimStart: Double = 0, trimEnd: Double? = nil, speed: Double = 1, note: String? = nil) {
        self.name = name
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.tint = tint
        self.vignette = vignette
        self.grain = grain
        self.sharpen = sharpen
        self.fade = fade
        self.blackWhite = blackWhite
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.speed = speed
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case name, exposure, contrast, saturation, warmth, tint, vignette, grain, sharpen, fade
        case blackWhite, trimStart, trimEnd, speed, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys, _ def: Double) -> Double { (try? c.decode(Double.self, forKey: k)) ?? def }
        name = (try? c.decode(String.self, forKey: .name)) ?? "KI-Edit"
        exposure = min(max(d(.exposure, 0), -2), 2)
        contrast = min(max(d(.contrast, 1), 0.5), 1.6)
        saturation = min(max(d(.saturation, 1), 0), 2)
        warmth = min(max(d(.warmth, 0), -100), 100)
        tint = min(max(d(.tint, 0), -100), 100)
        vignette = min(max(d(.vignette, 0), 0), 1)
        grain = min(max(d(.grain, 0), 0), 1)
        sharpen = min(max(d(.sharpen, 0), 0), 1)
        fade = min(max(d(.fade, 0), 0), 1)
        blackWhite = (try? c.decode(Bool.self, forKey: .blackWhite)) ?? false
        trimStart = max(d(.trimStart, 0), 0)
        trimEnd = (try? c.decodeIfPresent(Double.self, forKey: .trimEnd)) ?? nil
        speed = min(max(d(.speed, 1), 0.25), 2)
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }

    /// Gleicher Farblook, aber Schnitt und Tempo zurückgesetzt (zum Speichern als Stil).
    var styleOnly: EditRecipe {
        var r = self
        r.trimStart = 0
        r.trimEnd = nil
        r.speed = 1
        return r
    }

    static let original = EditRecipe(name: "Original")
    static let cinematic = EditRecipe(name: "Cinematic", exposure: -0.1, contrast: 1.15, saturation: 0.85, warmth: 12,
                                      tint: -6, vignette: 0.35, grain: 0.15, sharpen: 0.2, fade: 0.15)
    static let vintage = EditRecipe(name: "Warm Vintage", contrast: 0.92, saturation: 0.8, warmth: 35, tint: 8,
                                    vignette: 0.45, grain: 0.4, fade: 0.45)
    static let noir = EditRecipe(name: "Noir", contrast: 1.35, vignette: 0.55, grain: 0.3, sharpen: 0.3, blackWhite: true)
    static let neon = EditRecipe(name: "Neon Nacht", exposure: 0.2, contrast: 1.2, saturation: 1.35, warmth: -30,
                                 tint: 18, vignette: 0.3, sharpen: 0.2)
    static let clean = EditRecipe(name: "Clean", exposure: 0.1, contrast: 1.05, saturation: 1.08, sharpen: 0.35)
    static let dreamy = EditRecipe(name: "Dreamy", exposure: 0.25, contrast: 0.85, saturation: 0.9, warmth: 15, tint: 10,
                                   vignette: 0.2, fade: 0.5)

    static let builtIn: [EditRecipe] = [.original, .cinematic, .vintage, .noir, .neon, .clean, .dreamy]

    static func match(text: String) -> EditRecipe {
        let t = text.lowercased()
        var r: EditRecipe
        if t.contains("schwarz") || t.contains("noir") || t.contains("black") { r = .noir }
        else if t.contains("vintage") || t.contains("retro") || t.contains("alt") { r = .vintage }
        else if t.contains("neon") || t.contains("nacht") { r = .neon }
        else if t.contains("dream") || t.contains("verträumt") || t.contains("weich") { r = .dreamy }
        else if t.contains("clean") || t.contains("klar") || t.contains("scharf") { r = .clean }
        else { r = .cinematic }
        if t.contains("zeitlupe") || t.contains("slow") { r.speed = 0.5 }
        if t.contains("schneller") || t.contains("fast") { r.speed = 1.5 }
        return r
    }
}

enum EditCode {
    static let prefix = "KIEDIT:"

    static func encode(_ r: EditRecipe) -> String {
        prefix + ((try? JSONEncoder().encode(r)) ?? Data()).base64EncodedString()
    }

    static func decode(_ raw: String) -> EditRecipe? {
        guard let data = PresetCode.jsonData(from: raw, prefix: prefix) else { return nil }
        return try? JSONDecoder().decode(EditRecipe.self, from: data)
    }
}
