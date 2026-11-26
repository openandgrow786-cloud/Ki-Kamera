import SwiftUI

/// Deine gespeicherten Looks und die eingebauten. Tippen = anwenden.
struct LooksSheet: View {
    let current: Preset
    var onApply: (Preset) -> Void

    @EnvironmentObject private var library: LookLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var showSave = false
    @State private var saveName = ""
    @State private var renaming: SavedLook?
    @State private var renameText = ""
    @State private var copied: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Looks").font(Theme.ui(24, .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.muted)
                                .frame(width: 38, height: 38).glass(19)
                        }
                        .accessibilityLabel("Schließen")
                    }

                    Button {
                        saveName = current.name
                        showSave = true
                    } label: {
                        Label("Aktuelle Einstellungen speichern", systemImage: "plus")
                    }
                    .buttonStyle(GoldButtonStyle())

                    SectionLabel(text: "Meine Looks")
                    if library.looks.isEmpty {
                        Text("Noch keine eigenen Looks. Stell die Kamera ein (oder lass die KI das machen) und speichere sie, z. B. als „Nachtmodus“.")
                            .font(Theme.ui(13))
                            .foregroundStyle(Theme.muted)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(library.looks) { look in
                                LookCard(preset: look.preset, active: look.preset.name == current.name, custom: true) {
                                    onApply(look.preset)
                                }
                                .contextMenu {
                                    Button {
                                        renameText = look.preset.name
                                        renaming = look
                                    } label: { Label("Umbenennen", systemImage: "pencil") }
                                    Button {
                                        UIPasteboard.general.string = PresetCode.encode(look.preset)
                                        copied = look.preset.name
                                    } label: { Label("Code kopieren", systemImage: "doc.on.doc") }
                                    Button(role: .destructive) {
                                        withAnimation { library.delete(look) }
                                    } label: { Label("Löschen", systemImage: "trash") }
                                }
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }

                    SectionLabel(text: "Eingebaut")
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Preset.builtIn, id: \.name) { preset in
                            LookCard(preset: preset, active: preset.name == current.name, custom: false) {
                                onApply(preset)
                            }
                        }
                    }

                    if let copied {
                        Text("Code von „\(copied)“ kopiert.").font(Theme.ui(12)).foregroundStyle(Theme.cyan)
                    }
                    Text("Tipp: Lange drücken zum Umbenennen, Teilen als Code oder Löschen.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
                .padding(20)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: library.looks)
            }
        }
        .alert("Look speichern", isPresented: $showSave) {
            TextField("Name, z. B. Nachtmodus", text: $saveName)
            Button("Speichern") { withAnimation { library.save(current, as: saveName) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("OK") {
                if let r = renaming { library.rename(r, to: renameText) }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
    }
}

struct LookCard: View {
    let preset: Preset
    let active: Bool
    let custom: Bool
    var action: () -> Void

    private var icon: String {
        if preset.isPhoto { return "camera.aperture" }
        switch preset.lens {
        case .front: return "person.crop.circle"
        case .ultra: return "square.dashed"
        case .tele: return "scope"
        default: return "video"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(custom ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.cyan))
                    Spacer()
                    if active {
                        Text("AKTIV").font(Theme.mono(9, .heavy)).foregroundStyle(Theme.bg)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.goldGradient))
                    }
                }
                Text(preset.name)
                    .font(Theme.ui(16, .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(preset.summary)
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .padding(14)
            .glass(18, glow: active ? Theme.gold : nil)
        }
        .buttonStyle(.plain)
    }
}

/// Einstellungen: Claude API-Key und Modell.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("recFade") private var recFade = "transparent"
    @State private var apiKey = Keychain.get(ClaudeService.keyName) ?? ""
    @State private var model = UserDefaults.standard.string(forKey: ClaudeService.modelKey) ?? ClaudeService.defaultModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Modell", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude API")
                } footer: {
                    Text("Damit versteht die KI freie Wünsche und analysiert Referenzvideos und Clips direkt in der App. Den Key bekommst du auf console.anthropic.com, jede Analyse kostet ein paar Cent. Ohne Key funktionieren Vorschläge, einfache Befehle und Preset-Codes aus dem Chat.")
                }
                Section {
                    Picker("Knöpfe beim Filmen", selection: $recFade) {
                        Text("Transparent").tag("transparent")
                        Text("Ganz weg").tag("hidden")
                        Text("Immer sichtbar").tag("off")
                    }
                } header: {
                    Text("Aufnahme")
                } footer: {
                    Text("Während der Aufnahme blenden die Knöpfe weich aus. Tipp aufs Bild, dann kommen sie für 3 Sekunden zurück. Der Aufnahmeknopf bleibt immer sichtbar.")
                }
                Section("Info") {
                    LabeledContent("Version", value: "2.1")
                    LabeledContent("Eigene Looks und Stile", value: "auf diesem iPhone gespeichert")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: ClaudeService.keyName)
                        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ClaudeService.modelKey)
                        dismiss()
                    }
                }
            }
        }
    }
}
