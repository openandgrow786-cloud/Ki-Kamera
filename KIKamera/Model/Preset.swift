import Foundation

enum Lens: String, Codable, CaseIterable, Identifiable {
    case front, ultra, wide, wide2x, tele

    var id: String { rawValue }

    var label: String {
        switch self {
        case .front: return "Front"
        case .ultra: return "0,5×"
        case .wide: return "1×"
        case .wide2x: return "2×"
        case .tele: return "5×"
        }
    }

    var focal: String {
        switch self {
        case .front: return "Frontkamera"
        case .ultra: return "13 mm"
        case .wide: return "24 mm"
        case .wide2x: return "48 mm"
        case .tele: return "120 mm"
        }
    }

    var defaultZoom: Double { self == .wide2x ? 2 : 1 }
}

/// Ein kompletter Kamera-Look. Kommt von der KI, aus einem Preset-Code, aus der Bibliothek oder ist eingebaut.
struct Preset: Codable, Equatable {
    var name: String
    var lens: Lens
    var mode: String            // "video" oder "photo"
    var resolution: String      // "4K" oder "1080p"
    var fps: Double
    var shutter: Double         // Nenner: 96 bedeutet 1/96 s
    var iso: Double?            // nil = Automatik
    var whiteBalance: Double?   // Kelvin, nil = Automatik
    var tint: Double
    var exposureBias: Double    // EV, -2 bis +2
    var zoom: Double?           // nil = Standard des Objektivs
    var hdr: Bool
    var codec: String           // "hevc" oder "h264"
    var stabilization: String   // "auto", "cinematic", "off"
    var grid: Bool
    var countdown: Int          // Sekunden vor der Aufnahme
    var maxDuration: Int        // 0 = unbegrenzt
    var note: String?

    init(name: String, lens: Lens = .wide, mode: String = "video", resolution: String = "4K",
         fps: Double = 30, shutter: Double = 60, iso: Double? = nil, whiteBalance: Double? = nil,
         tint: Double = 0, exposureBias: Double = 0, zoom: Double? = nil, hdr: Bool = true,
         codec: String = "hevc", stabilization: String = "auto", grid: Bool = true,
         countdown: Int = 0, maxDuration: Int = 0, note: String? = nil) {
        self.name = name
        self.lens = lens
        self.mode = mode
        self.resolution = resolution
        self.fps = fps
        self.shutter = shutter
        self.iso = iso
        self.whiteBalance = whiteBalance
        self.tint = tint
        self.exposureBias = exposureBias
        self.zoom = zoom
        self.hdr = hdr
        self.codec = codec
        self.stabilization = stabilization
        self.grid = grid
        self.countdown = countdown
        self.maxDuration = maxDuration
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case name, lens, mode, resolution, fps, shutter, iso, whiteBalance, tint, exposureBias, zoom
        case hdr, codec, stabilization, grid, countdown, maxDuration, note
    }

    // Tolerant lesen: fehlende oder komische Felder bekommen sinnvolle Standardwerte.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "KI-Look"
        lens = Lens(rawValue: ((try? c.decode(String.self, forKey: .lens)) ?? "wide").lowercased()) ?? .wide
        mode = ((try? c.decode(String.self, forKey: .mode)) ?? "video").lowercased() == "photo" ? "photo" : "video"
        resolution = (try? c.decode(String.self, forKey: .resolution)) ?? "4K"
        fps = (try? c.decode(Double.self, forKey: .fps)) ?? 30
        shutter = (try? c.decode(Double.self, forKey: .shutter)) ?? fps * 2
        iso = (try? c.decodeIfPresent(Double.self, forKey: .iso)) ?? nil
        whiteBalance = (try? c.decodeIfPresent(Double.self, forKey: .whiteBalance)) ?? nil
        tint = (try? c.decode(Double.self, forKey: .tint)) ?? 0
        exposureBias = (try? c.decode(Double.self, forKey: .exposureBias)) ?? 0
        zoom = (try? c.decodeIfPresent(Double.self, forKey: .zoom)) ?? nil
        hdr = (try? c.decode(Bool.self, forKey: .hdr)) ?? true
        codec = (try? c.decode(String.self, forKey: .codec)) ?? "hevc"
        stabilization = (try? c.decode(String.self, forKey: .stabilization)) ?? "auto"
        grid = (try? c.decode(Bool.self, forKey: .grid)) ?? true
        countdown = (try? c.decode(Int.self, forKey: .countdown)) ?? 0
        maxDuration = (try? c.decode(Int.self, forKey: .maxDuration)) ?? 0
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }

    var isPhoto: Bool { mode == "photo" }
    var fpsText: String {
        abs(fps - fps.rounded()) < 0.001 ? String(Int(fps.rounded())) : String(format: "%.2f", fps)
    }
    var shutterText: String { "1/\(Int(shutter.rounded()))" }
    var isoText: String { iso.map { String(Int($0)) } ?? "Auto" }
    var wbText: String { whiteBalance.map { "\(Int($0))K" } ?? "Auto" }
    var tintText: String { String(Int(tint.rounded())) }
    var evText: String { exposureBias == 0 ? "±0" : String(format: "%+.1f", exposureBias) }
    var resolutionText: String { resolution.lowercased().contains("1080") ? "1080p" : "4K" }
    var effectiveZoom: Double { zoom ?? lens.defaultZoom }
    var summary: String {
        "\(lens.focal) · \(isPhoto ? "Foto" : "\(resolutionText) \(fpsText)p") · \(shutterText) · \(wbText)"
    }

    /// Ob für den Wechsel von `old` zu diesem Look die Kamera komplett neu aufgebaut werden muss.
    func needsReconfigure(from old: Preset?) -> Bool {
        guard let old else { return true }
        return old.lens != lens || old.mode != mode || old.resolution != resolution || abs(old.fps - fps) > 0.01
            || old.hdr != hdr || old.codec != codec || old.stabilization != stabilization
    }
}

extension Preset {
    static let standard = Preset(name: "Standard")

    static let referenzClip = Preset(name: "Dein Referenz-Clip", lens: .front, fps: 48, shutter: 96,
                                     whiteBalance: 4460, tint: 9,
                                     note: "Aus deinem Clip: Frontkamera, 48 fps, 1/96, 4460K, Tint 9.")

    static let kino = Preset(name: "Kino 24", fps: 24, shutter: 48, whiteBalance: 5000, stabilization: "cinematic",
                             note: "Klassischer Film-Look mit natürlicher Bewegungsunschärfe.")

    static let nacht = Preset(name: "Nachtmodus", fps: 24, shutter: 30, whiteBalance: 4000, exposureBias: 0.3,
                              stabilization: "cinematic",
                              note: "Längere Belichtung und warmes Licht für dunkle Umgebungen.")

    static let slowMo = Preset(name: "Slow Motion", fps: 120, shutter: 240,
                               note: "120 fps, später auf Zeitlupe verlangsamen.")

    static let sport = Preset(name: "Action", fps: 60, shutter: 500, stabilization: "cinematic",
                              note: "Kurzer Verschluss für gestochen scharfe Bewegung.")

    static let vlog = Preset(name: "Vlog Selfie", lens: .front, fps: 30, shutter: 60,
                             note: "Frontkamera, natürliche Farben.")

    static let produkt = Preset(name: "Produkt", lens: .wide2x, fps: 30, shutter: 60, whiteBalance: 5600,
                                note: "48 mm, neutrales Licht, wenig Verzerrung.")

    static let warm = Preset(name: "Golden Hour", lens: .wide2x, fps: 30, shutter: 60, whiteBalance: 4200, tint: 6,
                             note: "Warme, weiche Stimmung.")

    static let portraitFoto = Preset(name: "Porträt-Foto", lens: .tele, mode: "photo", fps: 30, shutter: 125,
                                     note: "Tele, Fotomodus.")

    static let builtIn: [Preset] = [.standard, .referenzClip, .kino, .nacht, .slowMo, .sport, .vlog, .produkt, .warm, .portraitFoto]

    /// Ohne API-Key: Text auf einen eingebauten Look abbilden.
    static func match(text: String) -> Preset {
        let t = text.lowercased()
        if t.contains("nacht") || t.contains("night") || t.contains("dunkel") { return .nacht }
        if t.contains("slow") || t.contains("zeitlupe") { return .slowMo }
        if t.contains("kino") || t.contains("cine") || t.contains("film") { return .kino }
        if t.contains("sport") || t.contains("action") || t.contains("schnell") { return .sport }
        if t.contains("selfie") || t.contains("vlog") || t.contains("front") { return .vlog }
        if t.contains("produkt") || t.contains("shop") { return .produkt }
        if t.contains("foto") || t.contains("porträt") || t.contains("portrait") { return .portraitFoto }
        if t.contains("warm") || t.contains("golden") || t.contains("weich") { return .warm }
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
        guard let data = jsonData(from: raw, prefix: prefix) else { return nil }
        return try? JSONDecoder().decode(Preset.self, from: data)
    }

    /// Holt JSON aus einem Text: direktes JSON, oder Base64 nach einem Präfix.
    static func jsonData(from raw: String, prefix: String) -> Data? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end {
            return Data(s[start...end].utf8)
        }
        if let r = s.range(of: prefix) { s = String(s[r.upperBound...]) }
        var cleaned = s.filter { !$0.isWhitespace }
        while cleaned.count % 4 != 0 { cleaned += "=" }
        return Data(base64Encoded: cleaned)
    }
}
