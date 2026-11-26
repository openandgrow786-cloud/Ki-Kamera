import Foundation
import UIKit

/// Ein erkanntes Wort mit Zeit im Originalclip (Sekunden).
struct Word: Codable, Equatable {
    var w: String
    var start: Double
    var end: Double
}

/// Ein Stück, das rausgeschnitten wird (Versprecher, Retake usw.). Zeiten im Originalclip.
struct CutRange: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var why: String
    var text: String
    var enabled = true
}

/// Eine Grafik-Einblendung (Motion Graphic). Zeiten im Originalclip.
struct Beat: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var kind: String          // "title", "keyword", "list", "number", "lowerThird", "quote"
    var title: String
    var subtitle: String?
    var items: [String]?
    var number: Double?
    var unit: String?
    var enabled = true

    enum CodingKeys: String, CodingKey { case id, start, end, kind, title, subtitle, items, number, unit, enabled }

    init(start: Double, end: Double, kind: String, title: String, subtitle: String? = nil,
         items: [String]? = nil, number: Double? = nil, unit: String? = nil) {
        self.start = start
        self.end = end
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.number = number
        self.unit = unit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        start = (try? c.decode(Double.self, forKey: .start)) ?? 0
        end = (try? c.decode(Double.self, forKey: .end)) ?? start + 3
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "keyword"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? nil
        items = (try? c.decodeIfPresent([String].self, forKey: .items)) ?? nil
        number = (try? c.decodeIfPresent(Double.self, forKey: .number)) ?? nil
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? nil
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        if end <= start { end = start + 3 }
    }
}

/// Alles, was der KI-Editor mit einem Clip macht.
struct EditProject: Codable, Equatable {
    var recipe = EditRecipe.original
    var language = Prefs.english ? "en" : "de"
    var cutSilences = true
    var pause = 0.3                 // 0.3 natürlich, 0.15 knackig
    var cutMistakes = true
    var captions = false
    var captionSize = 1.0           // 0.7 bis 1.6
    var style = "warm-canvas"       // oder "none"
    var amount = "light"            // "light" oder "medium"
    var sfx = true
    var words: [Word] = []
    var silences: [[Double]] = []   // erkannte Pausen [start, end]
    var cuts: [CutRange] = []
    var beats: [Beat] = []
    var analyzed = false
}

/// Die 7 Grafik-Stile aus dem Editor-Skill, fürs iPhone übersetzt.
struct GraphicStyle: Identifiable {
    let id: String
    let name: String
    let blurbDE: String
    let blurbEN: String
    let card: UIColor
    let ink: UIColor
    let accent: UIColor
    let titleFont: String
    let bodyFont: String
    let uppercase: Bool
    let radius: CGFloat
    let centered: Bool        // Kinetic: mittig; sonst Karte unten links
    let captionInk: UIColor
    let captionHighlight: UIColor

    var blurb: String { L(blurbDE, blurbEN) }

    static let all: [GraphicStyle] = [
        GraphicStyle(id: "warm-canvas", name: "Warm Canvas",
                     blurbDE: "Ruhig und edel: Serifen-Untertitel, weiße Karten. Bester Standard für Talking Heads.",
                     blurbEN: "Calm and editorial: serif captions, white cards. Best default for talking heads.",
                     card: UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 0.97), ink: UIColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
                     accent: UIColor(red: 0.27, green: 0.55, blue: 0.86, alpha: 1), titleFont: "Georgia-Bold", bodyFont: "Georgia",
                     uppercase: false, radius: 26, centered: false,
                     captionInk: .white, captionHighlight: UIColor(red: 0.55, green: 0.78, blue: 1, alpha: 1)),
        GraphicStyle(id: "creator-motion-graphics", name: "Creator Motion Graphics",
                     blurbDE: "Laut und schnell: riesige Großbuchstaben, Gelb als Akzent, dunkel.",
                     blurbEN: "Punchy kinetic type: huge caps, yellow accent, dark.",
                     card: UIColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 0.88), ink: .white,
                     accent: UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1), titleFont: "AvenirNextCondensed-Heavy", bodyFont: "AvenirNextCondensed-DemiBold",
                     uppercase: true, radius: 8, centered: true,
                     captionInk: .white, captionHighlight: UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1)),
        GraphicStyle(id: "clean-tech", name: "Clean Tech",
                     blurbDE: "Hell und klar: weiße UI-Karten, ein elektrisches Blau. Für Tech-Themen.",
                     blurbEN: "Bright and crisp: white UI cards, one electric blue. For tech topics.",
                     card: UIColor(white: 1, alpha: 0.96), ink: UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1),
                     accent: UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1), titleFont: "AvenirNext-Bold", bodyFont: "AvenirNext-Medium",
                     uppercase: false, radius: 20, centered: false,
                     captionInk: .white, captionHighlight: UIColor(red: 0.45, green: 0.65, blue: 1, alpha: 1)),
        GraphicStyle(id: "software-walkthrough", name: "Software Walkthrough",
                     blurbDE: "App-Fenster mit Schritt-Nummern. Für Tutorials.",
                     blurbEN: "App window with numbered steps. For tutorials.",
                     card: UIColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 0.96), ink: UIColor(white: 0.95, alpha: 1),
                     accent: UIColor(red: 0.98, green: 0.8, blue: 0.2, alpha: 1), titleFont: "AvenirNext-DemiBold", bodyFont: "Menlo-Regular",
                     uppercase: false, radius: 14, centered: false,
                     captionInk: .white, captionHighlight: UIColor(red: 0.98, green: 0.8, blue: 0.2, alpha: 1)),
        GraphicStyle(id: "data-story", name: "Data Story",
                     blurbDE: "Zahlen zählen hoch, dunkle Tinte, warme Akzente. Für Zahlen und Trends.",
                     blurbEN: "Numbers count up, deep ink, warm accents. For numbers and trends.",
                     card: UIColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 0.93), ink: UIColor(white: 0.96, alpha: 1),
                     accent: UIColor(red: 1, green: 0.47, blue: 0.4, alpha: 1), titleFont: "AvenirNext-Heavy", bodyFont: "Menlo-Bold",
                     uppercase: false, radius: 16, centered: true,
                     captionInk: .white, captionHighlight: UIColor(red: 0.37, green: 0.85, blue: 0.8, alpha: 1)),
        GraphicStyle(id: "chalk-talk", name: "Chalk Talk",
                     blurbDE: "Grüne Tafel, Kreideschrift. Zum Erklären von Ideen.",
                     blurbEN: "Green slate, chalk lettering. For explaining ideas.",
                     card: UIColor(red: 0.13, green: 0.25, blue: 0.19, alpha: 0.96), ink: UIColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1),
                     accent: UIColor(red: 0.98, green: 0.62, blue: 0.75, alpha: 1), titleFont: "ChalkboardSE-Bold", bodyFont: "ChalkboardSE-Regular",
                     uppercase: false, radius: 10, centered: false,
                     captionInk: UIColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1), captionHighlight: UIColor(red: 0.98, green: 0.88, blue: 0.5, alpha: 1)),
        GraphicStyle(id: "pop-info", name: "Pop Info",
                     blurbDE: "Flache, bunte Infografik mit runden Formen und Sprechblasen.",
                     blurbEN: "Flat, colorful infographic with round shapes and bubbles.",
                     card: UIColor(red: 0.2, green: 0.65, blue: 0.64, alpha: 0.97), ink: .white,
                     accent: UIColor(red: 1, green: 0.84, blue: 0.4, alpha: 1), titleFont: "AvenirNext-Heavy", bodyFont: "AvenirNext-DemiBold",
                     uppercase: false, radius: 34, centered: true,
                     captionInk: .white, captionHighlight: UIColor(red: 1, green: 0.84, blue: 0.4, alpha: 1))
    ]

    static func named(_ id: String) -> GraphicStyle? { all.first { $0.id == id } }
}
