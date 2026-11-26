import AVFoundation
import Foundation
import Security
import UIKit

// MARK: - Referenzvideo lesen

struct ReferenceInfo {
    var frames: [Data]
    var summary: String
}

enum ReferenceAnalyzer {
    static func load(url: URL) async throws -> ReferenceInfo {
        let asset = AVURLAsset(url: url)
        var lines: [String] = []

        let duration = try await asset.load(.duration)
        lines.append(String(format: "Dauer: %.1f s", duration.seconds))

        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (fps, size, transform) = try await track.load(.nominalFrameRate, .naturalSize, .preferredTransform)
            let r = CGRect(origin: .zero, size: size).applying(transform)
            lines.append("Auflösung: \(Int(abs(r.width)))x\(Int(abs(r.height)))")
            lines.append(String(format: "Bildrate laut Datei: %.2f fps", fps))
            let formats = try await track.load(.formatDescriptions)
            if let fd = formats.first {
                lines.append("Codec: \(fourCC(CMFormatDescriptionGetMediaSubType(fd)))")
                if let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] {
                    if let tf = ext[kCVImageBufferTransferFunctionKey as String] { lines.append("Transferfunktion: \(tf)") }
                    if let cp = ext[kCVImageBufferColorPrimariesKey as String] { lines.append("Farbraum: \(cp)") }
                }
            }
        }

        var meta: [AVMetadataItem] = []
        meta += (try? await asset.load(.commonMetadata)) ?? []
        meta += (try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? []
        for item in meta.prefix(30) {
            let key = item.identifier?.rawValue ?? "?"
            if let value = (try? await item.load(.stringValue)) ?? nil {
                lines.append("\(key): \(value)")
            }
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 768, height: 768)
        var frames: [Data] = []
        let total = max(duration.seconds, 0.1)
        for frac in [0.1, 0.35, 0.6, 0.85] {
            let t = CMTime(seconds: total * frac, preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image,
               let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) {
                frames.append(jpg)
            }
        }
        return ReferenceInfo(frames: frames, summary: lines.joined(separator: "\n"))
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}

// MARK: - Claude API

enum ClaudeError: LocalizedError {
    case http(Int, String)
    case noPreset
    case noKey

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            if code == 401 { return "Der API-Key stimmt nicht. Prüf ihn in den Einstellungen." }
            return "Claude API Fehler \(code): \(String(body.prefix(200)))"
        case .noPreset:
            return "Die KI hat keine gültige Antwort gegeben. Versuch es nochmal."
        case .noKey:
            return "Kein Claude API-Key eingetragen (Zahnrad oben rechts)."
        }
    }
}

enum ClaudeService {
    static let keyName = "claudeApiKey"
    static let modelKey = "claudeModel"
    static let defaultModel = "claude-sonnet-5-5"

    static var apiKey: String { Keychain.get(keyName) ?? "" }
    static var model: String {
        let saved = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return saved.isEmpty ? defaultModel : saved
    }

    static let cameraPrompt = """
    Du bist die Kamera-KI einer iPhone-16-Pro-Max-App im Stil einer Profi-Kamera-App. Aus einem Referenzvideo \
    (Einzelbilder und technische Daten) und/oder einer Anweisung bestimmst du ALLE Kameraeinstellungen.

    Antworte NUR mit einem JSON-Objekt, ohne Text davor oder danach:
    {"name": "kurzer Name des Looks", "lens": "front|ultra|wide|wide2x|tele", "mode": "video|photo", \
    "aspect": "9:16|16:9|1:1|4:5|3:4|2.39", "log": false, \
    "resolution": "4K|1080p", "fps": Zahl, "shutter": Nenner der Verschlusszeit (96 heißt 1/96), \
    "iso": null oder Zahl, "whiteBalance": null oder Kelvin, "tint": Zahl -50 bis 50, \
    "exposureBias": EV -2 bis 2, "zoom": null oder Zoomfaktor des Objektivs, "hdr": true|false, \
    "codec": "hevc|h264", "stabilization": "auto|cinematic|off", "grid": true|false, \
    "countdown": 0|3|5|10, "maxDuration": Sekunden oder 0, "note": "ein kurzer Satz auf Deutsch, was du eingestellt hast"}

    Regeln:
    - Objektive: front = Selfie-Kamera, ultra = 13 mm, wide = 24 mm Hauptkamera, wide2x = 48 mm, tele = 120 mm.
    - Person hält das Handy selbst und schaut in die Kamera: front.
    - aspect = Bildformat des fertigen Videos: 9:16 hochkant (TikTok, Reels, Shorts), 16:9 quer (YouTube), \
    1:1 quadratisch, 4:5 (Instagram-Feed), 3:4, 2.39 (Kino-Breitbild). Beim Referenzvideo das Format übernehmen.
    - fps: 24 (Kino), 25, 30, 48, 50, 60, 100 oder 120 (Zeitlupe). Frontkamera in 4K höchstens 60.
    - Verschluss nach der 180-Grad-Regel: shutter = 2 mal fps. Sport und Action: 250 bis 1000. Nachts darf shutter so klein wie fps sein.
    - iso fast immer null (Automatik). Nur eine Zahl, wenn der Look es klar verlangt.
    - whiteBalance aus der Farbstimmung: warm 3200 bis 4500, neutral 5000 bis 5600, kühl 6000 bis 7500. null wenn unklar.
    - Will der Nutzer nur einzelne Dinge ändern (z. B. "etwas wärmer", "mach 60 fps"), übernimm alle anderen Werte \
    unverändert aus den aktuellen Einstellungen.
    - Stammen die technischen Daten von einem iPhone oder einer Kamera-App, übernimm Bildrate und Objektiv daraus.
    """

    static let editPrompt = """
    Du bist die Schnitt- und Farb-KI einer iPhone-Video-App. Aus Einzelbildern eines Clips und einer Anweisung \
    bestimmst du die Bearbeitung.

    Antworte NUR mit einem JSON-Objekt, ohne Text davor oder danach:
    {"name": "kurzer Name des Looks", "exposure": EV -2 bis 2, "contrast": 0.5 bis 1.6 (1 neutral), \
    "saturation": 0 bis 2 (1 neutral), "warmth": -100 bis 100, "tint": -100 bis 100 (plus = magenta), \
    "vignette": 0 bis 1, "grain": 0 bis 1, "sharpen": 0 bis 1, "fade": 0 bis 1, "blackWhite": true|false, \
    "trimStart": Sekunden, "trimEnd": Sekunden oder null, "speed": 0.25 bis 2, \
    "note": "ein kurzer Satz auf Deutsch, was du gemacht hast"}

    Regeln:
    - Dezent bleiben, außer der Nutzer will etwas Krasses.
    - Kürzen nur, wenn der Nutzer es verlangt. Die Cliplänge steht in den Daten.
    - Zeitlupe: speed 0.5 (bei 60 fps) oder 0.25 (bei 120 fps).
    - Will der Nutzer nur einzelne Dinge ändern, übernimm alle anderen Werte aus der aktuellen Bearbeitung.
    """

    static func makePreset(request: String, current: Preset, reference: ReferenceInfo?) async throws -> Preset {
        let currentJSON = String(data: (try? JSONEncoder().encode(current)) ?? Data(), encoding: .utf8) ?? "{}"
        var text = "Aktuelle Einstellungen: \(currentJSON)\n\n"
        if let r = reference {
            text += "Technische Daten des Referenzvideos:\n\(r.summary)\n\nDie Bilder oben sind Einzelbilder daraus.\n\n"
        }
        let wish = request.trimmingCharacters(in: .whitespacesAndNewlines)
        text += "Anweisung: \(wish.isEmpty ? "Genau so filmen wie im Referenzvideo." : wish)"
        if Prefs.english { text += "\n\nWrite \"name\" and \"note\" in English." }
        let reply = try await send(system: cameraPrompt, frames: reference?.frames ?? [], text: text)
        guard let preset = PresetCode.decode(reply) else { throw ClaudeError.noPreset }
        return preset
    }

    static func makeEdit(request: String, current: EditRecipe, clip: ReferenceInfo) async throws -> EditRecipe {
        let currentJSON = String(data: (try? JSONEncoder().encode(current)) ?? Data(), encoding: .utf8) ?? "{}"
        var text = "Clip-Daten:\n\(clip.summary)\n\nAktuelle Bearbeitung: \(currentJSON)\n\nAnweisung: \(request)"
        if Prefs.english { text += "\n\nWrite \"name\" and \"note\" in English." }
        let reply = try await send(system: editPrompt, frames: clip.frames, text: text)
        guard let recipe = EditCode.decode(reply) else { throw ClaudeError.noPreset }
        return recipe
    }

    static func send(system: String, frames: [Data], text: String) async throws -> String {
        let key = apiKey
        guard !key.isEmpty else { throw ClaudeError.noKey }
        var content: [[String: Any]] = frames.map { frame in
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": frame.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 900,
            "system": system,
            "messages": [["role": "user", "content": content]]
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ClaudeError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else { throw ClaudeError.noPreset }
        return blocks.compactMap { $0["text"] as? String }.joined()
    }
}

// MARK: - API-Key sicher speichern

enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
