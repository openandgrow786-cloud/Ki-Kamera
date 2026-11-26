import SwiftUI

/// Alle Einstellungen, aufgebaut wie bei Profi-Kamera-Apps. Zweisprachig (Deutsch / English).
struct SettingsSheet: View {
    @ObservedObject var cam: CameraManager
    @Environment(\.dismiss) private var dismiss

    @AppStorage("lang") private var lang = Prefs.language
    @State private var langDraft = Prefs.language

    @AppStorage("recFade") private var recFade = "transparent"
    @AppStorage("dimWhileRecording") private var dimWhileRecording = false
    @AppStorage("volumeTrigger") private var volumeTrigger = true
    @AppStorage("lockWBOnRecord") private var lockWBOnRecord = true
    @AppStorage("timecodeMode") private var timecodeMode = "run"

    @AppStorage("lockOrientation") private var lockOrientation = false
    @AppStorage("mirrorFront") private var mirrorFront = true
    @AppStorage("shutterDisplay") private var shutterDisplay = "speed"
    @AppStorage("flicker") private var flicker = "50"
    @AppStorage("lensCorrection") private var lensCorrection = true

    @AppStorage("album") private var album = true

    @AppStorage("audioFormat") private var audioFormat = "aac"
    @AppStorage("stereo") private var stereo = true
    @AppStorage("windFilter") private var windFilter = true
    @AppStorage("meterScale") private var meterScale = "vu"

    @AppStorage("showMeters") private var showMeters = true
    @AppStorage("showBattery") private var showBattery = true
    @AppStorage("showStorage") private var showStorage = true
    @AppStorage("gridOpacity") private var gridOpacity = 0.25
    @AppStorage("frameOpacity") private var frameOpacity = 0.6
    @AppStorage("frameColor") private var frameColor = "gold"

    @State private var apiKey = Keychain.get(ClaudeService.keyName) ?? ""
    @State private var model = UserDefaults.standard.string(forKey: ClaudeService.modelKey) ?? ClaudeService.defaultModel
    @State private var confirmReset = false

    private func presetBinding<T>(_ get: @escaping (Preset) -> T, _ set: @escaping (inout Preset, T) -> Void) -> Binding<T> {
        Binding(get: { get(cam.preset) }, set: { v in cam.update { set(&$0, v) } })
    }

    private var colorSpace: Binding<String> {
        presetBinding({ $0.log ? "log" : ($0.hdr ? "hlg" : "709") }) { p, v in
            p.log = v == "log"
            p.hdr = v == "hlg"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Sprache", "Language"), selection: $langDraft) {
                        Text("Deutsch").tag("de")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(L("Sprache", "Language"))
                } footer: {
                    Text(L("Wird beim Schließen übernommen.", "Applied when you close settings."))
                }

                Section {
                    Picker("Codec", selection: presetBinding({ $0.codec }) { p, v in p.codec = v }) {
                        Text("HEVC (H.265)").tag("hevc")
                        Text("H.264").tag("h264")
                        Text("ProRes 422 HQ").tag("prores")
                    }
                    Picker(L("Auflösung", "Resolution"), selection: presetBinding({ $0.resolutionText }) { p, v in p.resolution = v }) {
                        Text("4K").tag("4K")
                        Text("1080p").tag("1080p")
                    }
                    Picker(L("Farbraum", "Color space"), selection: colorSpace) {
                        Text("Rec.709").tag("709")
                        Text("HDR (HLG)").tag("hlg")
                        Text("Apple Log").tag("log")
                    }
                    Picker(L("Stabilisierung", "Stabilization"), selection: presetBinding({ $0.stabilization }) { p, v in p.stabilization = v }) {
                        Text(L("Aus", "Off")).tag("off")
                        Text("Standard").tag("auto")
                        Text(L("Kino (stark)", "Cinematic (strong)")).tag("cinematic")
                    }
                    Picker("Countdown", selection: presetBinding({ $0.countdown }) { p, v in p.countdown = v }) {
                        Text(L("Aus", "Off")).tag(0)
                        Text("3 s").tag(3)
                        Text("5 s").tag(5)
                        Text("10 s").tag(10)
                    }
                    Picker(L("Maximale Länge", "Maximum length"), selection: presetBinding({ $0.maxDuration }) { p, v in p.maxDuration = v }) {
                        Text(L("Unbegrenzt", "Unlimited")).tag(0)
                        Text("15 s").tag(15)
                        Text("30 s").tag(30)
                        Text("60 s").tag(60)
                    }
                    Toggle(L("Raster", "Grid"), isOn: presetBinding({ $0.grid }) { p, v in p.grid = v })
                } header: {
                    Text(L("Aufzeichnen (aktueller Look)", "Record (current look)"))
                } footer: {
                    Text(L("Diese Werte gehören zum Look und werden mit „Looks“ gespeichert. Apple Log und ProRes sind für Profi-Farbkorrektur und brauchen viel Speicher.",
                           "These values belong to the look and are saved with \"Looks\". Apple Log and ProRes are for pro color grading and need a lot of storage."))
                }

                Section {
                    Picker(L("Knöpfe beim Filmen", "Buttons while recording"), selection: $recFade) {
                        Text("Transparent").tag("transparent")
                        Text(L("Ganz weg", "Hidden")).tag("hidden")
                        Text(L("Immer sichtbar", "Always visible")).tag("off")
                    }
                    Toggle(L("Bildschirm beim Filmen abdunkeln", "Dim screen while recording"), isOn: $dimWhileRecording)
                    Toggle(L("Lautstärke- oder Kamerataste startet Aufnahme", "Volume or Camera Control button starts recording"), isOn: $volumeTrigger)
                    Toggle(L("Weißabgleich beim Filmen fixieren", "Lock white balance while recording"), isOn: $lockWBOnRecord)
                    Picker(L("Timecode-Anzeige", "Timecode display"), selection: $timecodeMode) {
                        Text(L("Aufnahmezeit", "Record run")).tag("run")
                        Text(L("Tageszeit", "Time of day")).tag("tod")
                    }
                } header: {
                    Text(L("Aufnahme", "Recording"))
                } footer: {
                    Text(L("Tipp während der Aufnahme aufs Bild, dann kommen die Knöpfe für 3 Sekunden zurück.",
                           "Tap the image while recording to bring the buttons back for 3 seconds."))
                }

                Section(L("Kamera", "Camera")) {
                    Toggle(L("Aktuelle Ausrichtung fixieren", "Lock current orientation"), isOn: $lockOrientation)
                    Toggle(L("Frontkamera spiegeln", "Mirror front camera"), isOn: $mirrorFront)
                    Picker(L("Verschlusswert", "Shutter display"), selection: $shutterDisplay) {
                        Text(L("Zeit (1/96)", "Speed (1/96)")).tag("speed")
                        Text(L("Winkel (180°)", "Angle (180°)")).tag("angle")
                    }
                    Picker(L("Flimmerfreier Verschluss", "Flicker-free shutter"), selection: $flicker) {
                        Text("50 Hz").tag("50")
                        Text("60 Hz").tag("60")
                        Text(L("Aus", "Off")).tag("off")
                    }
                    Toggle(L("Objektivkorrektur", "Lens correction"), isOn: $lensCorrection)
                }

                Section {
                    Toggle(L("In Album „KI Kamera“ speichern", "Save to \"KI Kamera\" album"), isOn: $album)
                } header: {
                    Text(L("Medien", "Media"))
                } footer: {
                    Text(L("Videos und Fotos landen in deiner Mediathek und zusätzlich im eigenen Album.",
                           "Videos and photos go to your library and also into their own album."))
                }

                Section(L("Audio", "Audio")) {
                    Picker(L("Audioformat", "Audio format"), selection: $audioFormat) {
                        Text("AAC").tag("aac")
                        Text(L("PCM (unkomprimiert)", "PCM (uncompressed)")).tag("pcm")
                    }
                    Toggle(L("Stereo-Aufnahme", "Stereo recording"), isOn: $stereo)
                    Toggle(L("Windgeräusch-Filter", "Wind noise filter"), isOn: $windFilter)
                    Picker(L("Tonpegelmessung", "Audio meter"), selection: $meterScale) {
                        Text(L("VU (Durchschnitt)", "VU (average)")).tag("vu")
                        Text(L("PPM (Spitze)", "PPM (peak)")).tag("ppm")
                    }
                }

                Section(L("Monitoring", "Monitoring")) {
                    Toggle(L("Audiopegel anzeigen", "Show audio meters"), isOn: $showMeters)
                    Toggle(L("Akkustand anzeigen", "Show battery"), isOn: $showBattery)
                    Toggle(L("Speicherstatus anzeigen", "Show storage"), isOn: $showStorage)
                    VStack(alignment: .leading) {
                        Text(L("Rasteropazität", "Grid opacity") + " \(Int(gridOpacity * 100)) %")
                        Slider(value: $gridOpacity, in: 0.05...0.8)
                    }
                    Picker(L("Rahmenfarbe", "Frame color"), selection: $frameColor) {
                        Text("Gold").tag("gold")
                        Text(L("Weiß", "White")).tag("white")
                        Text(L("Rot", "Red")).tag("red")
                        Text("Cyan").tag("cyan")
                    }
                    VStack(alignment: .leading) {
                        Text(L("Rahmenopazität", "Frame opacity") + " \(Int(frameOpacity * 100)) %")
                        Slider(value: $frameOpacity, in: 0.1...1)
                    }
                }

                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("Modell", "Model"), text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude API")
                } footer: {
                    Text(L("Damit versteht die KI freie Wünsche und analysiert Videos direkt in der App. Key auf console.anthropic.com, jede Analyse kostet ein paar Cent. Ohne Key gehen Vorschläge, einfache Befehle und Preset-Codes aus dem Chat.",
                           "With this the AI understands free requests and analyzes videos right in the app. Get a key at console.anthropic.com; each analysis costs a few cents. Without a key, suggestions, simple commands and preset codes from the chat still work."))
                }

                Section(L("Zurücksetzen", "Reset")) {
                    Button(L("Alle Einstellungen zurücksetzen", "Reset all settings"), role: .destructive) { confirmReset = true }
                }

                Section("Info") {
                    LabeledContent("Version", value: "3.0")
                    LabeledContent(L("Eigene Looks und Stile", "Your looks and styles"), value: L("auf diesem iPhone", "on this iPhone"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .tint(Theme.gold)
            .navigationTitle(L("Einstellungen", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Fertig", "Done")) { close() }.fontWeight(.semibold)
                }
            }
            .alert(L("Alles zurücksetzen?", "Reset everything?"), isPresented: $confirmReset) {
                Button(L("Zurücksetzen", "Reset"), role: .destructive) {
                    Prefs.reset()
                    cam.reloadPrefs()
                    dismiss()
                }
                Button(L("Abbrechen", "Cancel"), role: .cancel) {}
            } message: {
                Text(L("Deine gespeicherten Looks und Stile bleiben erhalten.", "Your saved looks and styles are kept."))
            }
        }
    }

    private func close() {
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: ClaudeService.keyName)
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ClaudeService.modelKey)
        cam.reloadPrefs()
        dismiss()
        if langDraft != lang {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { lang = langDraft }
        }
    }
}
