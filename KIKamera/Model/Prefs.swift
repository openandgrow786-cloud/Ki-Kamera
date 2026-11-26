import Foundation

/// Text in der gewählten App-Sprache (Deutsch / English).
func L(_ de: String, _ en: String) -> String {
    Prefs.english ? en : de
}

/// Alle App-Einstellungen. Gespeichert in UserDefaults, damit sie nach einem Neustart erhalten bleiben.
enum Prefs {
    private static var d: UserDefaults { .standard }

    private static func bool(_ key: String, _ def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }
    private static func string(_ key: String, _ def: String) -> String {
        d.string(forKey: key) ?? def
    }
    private static func double(_ key: String, _ def: Double) -> Double {
        d.object(forKey: key) == nil ? def : d.double(forKey: key)
    }

    // Sprache
    static var language: String { string("lang", Locale.current.language.languageCode?.identifier == "de" ? "de" : "en") }
    static var english: Bool { language == "en" }

    // Aufnahme
    static var recFade: String { string("recFade", "transparent") }
    static var dimWhileRecording: Bool { bool("dimWhileRecording", false) }
    static var volumeTrigger: Bool { bool("volumeTrigger", true) }
    static var lockWBOnRecord: Bool { bool("lockWBOnRecord", true) }
    static var timecodeMode: String { string("timecodeMode", "run") }

    // Kamera
    static var lockOrientation: Bool { bool("lockOrientation", false) }
    static var mirrorFront: Bool { bool("mirrorFront", true) }
    static var shutterDisplay: String { string("shutterDisplay", "speed") }
    static var flicker: String { string("flicker", "50") }
    static var lensCorrection: Bool { bool("lensCorrection", true) }

    // Medien
    static var album: Bool { bool("album", true) }

    // Audio
    static var audioFormat: String { string("audioFormat", "aac") }
    static var stereo: Bool { bool("stereo", true) }
    static var windFilter: Bool { bool("windFilter", true) }
    static var meterScale: String { string("meterScale", "vu") }

    // Monitoring
    static var showMeters: Bool { bool("showMeters", true) }
    static var showBattery: Bool { bool("showBattery", true) }
    static var showStorage: Bool { bool("showStorage", true) }
    static var gridOpacity: Double { double("gridOpacity", 0.25) }
    static var frameOpacity: Double { double("frameOpacity", 0.6) }
    static var frameColor: String { string("frameColor", "gold") }

    static let allKeys = ["recFade", "dimWhileRecording", "volumeTrigger", "lockWBOnRecord", "timecodeMode",
                          "lockOrientation", "mirrorFront", "shutterDisplay", "flicker", "lensCorrection", "album",
                          "audioFormat", "stereo", "windFilter", "meterScale", "showMeters", "showBattery",
                          "showStorage", "gridOpacity", "frameOpacity", "frameColor"]

    static func reset() {
        allKeys.forEach { d.removeObject(forKey: $0) }
    }

    /// Verschlusszeit flimmerfrei machen (bei 50 Hz Netzstrom Vielfache von 50, bei 60 Hz von 60).
    static func flickerSafe(_ shutter: Double, fps: Double) -> Double {
        let base: Double
        switch flicker {
        case "50": base = 50
        case "60": base = 60
        default: return shutter
        }
        var best = shutter, bestDiff = Double.infinity
        for k in 1...40 {
            let candidate = base * Double(k)
            guard candidate >= fps else { continue }   // Verschluss darf nicht länger als ein Bild sein
            let diff = abs(log(candidate / shutter))
            if diff < bestDiff { bestDiff = diff; best = candidate }
        }
        return best
    }

    /// Verschluss als Zeit (1/96) oder Winkel (180°).
    static func shutterText(_ shutter: Double, fps: Double) -> String {
        if shutterDisplay == "angle" {
            let angle = 360 * fps / max(shutter, 1)
            return String(format: "%.0f°", angle)
        }
        return "1/\(Int(shutter.rounded()))"
    }
}
