import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest)
        }
    }
}

/// Hier sagt man der KI, wie das Video aussehen soll.
struct KISheet: View {
    var onApply: (Preset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var loadingVideo = false
    @State private var prompt = ""
    @State private var phase: Phase = .ask
    @State private var status = ""

    enum Phase: Equatable {
        case ask
        case working
        case result(Preset)
        case failed(String)
    }

    private let chips = ["Wie mein Referenzvideo", "Kino-Look 24 fps", "Slow Motion", "Warm & weich"]

    private var title: String {
        switch phase {
        case .ask: return "Wie willst du filmen?"
        case .working: return "KI analysiert …"
        case .result(let p): return "Erkannt: \(p.name)"
        case .failed: return "Hinweis"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .ask: askView
                    case .working: workingView
                    case .result(let p): resultView(p)
                    case .failed(let msg): failedView(msg)
                    }
                }
                .padding(20)
            }
            .background(Color.kPanel.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            loadVideo(item)
        }
    }

    // MARK: Ansichten

    private var askView: some View {
        VStack(alignment: .leading, spacing: 16) {
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                HStack(spacing: 12) {
                    Image(systemName: videoURL == nil ? "video.badge.plus" : "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.kAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(videoURL == nil ? "Referenzvideo zeigen" : "Referenzvideo ausgewählt")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.white)
                        Text(loadingVideo ? "Wird geladen …" : (videoURL == nil ? "Aus deinen Fotos wählen" : "Tippen zum Ändern"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.kMuted)
                    }
                    Spacer()
                    if loadingVideo { ProgressView() }
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(videoURL == nil ? Color.kLine : Color.kAccent,
                                      style: StrokeStyle(lineWidth: 1, dash: [5]))
                )
            }

            Text("Oder beschreib, wie es aussehen soll")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.kMuted)

            TextField("z. B. Kino-Look, etwas wärmer", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .padding(14)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Button { prompt = chip } label: {
                            Text(chip)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 13)
                                .frame(height: 36)
                                .background(Color.white.opacity(0.07))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Button { Task { await run() } } label: {
                Text("KI einstellen lassen")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.kAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(loadingVideo)

            Button { pasteCode() } label: {
                Label("Preset-Code einfügen", systemImage: "doc.on.clipboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Text("Preset-Code: Schick Claude im Chat dein Referenzvideo, kopier den Code und tipp hier drauf.")
                .font(.system(size: 12))
                .foregroundStyle(Color.kMuted)
        }
    }

    private var workingView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(Color.kAccent)
            Text(status).foregroundStyle(Color.kMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func resultView(_ p: Preset) -> some View {
        let rows: [(String, String)] = [
            ("Kamera", p.lens.longLabel),
            ("Auflösung", p.resolutionText),
            ("FPS", p.fpsText),
            ("Verschluss", p.shutterText),
            ("ISO", p.isoText),
            ("Weißabgleich", p.wbText),
            ("Tint", p.tintText),
            ("HDR", p.hdr ? "An" : "Aus"),
            ("Codec", p.codec.uppercased())
        ]
        return VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack {
                        Text(rows[i].0).foregroundStyle(Color.kMuted)
                        Spacer()
                        Text(rows[i].1).font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    if i < rows.count - 1 { Divider().overlay(Color.kLine) }
                }
            }
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if let note = p.note {
                Text(note).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.85))
            }
            if p.iso == nil {
                Text("ISO bleibt auf Automatik, damit das Bild bei anderem Licht nicht zu hell oder zu dunkel wird.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kMuted)
            }

            Button { onApply(p) } label: {
                Text("Übernehmen")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.kAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Button("Nochmal") { phase = .ask }
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(Color.kMuted)
        }
    }

    private func failedView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Hat nicht geklappt", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(Color.kAccent)
            Text(msg).foregroundStyle(Color.white)
            Button("Zurück") { phase = .ask }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(Color.white)
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
        let key = Keychain.get(SettingsView.keyName) ?? ""
        if key.isEmpty {
            if videoURL != nil {
                phase = .failed("Damit die App Videos selbst analysiert, brauchst du einen Claude API-Key (Zahnrad oben rechts).\n\nOhne Key: Schick das Video an Claude im Chat, kopier den Preset-Code und tipp auf „Preset-Code einfügen“.")
            } else {
                var p = Preset.match(text: prompt)
                p.note = "Ohne API-Key: passender eingebauter Look."
                phase = .result(p)
            }
            return
        }

        phase = .working
        do {
            var reference: ReferenceInfo?
            if let url = videoURL {
                status = "Video wird gelesen …"
                reference = try await ReferenceAnalyzer.load(url: url)
            }
            status = "KI analysiert Licht, Farbe und Bewegung …"
            let saved = UserDefaults.standard.string(forKey: SettingsView.modelKey) ?? ""
            let model = saved.isEmpty ? SettingsView.defaultModel : saved
            let preset = try await ClaudeService.makePreset(apiKey: key, model: model, request: prompt, reference: reference)
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
