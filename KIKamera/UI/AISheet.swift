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

    private let suggestions = ["Nachtmodus", "Kino 24", "Slow Motion", "Action", "Vlog Selfie", "Produkt",
                               "Golden Hour", "Porträt-Foto", "Etwas wärmer", "Heller", "60 fps", "Quer für YouTube", "Instagram 4:5",
                               "Wie mein Referenzvideo"]

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
        .alert("Look speichern", isPresented: $showSave) {
            TextField("Name, z. B. Nachtmodus", text: $saveName)
            Button("Speichern") {
                if case .result(let p) = phase { library.save(p, as: saveName) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Look landet unter „Looks“ und ist jederzeit wieder abrufbar.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AIOrb(size: 56, active: phase == .working)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(22, .bold)).foregroundStyle(Theme.text)
                Text(hasKey ? "KI verbunden" : "Offline-Modus: eingebaute Looks")
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(hasKey ? Theme.cyan : Theme.muted)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(width: 38, height: 38).glass(19)
            }
            .accessibilityLabel("Schließen")
        }
    }

    private var title: String {
        switch phase {
        case .ask: return "Was willst du filmen?"
        case .working: return "KI analysiert"
        case .result(let p): return p.name
        case .failed: return "Hinweis"
        }
    }

    // MARK: Fragen

    private var askView: some View {
        VStack(alignment: .leading, spacing: 18) {
            PromptField(placeholder: "z. B. Nachtmodus, warm, 24 fps …", text: $prompt) { Task { await run() } }

            SectionLabel(text: "Vorschläge")
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Chip(text: s) {
                        prompt = s
                        Task { await run() }
                    }
                }
            }

            SectionLabel(text: "Referenz")
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
                        Text(videoURL == nil ? "Referenzvideo zeigen" : "Referenzvideo bereit")
                            .font(Theme.ui(16, .semibold)).foregroundStyle(Theme.text)
                        Text(videoURL == nil ? "Die KI kopiert Licht, Farbe, Bewegung und Objektiv"
                                             : "Tipp auf den Pfeil oben, um es zu analysieren")
                            .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(14)
                .glass(18, glow: videoURL == nil ? nil : Theme.cyan)
            }
            .buttonStyle(.plain)

            Button(action: pasteCode) {
                Label("Preset-Code einfügen", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(GlassButtonStyle())

            if !hasKey {
                Text("Ohne API-Key versteht die KI Vorschläge und einfache Befehle wie „wärmer“ oder „60 fps“. Für freie Wünsche und Videoanalyse: Zahnrad → Claude API-Key. Oder schick das Video an Claude im Chat und füg den Preset-Code ein.")
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
            ("Kamera", current.lens.focal, p.lens.focal),
            ("Modus", current.isPhoto ? "Foto" : "Video", p.isPhoto ? "Foto" : "Video"),
            ("Format", current.aspectLabel, p.aspectLabel),
            ("Auflösung", current.resolutionText, p.resolutionText),
            ("FPS", current.fpsText, p.fpsText),
            ("Verschluss", current.shutterText, p.shutterText),
            ("ISO", current.isoText, p.isoText),
            ("Weißabgleich", current.wbText, p.wbText),
            ("Tint", current.tintText, p.tintText),
            ("Belichtung", current.evText, p.evText),
            ("Zoom", String(format: "%.1f×", current.effectiveZoom), String(format: "%.1f×", p.effectiveZoom)),
            ("HDR", current.hdr ? "An" : "Aus", p.hdr ? "An" : "Aus"),
            ("Stabilisierung", current.stabilization, p.stabilization),
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

            Button("Übernehmen") { onApply(p) }
                .buttonStyle(GoldButtonStyle())
            HStack(spacing: 10) {
                Button {
                    saveName = p.name
                    showSave = true
                } label: { Label("Als Look speichern", systemImage: "bookmark") }
                .buttonStyle(GlassButtonStyle())
                Button { phase = .ask } label: { Label("Nochmal", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func failedView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(msg).font(Theme.ui(15)).foregroundStyle(Theme.text)
            Button("Zurück") { phase = .ask }.buttonStyle(GlassButtonStyle())
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
                if file == nil { phase = .failed("Das Video konnte nicht geladen werden.") }
            }
        }
    }

    private func run() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || videoURL != nil else { return }

        guard hasKey else {
            if videoURL != nil && text.isEmpty {
                phase = .failed("Für die Videoanalyse in der App brauchst du einen Claude API-Key (Zahnrad oben rechts).\n\nOhne Key: Schick das Video an Claude im Chat, kopier den Preset-Code und tipp auf „Preset-Code einfügen“.")
            } else {
                phase = .working
                status = "Look wird zusammengestellt …"
                try? await Task.sleep(nanoseconds: 700_000_000)
                phase = .result(LocalAI.interpret(text, current: current))
            }
            return
        }

        phase = .working
        do {
            var reference: ReferenceInfo?
            if let url = videoURL {
                status = "Referenzvideo wird gelesen …"
                reference = try await ReferenceAnalyzer.load(url: url)
            }
            status = "KI analysiert Licht, Farbe und Bewegung …"
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
            phase = .failed("In der Zwischenablage ist kein gültiger Preset-Code.")
        }
    }
}
