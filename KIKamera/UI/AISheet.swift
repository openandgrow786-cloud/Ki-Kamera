import PhotosUI
import SwiftUI

/// KI-Zentrale: Befehl schreiben oder Referenzvideo zeigen, die KI stellt alles ein.
struct AISheet: View {
    let current: Preset
    var onApply: (Preset) -> Void

    @EnvironmentObject private var library: LookLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var loadingVideo = false
    @State private var phase: Phase = .ask
    @State private var status = ""
    @State private var showSave = false
    @State private var saveName = ""

    enum Phase: Equatable {
        case ask
        case working
        case result(Preset)
        case failed(String)
    }

    private let suggestions = [L("Nachtmodus", "Night mode"), L("Kino 24", "Cinema 24"), "Slow Motion", "Action", "Vlog Selfie", L("Produkt", "Product"),
                               "Golden Hour", L("Porträt-Foto", "Portrait photo"), L("Etwas wärmer", "A bit warmer"), L("Heller", "Brighter"), "60 fps", L("Quer für YouTube", "Landscape for YouTube"), "Instagram 4:5",
                               L("Wie mein Referenzvideo", "Like my reference video")]

    private var hasKey: Bool { !ClaudeService.apiKey.isEmpty }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    switch phase {
                    case .ask: askView
                    case .working: workingView
                    case .result(let p): resultView(p)
                    case .failed(let msg): failedView(msg)
                    }
                }
                .padding(20)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: phase)
            }
        }
        .onChange(of: pickerItem) { _, item in loadVideo(item) }
        .alert(L("Look speichern", "Save look"), isPresented: $showSave) {
            TextField(L("Name, z. B. Nachtmodus", "Name, e.g. Night mode"), text: $saveName)
            Button(L("Speichern", "Save")) {
                if case .result(let p) = phase { library.save(p, as: saveName) }
            }
            Button(L("Abbrechen", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("Der Look landet unter „Looks“ und ist jederzeit wieder abrufbar.", "The look is stored under \"Looks\" and can be recalled any time."))
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AIOrb(size: 56, active: phase == .working)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(22, .bold)).foregroundStyle(Theme.text)
                Text(hasKey ? L("KI verbunden", "AI connected") : L("Offline-Modus: eingebaute Looks", "Offline mode: built-in looks"))
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(hasKey ? Theme.cyan : Theme.muted)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 38, height: 38).glass(19)
            }
            .accessibilityLabel(L("Schließen", "Close"))
        }
    }

    private var title: String {
        switch phase {
        case .ask: return L("Was willst du filmen?", "What do you want to shoot?")
        case .working: return L("KI analysiert", "AI is analyzing")
        case .result(let p): return p.name
        case .failed: return L("Hinweis", "Note")
        }
    }

    // MARK: Fragen

    private var askView: some View {
        VStack(alignment: .leading, spacing: 18) {
            PromptField(placeholder: L("z. B. Nachtmodus, warm, 24 fps …", "e.g. night mode, warm, 24 fps …"), text: $prompt) { Task { await run() } }

            SectionLabel(text: L("Vorschläge", "Suggestions"))
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Chip(text: s) {
                        prompt = s
                        Task { await run() }
                    }
                }
            }

            SectionLabel(text: L("Referenz", "Reference"))
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Theme.cyan.opacity(0.12)).frame(width: 48, height: 48)
                        if loadingVideo {
                            ProgressView().tint(Theme.cyan)
                        } else {
                            Image(systemName: videoURL == nil ? "film.stack" : "checkmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.cyan)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(videoURL == nil ? L("Referenzvideo zeigen", "Show reference video") : L("Referenzvideo bereit", "Reference video ready"))
                            .font(Theme.ui(16, .semibold)).foregroundStyle(Theme.text)
                        Text(videoURL == nil ? L("Die KI kopiert Licht, Farbe, Bewegung und Objektiv", "The AI copies light, color, motion and lens")
                                             : L("Tipp auf den Pfeil oben, um es zu analysieren", "Tap the arrow above to analyze it"))
                            .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(14)
                .glass(18, glow: videoURL == nil ? nil : Theme.cyan)
            }
            .buttonStyle(.plain)

            Button(action: pasteCode) {
                Label(L("Preset-Code einfügen", "Paste preset code"), systemImage: "doc.on.clipboard")
            }
            .buttonStyle(GlassButtonStyle())

            if !hasKey {
                Text(L("Ohne API-Key versteht die KI Vorschläge und einfache Befehle wie „wärmer“ oder „60 fps“. Für freie Wünsche und Videoanalyse: Zahnrad → Claude API-Key. Oder schick das Video an Claude im Chat und füg den Preset-Code ein.", "Without an API key the AI understands suggestions and simple commands like \"warmer\" or \"60 fps\". For free requests and video analysis: gear → Claude API key. Or send the video to Claude in the chat and paste the preset code."))
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.muted)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var workingView: some View {
        VStack(spacing: 22) {
            AIOrb(size: 120, active: true)
            Text(status)
                .font(Theme.ui(15, .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .transition(.opacity)
    }

    // MARK: Ergebnis

    private func resultView(_ p: Preset) -> some View {
        let rows: [(String, String, String)] = [
            (L("Kamera", "Camera"), current.lens.focal, p.lens.focal),
            (L("Modus", "Mode"), current.isPhoto ? L("Foto", "Photo") : "Video", p.isPhoto ? L("Foto", "Photo") : "Video"),
            ("Format", current.aspectLabel, p.aspectLabel),
            (L("Auflösung", "Resolution"), current.resolutionText, p.resolutionText),
            ("FPS", current.fpsText, p.fpsText),
            (L("Verschluss", "Shutter"), current.shutterText, p.shutterText),
            ("ISO", current.isoText, p.isoText),
            (L("Weißabgleich", "White balance"), current.wbText, p.wbText),
            ("Tint", current.tintText, p.tintText),
            (L("Belichtung", "Exposure"), current.evText, p.evText),
            ("Zoom", String(format: "%.1f×", current.effectiveZoom), String(format: "%.1f×", p.effectiveZoom)),
            ("HDR", current.hdr ? "An" : L("Aus", "Off"), p.hdr ? "An" : L("Aus", "Off")),
            (L("Stabilisierung", "Stabilization"), current.stabilization, p.stabilization),
            ("Countdown", "\(current.countdown) s", "\(p.countdown) s")
        ]
        return VStack(alignment: .leading, spacing: 16) {
            if let note = p.note {
                Text(note).font(Theme.ui(15)).foregroundStyle(Theme.text.opacity(0.9))
            }
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let row = rows[i]
                    let changed = row.1 != row.2
                    HStack {
                        Text(row.0).font(Theme.ui(14)).foregroundStyle(Theme.muted)
                        Spacer()
                        if changed {
                            Text(row.1).font(Theme.mono(12)).foregroundStyle(Theme.muted).strikethrough()
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.cyan)
                        }
                        Text(row.2)
                            .font(Theme.mono(14, .bold))
                            .foregroundStyle(changed ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.text))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    if i < rows.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
            .glass(18)

            Button(L("Übernehmen", "Apply")) { onApply(p) }
                .buttonStyle(GoldButtonStyle())
            HStack(spacing: 10) {
                Button {
                    saveName = p.name
                    showSave = true
                } label: { Label(L("Als Look speichern", "Save as look"), systemImage: "bookmark") }
                .buttonStyle(GlassButtonStyle())
                Button { phase = .ask } label: { Label(L("Nochmal", "Try again"), systemImage: "arrow.counterclockwise") }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func failedView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(msg).font(Theme.ui(15)).foregroundStyle(Theme.text)
            Button(L("Zurück", "Back")) { phase = .ask }.buttonStyle(GlassButtonStyle())
        }
    }

    // MARK: Logik

    private func loadVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loadingVideo = true
        Task {
            let file = try? await item.loadTransferable(type: VideoFile.self)
            await MainActor.run {
                videoURL = file?.url
                loadingVideo = false
                if file == nil { phase = .failed(L("Das Video konnte nicht geladen werden.", "Could not load the video.")) }
            }
        }
    }

    private func run() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || videoURL != nil else { return }

        guard hasKey else {
            if videoURL != nil && text.isEmpty {
                phase = .failed(L("Für die Videoanalyse in der App brauchst du einen Claude API-Key (Zahnrad oben rechts).\n\nOhne Key: Schick das Video an Claude im Chat, kopier den Preset-Code und tipp auf „Preset-Code einfügen“.", "For video analysis in the app you need a Claude API key (gear at the top right).\n\nWithout a key: send the video to Claude in the chat, copy the preset code and tap \"Paste preset code\"."))
            } else {
                phase = .working
                status = L("Look wird zusammengestellt …", "Building the look …")
                try? await Task.sleep(nanoseconds: 700_000_000)
                phase = .result(LocalAI.interpret(text, current: current))
            }
            return
        }

        phase = .working
        do {
            var reference: ReferenceInfo?
            if let url = videoURL {
                status = L("Referenzvideo wird gelesen …", "Reading reference video …")
                reference = try await ReferenceAnalyzer.load(url: url)
            }
            status = L("KI analysiert Licht, Farbe und Bewegung …", "AI is analyzing light, color and motion …")
            let preset = try await ClaudeService.makePreset(request: text, current: current, reference: reference)
            phase = .result(preset)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func pasteCode() {
        if let text = UIPasteboard.general.string, let p = PresetCode.decode(text) {
            phase = .result(p)
        } else {
            phase = .failed(L("In der Zwischenablage ist kein gültiger Preset-Code.", "There is no valid preset code in the clipboard."))
        }
    }
}
