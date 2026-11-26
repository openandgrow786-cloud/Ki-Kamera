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
                        .accessibilityLabel(L("Schließen", "Close"))
                    }

                    Button {
                        saveName = current.name
                        showSave = true
                    } label: {
                        Label(L("Aktuelle Einstellungen speichern", "Save current settings"), systemImage: "plus")
                    }
                    .buttonStyle(GoldButtonStyle())

                    SectionLabel(text: L("Meine Looks", "My looks"))
                    if library.looks.isEmpty {
                        Text(L("Noch keine eigenen Looks. Stell die Kamera ein (oder lass die KI das machen) und speichere sie, z. B. als „Nachtmodus“.", "No looks of your own yet. Set up the camera (or let the AI do it) and save it, e.g. as \"Night mode\"."))
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
                                    } label: { Label(L("Umbenennen", "Rename"), systemImage: "pencil") }
                                    Button {
                                        UIPasteboard.general.string = PresetCode.encode(look.preset)
                                        copied = look.preset.name
                                    } label: { Label(L("Code kopieren", "Copy code"), systemImage: "doc.on.doc") }
                                    Button(role: .destructive) {
                                        withAnimation { library.delete(look) }
                                    } label: { Label(L("Löschen", "Delete"), systemImage: "trash") }
                                }
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }

                    SectionLabel(text: L("Eingebaut", "Built-in"))
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Preset.builtIn, id: \.name) { preset in
                            LookCard(preset: preset, active: preset.name == current.name, custom: false) {
                                onApply(preset)
                            }
                        }
                    }

                    if let copied {
                        Text(L("Code von „\(copied)“ kopiert.", "Code of \"\(copied)\" copied.")).font(Theme.ui(12)).foregroundStyle(Theme.cyan)
                    }
                    Text(L("Tipp: Lange drücken zum Umbenennen, Teilen als Code oder Löschen.", "Tip: Long-press to rename, share as code or delete."))
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
                .padding(20)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: library.looks)
            }
        }
        .alert(L("Look speichern", "Save look"), isPresented: $showSave) {
            TextField(L("Name, z. B. Nachtmodus", "Name, e.g. Night mode"), text: $saveName)
            Button(L("Speichern", "Save")) { withAnimation { library.save(current, as: saveName) } }
            Button(L("Abbrechen", "Cancel"), role: .cancel) {}
        }
        .alert(L("Umbenennen", "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("OK") {
                if let r = renaming { library.rename(r, to: renameText) }
                renaming = nil
            }
            Button(L("Abbrechen", "Cancel"), role: .cancel) { renaming = nil }
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
                        Text(L("AKTIV", "ACTIVE")).font(Theme.mono(9, .heavy)).foregroundStyle(Theme.bg)
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
