import AVKit
import PhotosUI
import SwiftUI

/// KI Studio: Clip wählen, der KI sagen wie er aussehen soll, live ansehen, exportieren.
struct EditorScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LookLibrary

    @State private var pickerItem: PhotosPickerItem?
    @State private var clipURL: URL?
    @State private var clipLength: Double = 0
    @State private var loading = false
    @State private var player = AVPlayer()
    @State private var recipe = EditRecipe.original
    @State private var prompt = ""
    @State private var aiBusy = false
    @State private var aiStatus: String?
    @State private var exporting = false
    @State private var progress: Float = 0
    @State private var toast: String?
    @State private var showSave = false
    @State private var saveName = ""
    @State private var showFine = false
    @State private var thumbs: [String: UIImage] = [:]

    private struct StyleItem: Identifiable {
        let recipe: EditRecipe
        let custom: Bool
        var id: String { (custom ? "c-" : "b-") + recipe.name }
    }

    private var styles: [StyleItem] {
        EditRecipe.builtIn.map { StyleItem(recipe: $0, custom: false) }
            + library.styles.map { StyleItem(recipe: $0.recipe, custom: true) }
    }

    private var rebuildKey: String {
        (clipURL?.lastPathComponent ?? "-") + EditCode.encode(recipe)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                header
                preview
                if clipURL != nil {
                    ScrollView { controls }
                        .scrollDismissesKeyboard(.interactively)
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
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toast)
        .animation(.easeInOut(duration: 0.25), value: exporting)
        .onChange(of: pickerItem) { _, item in load(item) }
        .task(id: rebuildKey) { await rebuild() }
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
                library.save(recipe, as: saveName)
                toast = L("Stil gespeichert", "Style saved")
            }
            Button(L("Abbrechen", "Cancel"), role: .cancel) {}
        }
    }

    // MARK: Kopf und Vorschau

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
                Text(clipURL == nil ? L("Clip wählen", "Choose a clip") : recipe.name)
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    .contentTransition(.opacity)
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
            .disabled(clipURL == nil || exporting)
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
                        Text(L("Dann sag der KI, wie er aussehen soll: Farblook, kürzen, Zeitlupe …", "Then tell the AI how it should look: color grade, trim, slow motion …"))
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
        .frame(height: clipURL == nil ? 420 : 300)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, 14)
    }

    // MARK: Bedienung

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            PromptField(placeholder: L("Sag der KI, wie dein Video aussehen soll …", "Tell the AI how your video should look …"), text: $prompt, busy: aiBusy) {
                Task { await runAI() }
            }
            if let aiStatus {
                Text(aiStatus).font(Theme.ui(13)).foregroundStyle(Theme.muted)
            } else if let note = recipe.note {
                Text(note).font(Theme.ui(13)).foregroundStyle(Theme.cyan)
            }

            SectionLabel(text: L("Stile", "Styles"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(styles) { item in
                        styleTile(item)
                    }
                }
                .padding(.vertical, 4)
            }

            SectionLabel(text: L("Schnitt & Tempo", "Trim & speed"))
            VStack(spacing: 14) {
                ValueSlider(label: "Start", value: startBinding, range: 0...max(clipLength - 0.3, 0.1), step: 0.1,
                            format: { String(format: "%.1f s", $0) })
                ValueSlider(label: L("Ende", "End"), value: endBinding, range: 0.3...max(clipLength, 0.4), step: 0.1,
                            format: { String(format: "%.1f s", $0) })
                FlowLayout(spacing: 8) {
                    ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { s in
                        Chip(text: s == 1 ? "Normal" : String(format: "%g×", s), selected: abs(recipe.speed - s) < 0.01) {
                            recipe.speed = s
                        }
                    }
                }
            }
            .padding(16)
            .glass(18)

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showFine.toggle() }
            } label: {
                HStack {
                    SectionLabel(text: L("Feinschliff", "Fine tuning"))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showFine ? 180 : 0))
                        .foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(.plain)

            if showFine {
                VStack(spacing: 14) {
                    ValueSlider(label: L("Belichtung", "Exposure"), value: $recipe.exposure, range: -2...2, step: 0.05,
                                format: { String(format: "%+.2f", $0) })
                    ValueSlider(label: L("Kontrast", "Contrast"), value: $recipe.contrast, range: 0.5...1.6, step: 0.01)
                    ValueSlider(label: L("Sättigung", "Saturation"), value: $recipe.saturation, range: 0...2, step: 0.01)
                    ValueSlider(label: L("Wärme", "Warmth"), value: $recipe.warmth, range: -100...100, step: 1,
                                format: { "\(Int($0))" })
                    ValueSlider(label: "Tint", value: $recipe.tint, range: -100...100, step: 1,
                                format: { "\(Int($0))" })
                    ValueSlider(label: "Vignette", value: $recipe.vignette, range: 0...1, step: 0.01)
                    ValueSlider(label: L("Körnung", "Grain"), value: $recipe.grain, range: 0...1, step: 0.01)
                    ValueSlider(label: L("Schärfe", "Sharpness"), value: $recipe.sharpen, range: 0...1, step: 0.01)
                    ValueSlider(label: "Fade", value: $recipe.fade, range: 0...1, step: 0.01)
                    Toggle(L("Schwarz-Weiß", "Black & white"), isOn: $recipe.blackWhite)
                        .font(Theme.ui(14, .semibold))
                        .tint(Theme.gold)
                }
                .padding(16)
                .glass(18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 10) {
                Button {
                    saveName = recipe.name
                    showSave = true
                } label: { Label(L("Stil speichern", "Save style"), systemImage: "bookmark") }
                .buttonStyle(GlassButtonStyle())
                Button {
                    UIPasteboard.general.string = EditCode.encode(recipe)
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
        .padding(.horizontal, 16)
        .padding(.bottom, 40)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: recipe)
    }

    private func styleTile(_ item: StyleItem) -> some View {
        let selected = item.recipe.styleOnly == recipe.styleOnly
            || (item.recipe.name == recipe.name && item.recipe.name != "KI-Edit")
        return Button {
            var r = item.recipe
            r.trimStart = recipe.trimStart
            r.trimEnd = recipe.trimEnd
            r.speed = recipe.speed
            recipe = r
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
                        .strokeBorder(selected ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.hairline),
                                      lineWidth: selected ? 2 : 1)
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
        Binding(get: { recipe.trimStart },
                set: { v in recipe.trimStart = max(0, min(v, (recipe.trimEnd ?? clipLength) - 0.3)) })
    }

    private var endBinding: Binding<Double> {
        Binding(get: { recipe.trimEnd ?? clipLength },
                set: { v in recipe.trimEnd = min(clipLength, max(v, recipe.trimStart + 0.3)) })
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
            recipe = .original
            clipURL = url
            loading = false
            await makeThumbs(url)
        }
    }

    private func makeThumbs(_ url: URL) async {
        let at = max(clipLength / 2, 0.1)
        var result: [String: UIImage] = [:]
        for item in styles {
            if let img = await VideoEditor.thumbnail(url: url, recipe: item.recipe, at: at) {
                result[item.id] = img
            }
        }
        withAnimation(.easeIn(duration: 0.3)) { thumbs = result }
    }

    private func rebuild() async {
        guard let url = clipURL else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)
        if Task.isCancelled { return }
        guard let result = try? await VideoEditor.makeComposition(url: url, recipe: recipe) else { return }
        if Task.isCancelled { return }
        let item = AVPlayerItem(asset: result.0)
        item.videoComposition = result.1
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func runAI() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = clipURL else { return }
        aiBusy = true
        defer { aiBusy = false }

        if ClaudeService.apiKey.isEmpty {
            var r = EditRecipe.match(text: text)
            r.trimStart = recipe.trimStart
            r.trimEnd = recipe.trimEnd
            if abs(r.speed - 1) < 0.01 { r.speed = recipe.speed }
            r.note = L("Ohne API-Key: passender eingebauter Stil.", "No API key: matching built-in style.")
            recipe = r
            return
        }
        aiStatus = L("KI schaut sich deinen Clip an …", "AI is looking at your clip …")
        do {
            let info = try await ReferenceAnalyzer.load(url: url)
            aiStatus = L("KI bearbeitet …", "AI is editing …")
            let r = try await ClaudeService.makeEdit(request: text, current: recipe, clip: info)
            recipe = r
            aiStatus = nil
            prompt = ""
        } catch {
            aiStatus = error.localizedDescription
        }
    }

    private func pasteCode() {
        if let text = UIPasteboard.general.string, let r = EditCode.decode(text) {
            recipe = r
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
        let r = recipe
        Task {
            do {
                let out = try await VideoEditor.export(url: url, recipe: r) { p in
                    DispatchQueue.main.async { progress = p }
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
