# KI Kamera

iPhone-Kamera-App, die sich per KI selbst einstellt. Du zeigst ein Referenzvideo oder beschreibst den Look, die App setzt Objektiv, FPS, Verschluss, Weißabgleich, HDR und regelt ISO automatisch. Danach nur noch Aufnahme drücken.

## App bekommen (ohne Mac)

1. Jeder Push auf `main` baut die App automatisch (Tab **Actions**).
2. Im fertigen Lauf unten unter **Artifacts** `KIKamera-ipa` herunterladen und entpacken.
3. `KIKamera.ipa` in **Sideloadly** ziehen, iPhone per Kabel anschließen, Apple-ID eingeben, **Start**.
4. Auf dem iPhone: Einstellungen > Datenschutz & Sicherheit > **Entwicklermodus** an (Neustart).
5. Einstellungen > Allgemein > VPN & Geräteverwaltung > deiner Apple-ID **vertrauen**.

Mit einer kostenlosen Apple-ID läuft die App 7 Tage, danach in Sideloadly einfach nochmal installieren.

## KI nutzen

- **Ohne Kosten:** Referenzvideo an Claude im Chat schicken, Preset-Code kopieren, in der App auf **KI > Preset-Code einfügen**.
- **Direkt in der App:** Claude API-Key unter dem Zahnrad eintragen. Dann analysiert die App Referenzvideos selbst.

## Aufbau

| Datei | Aufgabe |
|---|---|
| `CameraManager.swift` | Kamera-Steuerung mit AVFoundation, Auto-ISO bei festem Verschluss, Aufnahme |
| `ClaudeService.swift` | Referenzvideo auslesen, Claude API, Keychain |
| `Preset.swift` | Look-Daten, eingebaute Looks, Preset-Codes |
| `ContentView.swift` | Kamera-Bildschirm |
| `KISheet.swift` | KI-Fenster |
| `SettingsView.swift` | API-Key und Preset-Code kopieren |
