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

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            if code == 401 { return "Der API-Key stimmt nicht. Prüf ihn in den Einstellungen." }
            return "Claude API Fehler \(code): \(String(body.prefix(200)))"
        case .noPreset:
            return "Die KI hat keinen gültigen Look zurückgegeben. Versuch es nochmal."
        }
    }
}

enum ClaudeService {
    static let systemPrompt = """
    Du bist die Kamera-KI einer iPhone-16-Pro-Max-App. Aus einem Referenzvideo (Einzelbilder und technische Daten) \
    und/oder einer Beschreibung bestimmst du die Kameraeinstellungen, mit denen der Nutzer denselben Look bekommt.

    Antworte NUR mit einem JSON-Objekt, ohne Text davor oder danach:
    {"name": "kurzer Name des Looks", "lens": "front|ultra|wide|wide2x|tele", "resolution": "4K|1080p", \
    "fps": Zahl, "shutter": Nenner der Verschlusszeit (96 heißt 1/96), "iso": null oder Zahl, \
    "whiteBalance": null oder Kelvin, "tint": Zahl, "hdr": true oder false, "codec": "hevc", \
    "note": "ein kurzer Satz auf Deutsch, was du erkannt hast"}

    Regeln:
    - Objektive: front = Selfie-Kamera, ultra = 13 mm Ultraweitwinkel, wide = 24 mm Hauptkamera, wide2x = 48 mm, tele = 120 mm.
    - Person hält das Handy selbst und schaut in die Kamera: front.
    - fps: 24 (Kino), 25, 30, 48, 50, 60, 100 oder 120 (Zeitlupe). Frontkamera in 4K höchstens 60.
    - Verschluss nach der 180-Grad-Regel: shutter = 2 mal fps. Viel Bewegungsunschärfe: kleinerer Nenner. Gestochen scharfe Action: größerer.
    - iso fast immer null (Automatik). Nur eine Zahl, wenn ein bestimmter Look es klar verlangt.
    - whiteBalance aus der Farbstimmung schätzen: warm 3200 bis 4500, neutral 5000 bis 5600, kühl 6000 bis 7500. null nur wenn unklar.
    - Stammen die technischen Daten von einem iPhone oder einer Kamera-App, übernimm Bildrate und Objektiv daraus.
    """

    static func makePreset(apiKey: String, model: String, request: String, reference: ReferenceInfo?) async throws -> Preset {
        var content: [[String: Any]] = []
        for frame in reference?.frames ?? [] {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": frame.base64EncodedString()]
            ])
        }
        var text = ""
        if let r = reference {
            text += "Technische Daten des Referenzvideos:\n\(r.summary)\n\nDie Bilder oben sind Einzelbilder daraus.\n\n"
        }
        let wish = request.trimmingCharacters(in: .whitespacesAndNewlines)
        text += "Wunsch des Nutzers: \(wish.isEmpty ? "Genau so filmen wie im Referenzvideo." : wish)"
        content.append(["type": "text", "text": text])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 800,
            "system": systemPrompt,
            "messages": [["role": "user", "content": content]]
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ClaudeError.http(code, String(data: data, encoding: .utf8) ?? "") }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else { throw ClaudeError.noPreset }
        let reply = blocks.compactMap { $0["text"] as? String }.joined()
        guard let preset = PresetCode.decode(reply) else { throw ClaudeError.noPreset }
        return preset
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
