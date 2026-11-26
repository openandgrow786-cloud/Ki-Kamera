import AVKit
import PhotosUI
import SwiftUI

private enum StudioTab: String, CaseIterable, Identifiable {
    case ai, cut, graphics, look
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ai: return L("KI-Editor", "AI editor")
        case .cut: return L("Schnitt", "Cut")
        case .graphics: return L("Grafik", "Graphics")
        case .look: return "Look"
        }
    }
}

private struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let fromUser: Bool
    let text: String
    var options: [String] = []
}

private struct StyleItem: Identifiable {
    let id: String
    let recipe: EditRecipe
    let custom: Bool
}

/// KI Studio mit eingebautem Video-Editor-Skill: fragt dich, schneidet Pausen und Versprecher,
/// setzt Untertitel und Motion Graphics, färbt, kürzt und exportiert.
struct EditorScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LookLibrary
    @Namespace private var ns

    @State private var pickerItem: PhotosPickerItem?
    @State private var clipURL: URL?
    @State private var clipLength: Double = 0
    @State private var outLength: Double = 0
    @State private var loading = false
    @State private var player = AVPlayer()
    @State private var project = EditProject()
    @State private var revision = 0
    @State private var tab: StudioTab = .ai

    @State private var interviewDone = false
    @State private var messages: [ChatMessage] = []
    @State private var chatInput = ""
    @State private var busy = false
    @State private var stage: String?

    @State private var exporting = false
    @State private var progress: Float = 0
    @State private var toast: String?
    @State private var showSave = false
    @State private var saveName = ""
    @State private var showFine = false
    @State private var thumbs: [String: UIImage] = [:]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                header
                preview
                if clipURL != nil {
                    tabBar
                    ScrollViewReader { proxy in
                        ScrollView {
                            Group {
                                switch tab {
                                case .ai: aiTab
                                case .cut: cutTab
                                case .graphics: graphicsTab
                                case .look: lookTab
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 40)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: messages) { _, _ in
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                } else {
                    Spacer()
                }
            }
            if exporting { exportOverlay }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(Theme.ui(14, .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glass(16, glow: Theme.cyan)
                        .padding(.bottom, 30)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toast)
        .animation(.easeInOut(duration: 0.25), value: exporting)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: tab)
        .onChange(of: pickerItem) { _, item in load(item) }
        .onChange(of: project) { _, _ in revision += 1 }
        .task(id: revision) { await rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            player.seek(to: .zero)
            player.play()
        }
        .onChange(of: toast) { _, value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if toast == value { toast = nil } }
        }
        .alert(L("Stil speichern", "Save style"), isPresented: $showSave) {
            TextField(L("Name, z. B. Mein Kino-Look", "Name, e.g. My cinema look"), text: $saveName)
            Button(L("Speichern", "Save")) {
                library.save(project.recipe, as: saveName)
                toast = L("Stil gespeichert", "Style saved")
            }
            Button(L("Abbrechen", "Cancel"), role: .cancel) {}
        }
    }

    // MARK: Kopf, Vorschau, Tabs

    private var header: some View {
        HStack {
            Button { player.pause(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 40, height: 40).glass(20)
            }
            .accessibilityLabel(L("Schließen", "Close"))
            Spacer()
            VStack(spacing: 2) {
                Text("KI STUDIO").font(Theme.mono(14, .heavy)).tracking(3).foregroundStyle(Theme.goldGradient)
                Text(clipURL == nil ? L("Clip wählen", "Choose a clip") : String(format: "%.1f s → %.1f s", clipLength, outLength))
                    .font(Theme.mono(11, .semibold)).foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: outLength)
            }
            Spacer()
            Button(action: export) {
                Text("Export")
                    .font(Theme.ui(14, .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().fill(Theme.goldGradient))
            }
            .disabled(clipURL == nil || exporting || busy)
            .opacity(clipURL == nil ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var preview: some View {
        ZStack {
            if clipURL != nil {
                VideoPlayer(player: player)
            } else {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    VStack(spacing: 18) {
                        AIOrb(size: 90, active: loading)
                        Text(L("Clip auswählen", "Choose clip")).font(Theme.ui(20, .bold)).foregroundStyle(Theme.text)
                        Text(L("Der KI-Editor fragt dich kurz, schneidet Pausen und Versprecher, setzt Untertitel und Grafiken. Danach sagst du ihm einfach, was anders sein soll.",
                               "The AI editor asks you a few questions, cuts pauses and mistakes, adds captions and graphics. Then just tell it what to change."))
                            .font(Theme.ui(14))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            }
            if loading { ProgressView().tint(Theme.gold).controlSize(.large) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: clipURL == nil ? 460 : 280)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, 14)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(StudioTab.allCases) { t in
                let on = tab == t
                Button { tab = t } label: {
                    Text(t.title)
                        .font(Theme.ui(13, .bold))
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if on { Capsule().fill(Theme.goldGradient).matchedGeometryEffect(id: "studioTab", in: ns) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glass(20)
        .padding(.horizontal, 14)
    }

    // MARK: KI-Editor

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !interviewDone {
                interview
            } else {
                ForEach(messages) { m in bubble(m) }
                if let stage {
                    HStack(spacing: 12) {
                        AIOrb(size: 36, active: true)
                        Text(stage).font(Theme.ui(14, .medium)).foregroundStyle(Theme.muted)
                    }
                    .transition(.opacity)
                }
                if !busy {
                    PromptField(placeholder: L("Sag dem Editor, was anders sein soll …", "Tell the editor what to change …"),
                                text: $chatInput, busy: busy) { send(chatInput) }
                }
            }
        }
        .padding(.top, 4)
    }

    private func question(_ title: String, _ items: [ChipItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.ui(14, .semibold)).foregroundStyle(Theme.text)
            FlowLayout(spacing: 8) {
                ForEach(items) { item in
                    Chip(text: item.label, selected: item.selected, action: item.action)
                }
            }
        }
    }

    private var silenceItems: [ChipItem] {
        [
            ChipItem(label: L("Ja, natürlich", "Yes, natural"), selected: project.cutSilences && project.pause > 0.2) {
                project.cutSilences = true
                project.pause = 0.3
            },
            ChipItem(label: L("Ja, knackig", "Yes, tight"), selected: project.cutSilences && project.pause < 0.2) {
                project.cutSilences = true
                project.pause = 0.15
            },
            ChipItem(label: L("Nein", "No"), selected: !project.cutSilences) { project.cutSilences = false }
        ]
    }

    private func yesNo(_ value: Bool, _ set: @escaping (Bool) -> Void) -> [ChipItem] {
        [
            ChipItem(label: L("Ja", "Yes"), selected: value) { set(true) },
            ChipItem(label: L("Nein", "No"), selected: !value) { set(false) }
        ]
    }

    private var interview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AIOrb(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Kurz vorab", "Quick questions")).font(Theme.ui(18, .bold))
                    Text(L("Gold = Standard. Tipp einfach „Los geht's“.", "Gold = default. Just tap \"Let's go\"."))
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
            }
            question(L("1. Pausen rausschneiden?", "1. Cut silent parts?"), silenceItems)
            question(L("2. Versprecher, Retakes, Fehlstarts rausschneiden?", "2. Cut mistakes, retakes, false starts?"),
                     yesNo(project.cutMistakes) { project.cutMistakes = $0 })
            VStack(alignment: .leading, spacing: 8) {
                Text(L("3. Grafik-Stil", "3. Graphics style")).font(Theme.ui(14, .semibold))
                FlowLayout(spacing: 8) {
                    ForEach(GraphicStyle.all) { s in
                        Chip(text: s.name, selected: project.style == s.id) { project.style = s.id }
                    }
                    Chip(text: L("Keine Grafiken", "No graphics"), selected: project.style == "none") { project.style = "none" }
                }
                if let s = GraphicStyle.named(project.style) {
                    Text(s.blurb).font(Theme.ui(12)).foregroundStyle(Theme.cyan)
                }
            }
            question(L("4. Sprache im Video", "4. Language in the video"), [
                ChipItem(label: "Deutsch", selected: project.language == "de") { project.language = "de" },
                ChipItem(label: "English", selected: project.language == "en") { project.language = "en" }
            ])
            question(L("5. Untertitel?", "5. Captions?"), yesNo(project.captions) { project.captions = $0 })
            question(L("6. Wie viele Grafiken?", "6. How much graphics?"), [
                ChipItem(label: L("Wenig (nur Schlüsselmomente)", "Light (key moments only)"), selected: project.amount == "light") { project.amount = "light" },
                ChipItem(label: L("Mittel", "Medium"), selected: project.amount == "medium") { project.amount = "medium" }
            ])
            question(L("7. Sounds zu den Grafiken?", "7. Sound effects with graphics?"), yesNo(project.sfx) { project.sfx = $0 })
            Button(L("Los geht's", "Let's go")) {
                interviewDone = true
                Task { await analyze() }
            }
            .buttonStyle(GoldButtonStyle())
            Text(EditorAI.online
                 ? L("Claude ist verbunden: denkt mit, findet Fehler und plant Grafiken.", "Claude is connected: thinks along, finds mistakes and plans graphics.")
                 : L("Ohne API-Key arbeitet der Editor mit einfachen Regeln. Mit Key (Zahnrad) denkt Claude mit.", "Without an API key the editor uses simple rules. With a key (gear) Claude thinks along."))
                .font(Theme.ui(12)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .glass(20)
    }

    private func bubble(_ m: ChatMessage) -> some View {
        VStack(alignment: m.fromUser ? .trailing : .leading, spacing: 8) {
            Text(m.text)
                .font(Theme.ui(15))
                .foregroundStyle(m.fromUser ? Color.black : Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if m.fromUser {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.goldGradient)
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel2)
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cyan.opacity(0.3)))
                    }
                }
                .frame(maxWidth: 300, alignment: m.fromUser ? .trailing : .leading)
            if !m.options.isEmpty && m.id == messages.last?.id && !busy {
                FlowLayout(spacing: 8) {
                    ForEach(m.options, id: \.self) { o in
                        Chip(text: o) { send(o) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: m.fromUser ? .trailing : .leading)
        .transition(.move(edge: m.fromUser ? .trailing : .leading).combined(with: .opacity))
    }

    // MARK: Schnitt

    private var cutTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 14) {
                Toggle(L("Pausen rausschneiden", "Cut silent parts"), isOn: $project.cutSilences)
                if project.cutSilences {
                    Picker("", selection: $project.pause) {
                        Text(L("Natürlich (0,3 s)", "Natural (0.3 s)")).tag(0.3)
                        Text(L("Knackig (0,15 s)", "Tight (0.15 s)")).tag(0.15)
                    }
                    .pickerStyle(.segmented)
                }
                Toggle(L("Versprecher rausschneiden", "Cut mistakes"), isOn: $project.cutMistakes)
                HStack {
                    Text(L("Erkannte Pausen", "Detected pauses")).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(project.silences.count)").font(Theme.mono(14, .bold))
                }
            }
            .font(Theme.ui(14, .semibold))
            .tint(Theme.gold)
            .padding(16)
            .glass(18)

            SectionLabel(text: L("Fehler-Schnitte", "Mistake cuts"))
            if project.cuts.isEmpty {
                Text(project.analyzed ? L("Keine Versprecher gefunden.", "No mistakes found.")
                                      : L("Erst im KI-Editor auf „Los geht's“ tippen.", "Tap \"Let's go\" in the AI editor first."))
                    .font(Theme.ui(13)).foregroundStyle(Theme.muted)
            }
            ForEach($project.cuts) { $c in
                HStack(alignment: .top, spacing: 12) {
                    Toggle("", isOn: $c.enabled).labelsHidden().tint(Theme.gold)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f – %.1f s · ", c.start, c.end) + c.why)
                            .font(Theme.mono(11, .bold)).foregroundStyle(Theme.cyan)
                        Text(c.text).font(Theme.ui(14)).foregroundStyle(Theme.text.opacity(c.enabled ? 0.6 : 1))
                            .strikethrough(c.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(14)
            }

            SectionLabel(text: L("Kürzen & Tempo", "Trim & speed"))
            VStack(spacing: 14) {
                ValueSlider(label: "Start", value: startBinding, range: 0...max(clipLength - 0.3, 0.1), step: 0.1,
                            format: { String(format: "%.1f s", $0) })
                ValueSlider(label: L("Ende", "End"), value: endBinding, range: 0.3...max(clipLength, 0.4), step: 0.1,
                            format: { String(format: "%.1f s", $0) })
                FlowLayout(spacing: 8) {
                    ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { s in
                        Chip(text: s == 1 ? "Normal" : String(format: "%g×", s), selected: abs(project.recipe.speed - s) < 0.01) {
                            project.recipe.speed = s
                        }
                    }
                }
            }
            .padding(16)
            .glass(18)
        }
        .padding(.top, 4)
    }

    // MARK: Grafik

    private var graphicsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: L("Stil", "Style"))
            FlowLayout(spacing: 8) {
                ForEach(GraphicStyle.all) { s in
                    Chip(text: s.name, selected: project.style == s.id) { project.style = s.id }
                }
                Chip(text: L("Keine", "None"), selected: project.style == "none") { project.style = "none" }
            }
            VStack(spacing: 14) {
                Toggle(L("Untertitel", "Captions"), isOn: $project.captions)
                if project.captions {
                    ValueSlider(label: L("Untertitel-Größe", "Caption size"), value: $project.captionSize, range: 0.7...1.6, step: 0.05,
                                format: { "\(Int($0 * 100)) %" })
                }
                Toggle(L("Whoosh-Sounds", "Whoosh sounds"), isOn: $project.sfx)
                Picker(L("Menge", "Amount"), selection: $project.amount) {
                    Text(L("Wenig", "Light")).tag("light")
                    Text(L("Mittel", "Medium")).tag("medium")
                }
                .pickerStyle(.segmented)
            }
            .font(Theme.ui(14, .semibold))
            .tint(Theme.gold)
            .padding(16)
            .glass(18)

            HStack {
                SectionLabel(text: L("Grafiken", "Graphics"))
                Spacer()
                Button {
                    Task { await replan() }
                } label: {
                    Label(L("Neu planen", "Re-plan"), systemImage: "sparkles").font(Theme.ui(13, .semibold))
                }
                .disabled(busy || !project.analyzed || project.style == "none")
            }
            if project.beats.isEmpty {
                Text(project.analyzed ? L("Noch keine Grafiken. Tipp auf „Neu planen“ oder sag dem Editor, wo eine hin soll.",
                                          "No graphics yet. Tap \"Re-plan\" or tell the editor where you want one.")
                                      : L("Erst im KI-Editor auf „Los geht's“ tippen.", "Tap \"Let's go\" in the AI editor first."))
                    .font(Theme.ui(13)).foregroundStyle(Theme.muted)
            }
            ForEach($project.beats) { $b in
                HStack(alignment: .top, spacing: 12) {
                    Toggle("", isOn: $b.enabled).labelsHidden().tint(Theme.gold)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f – %.1f s · ", b.start, b.end) + kindName(b.kind))
                            .font(Theme.mono(11, .bold)).foregroundStyle(Theme.cyan)
                        TextField("Text", text: $b.title)
                            .font(Theme.ui(15, .semibold))
                        if let items = b.items, !items.isEmpty {
                            Text(items.joined(separator: " · ")).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    Button {
                        let id = b.id
                        project.beats.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "trash").foregroundStyle(Theme.muted).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(L("Löschen", "Delete"))
                }
                .padding(12)
                .glass(14)
            }
        }
        .padding(.top, 4)
    }

    private func kindName(_ k: String) -> String {
        switch k {
        case "title": return L("Titel", "Title")
        case "keyword": return L("Stichwort", "Keyword")
        case "list": return L("Liste", "List")
        case "number": return L("Zahl", "Number")
        case "lowerThird": return L("Bauchbinde", "Lower third")
        case "quote": return L("Zitat", "Quote")
        default: return k
        }
    }

    // MARK: Look

    private var styleItems: [StyleItem] {
        EditRecipe.builtIn.map { StyleItem(id: "b-" + $0.name, recipe: $0, custom: false) }
            + library.styles.map { StyleItem(id: "c-" + $0.recipe.name, recipe: $0.recipe, custom: true) }
    }

    private var lookTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: L("Farblook", "Color look"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(styleItems) { item in styleTile(item) }
                }
                .padding(.vertical, 4)
            }
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showFine.toggle() }
            } label: {
                HStack {
                    SectionLabel(text: L("Feinschliff", "Fine tuning"))
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showFine ? 180 : 0)).foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(.plain)
            if showFine {
                VStack(spacing: 14) {
                    ValueSlider(label: L("Belichtung", "Exposure"), value: $project.recipe.exposure, range: -2...2, step: 0.05,
                                format: { String(format: "%+.2f", $0) })
                    ValueSlider(label: L("Kontrast", "Contrast"), value: $project.recipe.contrast, range: 0.5...1.6, step: 0.01)
                    ValueSlider(label: L("Sättigung", "Saturation"), value: $project.recipe.saturation, range: 0...2, step: 0.01)
                    ValueSlider(label: L("Wärme", "Warmth"), value: $project.recipe.warmth, range: -100...100, step: 1, format: { "\(Int($0))" })
                    ValueSlider(label: "Tint", value: $project.recipe.tint, range: -100...100, step: 1, format: { "\(Int($0))" })
                    ValueSlider(label: "Vignette", value: $project.recipe.vignette, range: 0...1, step: 0.01)
                    ValueSlider(label: L("Körnung", "Grain"), value: $project.recipe.grain, range: 0...1, step: 0.01)
                    ValueSlider(label: L("Schärfe", "Sharpness"), value: $project.recipe.sharpen, range: 0...1, step: 0.01)
                    ValueSlider(label: "Fade", value: $project.recipe.fade, range: 0...1, step: 0.01)
                    Toggle(L("Schwarz-Weiß", "Black & white"), isOn: $project.recipe.blackWhite)
                        .font(Theme.ui(14, .semibold)).tint(Theme.gold)
                }
                .padding(16)
                .glass(18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 10) {
                Button {
                    saveName = project.recipe.name
                    showSave = true
                } label: { Label(L("Stil speichern", "Save style"), systemImage: "bookmark") }
                .buttonStyle(GlassButtonStyle())
                Button {
                    UIPasteboard.general.string = EditCode.encode(project.recipe)
                    toast = L("Stil-Code kopiert", "Style code copied")
                } label: { Label("Code", systemImage: "doc.on.doc") }
                .buttonStyle(GlassButtonStyle())
            }
            HStack(spacing: 10) {
                Button(action: pasteCode) { Label(L("Code einfügen", "Paste code"), systemImage: "doc.on.clipboard") }
                    .buttonStyle(GlassButtonStyle())
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label(L("Anderer Clip", "Other clip"), systemImage: "film")
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.top, 4)
    }

    private func styleTile(_ item: StyleItem) -> some View {
        let selected = item.recipe.styleOnly == project.recipe.styleOnly
        return Button {
            var r = item.recipe
            r.trimStart = project.recipe.trimStart
            r.trimEnd = project.recipe.trimEnd
            r.speed = project.recipe.speed
            project.recipe = r
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let img = thumbs[item.id] {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [Theme.panel2, Theme.panel], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: 78, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.hairline), lineWidth: selected ? 2 : 1)
                )
                .shadow(color: selected ? Theme.gold.opacity(0.45) : .clear, radius: 10)
                Text(item.recipe.name)
                    .font(Theme.ui(11, .semibold))
                    .foregroundStyle(selected ? Theme.gold : Theme.text)
                    .lineLimit(1)
                    .frame(width: 80)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.custom, let saved = library.styles.first(where: { $0.recipe.name == item.recipe.name }) {
                Button(role: .destructive) { library.delete(saved) } label: { Label(L("Löschen", "Delete"), systemImage: "trash") }
            }
        }
    }

    private var startBinding: Binding<Double> {
        Binding(get: { project.recipe.trimStart },
                set: { v in project.recipe.trimStart = max(0, min(v, (project.recipe.trimEnd ?? clipLength) - 0.3)) })
    }

    private var endBinding: Binding<Double> {
        Binding(get: { project.recipe.trimEnd ?? clipLength },
                set: { v in project.recipe.trimEnd = min(clipLength, max(v, project.recipe.trimStart + 0.3)) })
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Theme.line, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress))
                        .stroke(Theme.goldGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(Theme.mono(22, .bold))
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                }
                .frame(width: 120, height: 120)
                .shadow(color: Theme.gold.opacity(0.4), radius: 20)
                Text(L("Wird gerendert …", "Rendering …")).font(Theme.ui(15)).foregroundStyle(Theme.muted)
            }
        }
        .transition(.opacity)
    }

    // MARK: Logik

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loading = true
        Task {
            let file = try? await item.loadTransferable(type: VideoFile.self)
            guard let url = file?.url else {
                loading = false
                toast = L("Clip konnte nicht geladen werden.", "Could not load the clip.")
                return
            }
            clipLength = await VideoEditor.duration(of: url)
            var fresh = EditProject()
            fresh.language = project.language
            project = fresh
            interviewDone = false
            messages = []
            tab = .ai
            clipURL = url
            loading = false
            await makeThumbs(url)
        }
    }

    private func makeThumbs(_ url: URL) async {
        let at = max(clipLength / 2, 0.1)
        var result: [String: UIImage] = [:]
        for item in styleItems {
            if let img = await VideoEditor.thumbnail(url: url, recipe: item.recipe, at: at) { result[item.id] = img }
        }
        withAnimation(.easeIn(duration: 0.3)) { thumbs = result }
    }

    private func rebuild() async {
        guard let url = clipURL else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        if Task.isCancelled { return }
        guard let built = try? await StudioEngine.build(url: url, project: project, preview: true) else { return }
        if Task.isCancelled { return }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        outLength = built.timeline.duration
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func say(_ text: String, options: [String] = []) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            messages.append(ChatMessage(fromUser: false, text: text, options: options))
        }
    }

    /// Die Pipeline des Editor-Skills: transkribieren, Pausen, Fehler, Grafiken.
    private func analyze() async {
        guard let url = clipURL else { return }
        busy = true
        var p = project

        stage = L("Ich höre mir dein Video an (Transkription) …", "Listening to your video (transcription) …")
        do {
            p.words = try await Transcriber.transcribe(url: url, language: p.language)
        } catch {
            say(error.localizedDescription)
        }
        stage = L("Ich suche die Pausen …", "Finding the pauses …")
        p.silences = (try? await Transcriber.silences(url: url)) ?? []

        if p.cutMistakes && !p.words.isEmpty {
            stage = L("Ich suche Versprecher und Retakes …", "Looking for mistakes and retakes …")
            p.cuts = await EditorAI.findMistakes(words: p.words)
        }
        if p.style != "none" {
            stage = L("Ich plane die Grafiken …", "Planning the graphics …")
            p.beats = await EditorAI.planBeats(p, timeline: Timeline.make(for: p, duration: clipLength))
        }
        p.analyzed = true
        project = p
        busy = false
        stage = nil

        let final = Timeline.make(for: p, duration: clipLength)
        let removed = max(clipLength - final.duration, 0)
        var lines: [String] = []
        lines.append(L("Fertig! ", "Done! ")
                     + String(format: "%.1f s → %.1f s", clipLength, final.duration)
                     + L(" (\(String(format: "%.1f", removed)) s rausgeschnitten).", " (\(String(format: "%.1f", removed)) s cut)."))
        if p.cutSilences { lines.append(L("\(p.silences.count) Pausen gekürzt.", "\(p.silences.count) pauses shortened.")) }
        if p.cutMistakes {
            lines.append(L("\(p.cuts.count) Versprecher/Retakes entfernt (unter „Schnitt“ prüfen).",
                           "\(p.cuts.count) mistakes/retakes removed (check under \"Cut\")."))
        }
        if let s = GraphicStyle.named(p.style) {
            lines.append(L("\(p.beats.count) Grafiken im Stil \(s.name).", "\(p.beats.count) graphics in \(s.name) style."))
        }
        if p.captions { lines.append(L("Untertitel sind an.", "Captions are on.")) }
        if p.words.isEmpty {
            lines.append(L("Ich habe keine Sprache erkannt, daher nur Pausen geschnitten.", "I didn't detect any speech, so only pauses were cut."))
        }
        lines.append(L("Was soll ich noch ändern? Für wen ist das Video, und wo postest du es?",
                       "What should I change? Who is the video for, and where will you post it?"))
        say(lines.joined(separator: " "), options: [
            L("Knackiger", "Tighter"), L("Untertitel größer", "Captions bigger"), L("Mehr Grafiken", "More graphics"), "Cinematic"
        ])
    }

    private func replan() async {
        busy = true
        stage = L("Ich plane die Grafiken neu …", "Re-planning the graphics …")
        var p = project
        p.beats = await EditorAI.planBeats(p, timeline: Timeline.make(for: p, duration: clipLength))
        project = p
        busy = false
        stage = nil
    }

    private func send(_ text: String) {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, !busy else { return }
        chatInput = ""
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            messages.append(ChatMessage(fromUser: true, text: msg))
        }
        let history = messages.map { ($0.fromUser, $0.text) }
        var p = project
        let length = clipLength
        Task {
            busy = true
            stage = L("Editor denkt nach …", "Editor is thinking …")
            let reply = await EditorAI.chat(history: history, project: &p, timeline: Timeline.make(for: p, duration: length))
            if reply.replan && p.style != "none" && p.analyzed {
                stage = L("Ich plane die Grafiken neu …", "Re-planning the graphics …")
                p.beats = await EditorAI.planBeats(p, timeline: Timeline.make(for: p, duration: length))
            }
            project = p
            busy = false
            stage = nil
            say(reply.text, options: reply.options)
        }
    }

    private func pasteCode() {
        if let text = UIPasteboard.general.string, let r = EditCode.decode(text) {
            project.recipe = r
            toast = L("Stil übernommen", "Style applied")
        } else {
            toast = L("Kein gültiger Stil-Code in der Zwischenablage", "No valid style code in the clipboard")
        }
    }

    private func export() {
        guard let url = clipURL else { return }
        player.pause()
        exporting = true
        progress = 0
        let p = project
        Task {
            do {
                let out = try await StudioEngine.export(url: url, project: p) { value in
                    DispatchQueue.main.async { progress = value }
                }
                PhotoSaver.saveVideo(out) { ok in
                    exporting = false
                    toast = ok ? L("In Fotos gespeichert", "Saved to Photos") : L("Kein Zugriff auf Fotos", "No access to Photos")
                    player.play()
                }
            } catch {
                exporting = false
                toast = error.localizedDescription
            }
        }
    }
}
