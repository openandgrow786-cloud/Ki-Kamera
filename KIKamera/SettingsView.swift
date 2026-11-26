import SwiftUI

struct SettingsView: View {
    static let keyName = "claudeApiKey"
    static let modelKey = "claudeModel"
    static let defaultModel = "claude-sonnet-5-5"

    let current: Preset

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = Keychain.get(SettingsView.keyName) ?? ""
    @State private var model = UserDefaults.standard.string(forKey: SettingsView.modelKey) ?? SettingsView.defaultModel
    @State private var copied = false

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
                    Text("Nur nötig, wenn die App Videos selbst analysieren soll. Den Key bekommst du auf console.anthropic.com. Ohne Key funktionieren Preset-Codes aus dem Chat.")
                }

                Section("Aktueller Look") {
                    Text(current.name)
                    Button(copied ? "Kopiert" : "Preset-Code kopieren") {
                        UIPasteboard.general.string = PresetCode.encode(current)
                        copied = true
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keyName)
                        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelKey)
                        dismiss()
                    }
                }
            }
        }
    }
}
