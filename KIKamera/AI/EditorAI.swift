import Foundation

/// Antwort des KI-Editors im Chat.
struct EditorReply {
    var text: String
    var options: [String] = []
    var replan = false
}

/// Der KI-Editor: findet Versprecher, plant Grafiken, chattet. Arbeitet wie der Editor-Skill.
/// Mit Claude API-Key denkt Claude mit, ohne Key greifen einfache Regeln.
enum EditorAI {
    static var online: Bool { !ClaudeService.apiKey.isEmpty }

    // MARK: Transkript als Text (wie im Skill: [start-end] wA-wB: Text, Pausen dazwischen)

    static func transcriptLines(_ words: [Word], include: (Int) -> Bool = { _ in true }) -> String {
        var lines: [String] = []
        var cur: [Int] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            let text = cur.map { words[$0].w }.joined(separator: " ")
            lines.append(String(format: "[%.2f-%.2f] w%d-w%d: %@", words[f].start, words[l].end, f, l, text))
            cur = []
        }
        var prevEnd: Double?
        for i in words.indices where include(i) {
            if let p = prevEnd, words[i].start - p > 0.5 {
                flush()
                lines.append(String(format: "(pause %.1fs)", words[i].start - p))
            }
            cur.append(i)
            prevEnd = words[i].end
            if cur.count >= 14 || words[i].w.hasSuffix(".") || words[i].w.hasSuffix("?") || words[i].w.hasSuffix("!") { flush() }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Wortbereich → Schnitt in Sekunden: vom Ende des vorigen behaltenen Wortes bis kurz vor das nächste.
    static func cut(words: [Word], from: Int, to: Int, why: String) -> CutRange? {
        guard !words.isEmpty, from <= to, from >= 0, to < words.count else { return nil }
        let start = from > 0 ? words[from - 1].end + 0.02 : max(words[from].start - 0.05, 0)
        let end = to + 1 < words.count ? words[to + 1].start - 0.02 : words[to].end + 0.1
        guard end > start else { return nil }
        let text = words[from...to].map(\.w).joined(separator: " ")
        return CutRange(start: start, end: end, why: why, text: text)
    }

    // MARK: Versprecher finden

    static let mistakeRules = """
    Du bist ein Video-Cutter. Finde im Transkript eines Talking-Head-Videos die Fehler, die raus sollen:
    - Retakes: derselbe Satz (oder sein Anfang) zwei- oder mehrmals gesagt. Behalte den LETZTEN vollständigen Take, \\
    entferne die früheren Versuche komplett, inklusive halber Wörter.
    - Fehlstarts: eine Phrase bricht mitten im Gedanken ab und beginnt neu. Entferne den abgebrochenen Teil.
    - Ausdrückliche Wiederholungs-Hinweise: "nochmal", "noch mal", "warte", "sorry", "let me say that again", "cut that", \\
    "one more time", "wait". Entferne den Hinweis und den Take, auf den er sich bezieht.
    - Füllsel am Anfang/Ende: "okay, läuft", "is this on", ein auslaufendes "und, ähm, ja".
    - Einzelne "ähm"/"äh" im Satz klingen natürlich: nur Häufungen oder lange entfernen.
    Entferne NIE Inhalt, nur weil er locker formuliert ist, und stelle nie Sätze um.
    Jede Zeile ist eine Phrase: [start-end] wA-wB: Text, mit (pause Ns) dazwischen. wA/wB sind Wort-Indizes.
    Antworte NUR mit JSON: {"remove": [{"from": Wortindex, "to": Wortindex, "why": "kurzer Grund"}]}
    Wenn nichts raus muss: {"remove": []}
    """

    static func findMistakes(words: [Word]) async -> [CutRange] {
        guard !words.isEmpty else { return [] }
        if online {
            var text = "Transkript:\n" + transcriptLines(words)
            if Prefs.english { text += "\n\nWrite each \"why\" in English." } else { text += "\n\nSchreibe jedes \"why\" auf Deutsch." }
            if let reply = try? await ClaudeService.send(system: mistakeRules, frames: [], text: text),
               let data = PresetCode.jsonData(from: reply, prefix: "~"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["remove"] as? [[String: Any]] {
                return list.compactMap { item in
                    guard let f = item["from"] as? Int, let t = item["to"] as? Int else { return nil }
                    return cut(words: words, from: f, to: t, why: item["why"] as? String ?? "")
                }
            }
        }
        return heuristicMistakes(words: words)
    }

    /// Ohne KI: doppelte Satzanfänge und Wiederholungs-Hinweise.
    static func heuristicMistakes(words: [Word]) -> [CutRange] {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let n = words.map { norm($0.w) }
        var cuts: [CutRange] = []
        var i = 0
        while i + 3 < n.count {
            let gram = n[i..<(i + 3)].joined(separator: " ")
            var found: Int?
            var j = i + 3
            while j + 3 <= n.count && j <= i + 40 {
                if n[j..<(j + 3)].joined(separator: " ") == gram { found = j; break }
                j += 1
            }
            if let j = found, let c = cut(words: words, from: i, to: j - 1, why: L("Retake (früherer Versuch)", "Retake (earlier attempt)")) {
                cuts.append(c)
                i = j
            } else {
                i += 1
            }
        }
        let cues = ["nochmal", "noch mal", "warte", "sorry", "again", "wait", "redo"]
        for (k, w) in n.enumerated() where cues.contains(w) || (k + 1 < n.count && cues.contains(w + " " + n[k + 1])) {
            var s = k
            while s > 0 && k - s < 15 && words[s].start - words[s - 1].end < 0.5 { s -= 1 }
            if !cuts.contains(where: { $0.start <= words[k].start && $0.end >= words[k].end }),
               let c = cut(words: words, from: s, to: min(k + (n[k] == "noch" ? 1 : 0), words.count - 1), why: L("Wiederholungs-Hinweis", "Redo cue")) {
                cuts.append(c)
            }
        }
        return cuts.sorted { $0.start < $1.start }
    }

    // MARK: Grafiken planen

    static func beatRules(style: GraphicStyle, amount: String) -> String {
        """
        Du planst Motion Graphics für ein Talking-Head-Video im Stil "\(style.name)": \(style.blurbDE)
        Wähle die Momente, in denen eine Grafik die Idee klarer macht: eine Aufzählung, eine Zahl, ein Vergleich, \\
        ein Ablauf, ein Schlüsselbegriff, ein Vorher/Nachher, ein genanntes Tool. Persönliche und emotionale Sätze \\
        bleiben ohne Grafik. Menge: \(amount == "medium" ? "etwa eine Grafik alle 15 bis 30 Sekunden" : "etwa eine Grafik alle 30 bis 60 Sekunden, mindestens eine Titel-Grafik am Anfang").
        Arten: "title" (Überschrift, optional subtitle), "keyword" (ein Begriff, 1 bis 3 Wörter), \\
        "list" (title + items, 2 bis 4 kurze Punkte), "number" (number als Zahl, unit wie "%" oder "€", title als Beschriftung), \\
        "lowerThird" (Name/Thema + subtitle), "quote" (kurzes Zitat + subtitle als Quelle).
        Texte kurz: Titel höchstens 6 Wörter, Punkte höchstens 4 Wörter. Benutze die echten Worte und Zahlen aus dem Transkript.
        start/end in Sekunden des Transkripts (die Zeitstempel in eckigen Klammern), 2 bis 6 Sekunden pro Grafik.
        Antworte NUR mit JSON: {"beats": [{"start": 1.2, "end": 4.0, "kind": "title", "title": "...", "subtitle": "...", \\
        "items": ["..."], "number": 42, "unit": "%"}]}
        """
    }

    static func planBeats(_ p: EditProject, timeline: Timeline) async -> [Beat] {
        guard let style = GraphicStyle.named(p.style), !p.words.isEmpty else { return [] }
        if online {
            let kept = transcriptLines(p.words) { timeline.outTime(p.words[$0].start) != nil }
            var text = "Transkript (nur die behaltenen Teile):\n" + kept
            text += Prefs.english || p.language == "en" ? "\n\nWrite all on-screen text in English." : "\n\nSchreibe alle Texte auf Deutsch."
            if let reply = try? await ClaudeService.send(system: beatRules(style: style, amount: p.amount), frames: [], text: text),
               let data = PresetCode.jsonData(from: reply, prefix: "~"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["beats"],
               let listData = try? JSONSerialization.data(withJSONObject: list),
               let beats = try? JSONDecoder().decode([Beat].self, from: listData) {
                return beats.sorted { $0.start < $1.start }
            }
        }
        return heuristicBeats(p, timeline: timeline)
    }

    /// Ohne KI: Titel am Anfang, Zahlen als Zähler.
    static func heuristicBeats(_ p: EditProject, timeline: Timeline) -> [Beat] {
        let kept = p.words.filter { timeline.outTime($0.start) != nil }
        guard let first = kept.first else { return [] }
        var beats: [Beat] = []
        var titleWords: [Word] = []
        for w in kept {
            titleWords.append(w)
            if titleWords.count >= 6 || w.w.hasSuffix(".") || w.w.hasSuffix("?") || w.w.hasSuffix("!") { break }
        }
        let title = titleWords.map(\.w).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        beats.append(Beat(start: first.start, end: (titleWords.last?.end ?? first.end) + 1.5, kind: "title", title: title))
        let gap = p.amount == "medium" ? 15.0 : 30.0
        var last = first.start
        for (i, w) in kept.enumerated() {
            let digits = w.w.filter { $0.isNumber || $0 == "," || $0 == "." }
            guard let value = Double(digits.replacingOccurrences(of: ",", with: ".")), value >= 2, w.start - last >= gap else { continue }
            let unit = w.w.contains("%") ? "%" : (w.w.contains("€") ? "€" : nil)
            let label = kept[(i + 1)..<min(i + 4, kept.count)].map(\.w).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            beats.append(Beat(start: w.start, end: w.end + 3, kind: "number", title: label, number: value, unit: unit))
            last = w.start
        }
        return beats
    }

    // MARK: Chat

    static let chatRules = """
    Du bist der KI-Editor im Studio einer iPhone-Kamera-App und bearbeitest gerade einen Clip mit dem Nutzer. \\
    Du denkst wie ein erfahrener Video-Editor: stellst gezielte Rückfragen, wenn etwas unklar ist, schlägst Verbesserungen vor \\
    und setzt Wünsche direkt um. Antworte kurz und locker.
    Du bekommst den aktuellen Projektstand als JSON und den Verlauf. Antworte NUR mit JSON:
    {"reply": "deine Antwort an den Nutzer", "options": ["bis zu 4 kurze Antwort-Vorschläge"], "changes": {...}}
    Mögliche Felder in changes (nur was sich ändert):
    "cutSilences": bool, "pause": 0.15 oder 0.3, "cutMistakes": bool, "captions": bool, "captionSize": 0.7 bis 1.6,
    "style": "none|warm-canvas|creator-motion-graphics|clean-tech|software-walkthrough|data-story|chalk-talk|pop-info",
    "amount": "light|medium", "sfx": bool, "replanGraphics": bool (Grafiken neu planen),
    "removeBeats": [Index], "addBeats": [{"start","end","kind","title","subtitle","items","number","unit"}] (Zeiten im Original),
    "enableCuts": [Index], "disableCuts": [Index],
    "look": "Original|Cinematic|Warm Vintage|Noir|Neon Night|Clean|Dreamy",
    "recipe": {"exposure","contrast","saturation","warmth","tint","vignette","grain","sharpen","fade","blackWhite"},
    "trimStart": Sekunden, "trimEnd": Sekunden, "speed": 0.25 bis 2
    """

    static func projectSummary(_ p: EditProject, timeline: Timeline) -> String {
        let beats = p.beats.enumerated().map { i, b in
            "\(i): \(b.kind) \"\(b.title)\" \(String(format: "%.1f-%.1f s", b.start, b.end))\(b.enabled ? "" : " (aus)")"
        }.joined(separator: "\n")
        let cuts = p.cuts.enumerated().map { i, c in
            "\(i): \(String(format: "%.1f-%.1f s", c.start, c.end)) \(c.why): \"\(c.text)\"\(c.enabled ? "" : " (aus)")"
        }.joined(separator: "\n")
        let recipe = String(data: (try? JSONEncoder().encode(p.recipe)) ?? Data(), encoding: .utf8) ?? "{}"
        return """
        Länge fertig: \(String(format: "%.1f", timeline.duration)) s, Schnittstücke: \(timeline.segments.count)
        Pausen schneiden: \(p.cutSilences) (Pause \(p.pause) s), Fehler schneiden: \(p.cutMistakes), Untertitel: \(p.captions) (Größe \(p.captionSize))
        Stil: \(p.style), Menge: \(p.amount), Sounds: \(p.sfx)
        Farbe/Schnitt: \(recipe)
        Grafiken:
        \(beats.isEmpty ? "keine" : beats)
        Fehler-Schnitte:
        \(cuts.isEmpty ? "keine" : cuts)
        Transkript (Auszug):
        \(String(transcriptLines(p.words).prefix(6000)))
        """
    }

    static func chat(history: [(Bool, String)], project p: inout EditProject, timeline: Timeline) async -> EditorReply {
        guard let last = history.last?.1 else { return EditorReply(text: "") }
        if online {
            let convo = history.suffix(12).map { ($0.0 ? "Nutzer: " : "Editor: ") + $0.1 }.joined(separator: "\n")
            var text = "Projekt:\n\(projectSummary(p, timeline: timeline))\n\nVerlauf:\n\(convo)"
            text += Prefs.english ? "\n\nReply in English." : "\n\nAntworte auf Deutsch."
            if let reply = try? await ClaudeService.send(system: chatRules, frames: [], text: text),
               let data = PresetCode.jsonData(from: reply, prefix: "~"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var out = EditorReply(text: json["reply"] as? String ?? "", options: json["options"] as? [String] ?? [])
                if let ch = json["changes"] as? [String: Any] { out.replan = apply(ch, to: &p) }
                return out
            }
        }
        return offlineChat(last, project: &p)
    }

    /// Änderungen aus der KI-Antwort übernehmen. Gibt zurück, ob die Grafiken neu geplant werden sollen.
    static func apply(_ ch: [String: Any], to p: inout EditProject) -> Bool {
        if let v = ch["cutSilences"] as? Bool { p.cutSilences = v }
        if let v = ch["pause"] as? Double { p.pause = min(max(v, 0.1), 0.6) }
        if let v = ch["cutMistakes"] as? Bool { p.cutMistakes = v }
        if let v = ch["captions"] as? Bool { p.captions = v }
        if let v = ch["captionSize"] as? Double { p.captionSize = min(max(v, 0.7), 1.6) }
        if let v = ch["style"] as? String, v == "none" || GraphicStyle.named(v) != nil { p.style = v }
        if let v = ch["amount"] as? String { p.amount = v == "medium" ? "medium" : "light" }
        if let v = ch["sfx"] as? Bool { p.sfx = v }
        if let v = ch["enableCuts"] as? [Int] { for i in v where p.cuts.indices.contains(i) { p.cuts[i].enabled = true } }
        if let v = ch["disableCuts"] as? [Int] { for i in v where p.cuts.indices.contains(i) { p.cuts[i].enabled = false } }
        if let v = ch["removeBeats"] as? [Int] { for i in v.sorted(by: >) where p.beats.indices.contains(i) { p.beats.remove(at: i) } }
        if let v = ch["addBeats"], let d = try? JSONSerialization.data(withJSONObject: v),
           let new = try? JSONDecoder().decode([Beat].self, from: d) {
            p.beats = (p.beats + new).sorted { $0.start < $1.start }
        }
        if let v = ch["look"] as? String, let r = EditRecipe.builtIn.first(where: { $0.name.lowercased() == v.lowercased() }) {
            var nr = r
            nr.trimStart = p.recipe.trimStart
            nr.trimEnd = p.recipe.trimEnd
            nr.speed = p.recipe.speed
            p.recipe = nr
        }
        if let v = ch["recipe"] as? [String: Any] {
            var current = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(p.recipe))) as? [String: Any] ?? [:]
            for (k, val) in v { current[k] = val }
            if let d = try? JSONSerialization.data(withJSONObject: current), let r = try? JSONDecoder().decode(EditRecipe.self, from: d) {
                p.recipe = r
            }
        }
        if let v = ch["trimStart"] as? Double { p.recipe.trimStart = max(v, 0) }
        if let v = ch["trimEnd"] as? Double { p.recipe.trimEnd = v }
        if let v = ch["speed"] as? Double { p.recipe.speed = min(max(v, 0.25), 2) }
        return (ch["replanGraphics"] as? Bool) ?? false || ch["style"] != nil || ch["amount"] != nil
    }

    static func offlineChat(_ msg: String, project p: inout EditProject) -> EditorReply {
        let t = msg.lowercased()
        var done: [String] = []
        var replan = false
        if t.contains("untertitel") || t.contains("caption") || t.contains("subtitle") {
            if t.contains("größer") || t.contains("bigger") || t.contains("larger") { p.captions = true; p.captionSize = min(p.captionSize + 0.2, 1.6); done.append(L("Untertitel größer", "Captions bigger")) }
            else if t.contains("kleiner") || t.contains("smaller") { p.captionSize = max(p.captionSize - 0.2, 0.7); done.append(L("Untertitel kleiner", "Captions smaller")) }
            else if t.contains("aus") || t.contains("off") || t.contains("keine") || t.contains("no ") { p.captions = false; done.append(L("Untertitel aus", "Captions off")) }
            else { p.captions = true; done.append(L("Untertitel an", "Captions on")) }
        }
        if t.contains("knackig") || t.contains("schneller") || t.contains("tight") { p.cutSilences = true; p.pause = 0.15; done.append(L("Pausen knackig", "Tight pauses")) }
        if t.contains("natürlich") || t.contains("natural") { p.pause = 0.3; done.append(L("Pausen natürlich", "Natural pauses")) }
        if t.contains("keine grafik") || t.contains("no graphics") { p.style = "none"; done.append(L("Grafiken aus", "Graphics off")) }
        if t.contains("mehr grafik") || t.contains("more graphics") { p.amount = "medium"; replan = true; done.append(L("Mehr Grafiken", "More graphics")) }
        if t.contains("sound") || t.contains("whoosh") { p.sfx = !(t.contains("aus") || t.contains("off")); done.append(p.sfx ? "Sounds an" : "Sounds aus") }
        for s in GraphicStyle.all where t.contains(s.name.lowercased()) || t.contains(s.id) {
            p.style = s.id
            replan = true
            done.append(L("Stil: ", "Style: ") + s.name)
        }
        for r in EditRecipe.builtIn where t.contains(r.name.lowercased()) && r.name != "Original" {
            var nr = r
            nr.trimStart = p.recipe.trimStart
            nr.trimEnd = p.recipe.trimEnd
            nr.speed = p.recipe.speed
            p.recipe = nr
            done.append(L("Farblook: ", "Color look: ") + r.name)
        }
        if done.isEmpty {
            return EditorReply(text: L("Ohne API-Key verstehe ich einfache Befehle wie „Untertitel größer“, „knackiger“, „Stil Chalk Talk“, „Cinematic“ oder „keine Grafiken“. Für alles andere trag unter Zahnrad einen Claude API-Key ein.",
                                       "Without an API key I understand simple commands like \"captions bigger\", \"tighter\", \"style Chalk Talk\", \"Cinematic\" or \"no graphics\". For anything else, add a Claude API key under the gear."),
                               options: [L("Untertitel größer", "Captions bigger"), L("Knackiger", "Tighter"), "Cinematic", L("Mehr Grafiken", "More graphics")])
        }
        return EditorReply(text: L("Erledigt: ", "Done: ") + done.joined(separator: ", ") + ".",
                           options: [L("Untertitel größer", "Captions bigger"), L("Knackiger", "Tighter"), "Cinematic", L("Mehr Grafiken", "More graphics")],
                           replan: replan)
    }
}
