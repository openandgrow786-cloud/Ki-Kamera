import Foundation

enum Lens: String, Codable, CaseIterable, Identifiable {
    case front, ultra, wide, wide2x, tele

    var id: String { rawValue }

    var label: String {
        switch self {
        case .front: return "Front"
        case .ultra: return "13 mm"
        case .wide: return "24 mm"
        case .wide2x: return "48 mm"
        case .tele: return "120 mm"
        }
    }

    var longLabel: String { self == .front ? "Frontkamera" : label }
}

/// Ein kompletter Kamera-Look. Kommt von der KI, aus einem Preset-Code oder ist eingebaut.
struct Preset: Codable, Equatable {
    var name: String
    var lens: Lens
    var resolution: String      // "4K" oder "1080p"
    var fps: Double
    var shutter: Double         // Nenner: 96 bedeutet 1/96 s
    var iso: Double?            // nil = Automatik
    var whiteBalance: Double?   // Kelvin, nil = Automatik
    var tint: Double
    var hdr: Bool
    var codec: String           // "hevc" oder "h264"
    var note: String?

    init(name: String, lens: Lens, resolution: String, fps: Double, shutter: Double,
         iso: Double?, whiteBalance: Double?, tint: Double, hdr: Bool, codec: String, note: String? = nil) {
        self.name = name
        self.lens = lens
        self.resolution = resolution
        self.fps = fps
        self.shutter = shutter
        self.iso = iso
        self.whiteBalance = whiteBalance
        self.tint = tint
        self.hdr = hdr
        self.codec = codec
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case name, lens, resolution, fps, shutter, iso, whiteBalance, tint, hdr, codec, note
    }

    // Tolerant lesen: fehlende oder komische Felder bekommen sinnvolle Standardwerte.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "KI-Look"
        let lensText = ((try? c.decode(String.self, forKey: .lens)) ?? "wide").lowercased()
        lens = Lens(rawValue: lensText) ?? .wide
        resolution = (try? c.decode(String.self, forKey: .resolution)) ?? "4K"
        fps = (try? c.decode(Double.self, forKey: .fps)) ?? 30
        shutter = (try? c.decode(Double.self, forKey: .shutter)) ?? fps * 2
        iso = (try? c.decodeIfPresent(Double.self, forKey: .iso)) ?? nil
        whiteBalance = (try? c.decodeIfPresent(Double.self, forKey: .whiteBalance)) ?? nil
        tint = (try? c.decode(Double.self, forKey: .tint)) ?? 0
        hdr = (try? c.decode(Bool.self, forKey: .hdr)) ?? true
        codec = (try? c.decode(String.self, forKey: .codec)) ?? "hevc"
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }

    var fpsText: String {
        abs(fps - fps.rounded()) < 0.001 ? String(Int(fps.rounded())) : String(format: "%.2f", fps)
    }
    var shutterText: String { "1/\(Int(shutter.rounded()))" }
    var isoText: String { iso.map { String(Int($0)) } ?? "Auto" }
    var wbText: String { whiteBalance.map { "\(Int($0))K" } ?? "Auto" }
    var tintText: String { String(Int(tint.rounded())) }
    var resolutionText: String { resolution.lowercased().contains("1080") ? "1080p" : "4K" }
}

extension Preset {
    static let standard = Preset(name: "Standard", lens: .wide, resolution: "4K", fps: 30, shutter: 60,
                                 iso: nil, whiteBalance: nil, tint: 0, hdr: true, codec: "hevc")

    static let referenzClip = Preset(name: "Dein Referenz-Clip", lens: .front, resolution: "4K", fps: 48, shutter: 96,
                                     iso: nil, whiteBalance: 4460, tint: 9, hdr: true, codec: "hevc",
                                     note: "Aus deinem Clip: Frontkamera, 48 fps, 1/96, 4460K, Tint 9.")

    static let kino = Preset(name: "Kino-Look", lens: .wide, resolution: "4K", fps: 24, shutter: 48,
                             iso: nil, whiteBalance: 5000, tint: 0, hdr: true, codec: "hevc")

    static let slowMo = Preset(name: "Slow Motion", lens: .wide, resolution: "4K", fps: 120, shutter: 240,
                               iso: nil, whiteBalance: nil, tint: 0, hdr: true, codec: "hevc")

    static let warm = Preset(name: "Warm & weich", lens: .wide2x, resolution: "4K", fps: 30, shutter: 60,
                             iso: nil, whiteBalance: 4200, tint: 6, hdr: true, codec: "hevc")

    /// Ohne API-Key: Text auf einen eingebauten Look abbilden.
    static func match(text: String) -> Preset {
        let t = text.lowercased()
        if t.contains("slow") || t.contains("zeitlupe") { return .slowMo }
        if t.contains("kino") || t.contains("cine") || t.contains("film") { return .kino }
        if t.contains("warm") || t.contains("weich") { return .warm }
        if t.contains("referenz") || t.contains("mein") || t.contains("blackmagic") { return .referenzClip }
        return .standard
    }
}

/// Preset-Code zum Kopieren zwischen Chat und App: "KIKAM:" + Base64(JSON). Reines JSON geht auch.
enum PresetCode {
    static let prefix = "KIKAM:"

    static func encode(_ p: Preset) -> String {
        let data = (try? JSONEncoder().encode(p)) ?? Data()
        return prefix + data.base64EncodedString()
    }

    static func decode(_ raw: String) -> Preset? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end {
            return try? JSONDecoder().decode(Preset.self, from: Data(s[start...end].utf8))
        }
        if let r = s.range(of: prefix) { s = String(s[r.upperBound...]) }
        var cleaned = s.filter { !$0.isWhitespace }
        while cleaned.count % 4 != 0 { cleaned += "=" }
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return try? JSONDecoder().decode(Preset.self, from: data)
    }
}
