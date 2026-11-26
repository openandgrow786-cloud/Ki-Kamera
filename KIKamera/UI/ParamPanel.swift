import SwiftUI

enum CameraParam: String, CaseIterable, Identifiable {
    case fps, shutter, ev, iso, wb, tint

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fps: return "FPS"
        case .shutter: return L("VERSCHL.", "SHUTTER")
        case .ev: return L("BELICHT.", "EXPOS.")
        case .iso: return "ISO"
        case .wb: return "WB"
        case .tint: return "TINT"
        }
    }

    var title: String {
        switch self {
        case .fps: return L("Bildrate", "Frame rate")
        case .shutter: return L("Verschlusszeit", "Shutter")
        case .ev: return L("Belichtung", "Exposure")
        case .iso: return "ISO"
        case .wb: return L("Weißabgleich", "White balance")
        case .tint: return "Tint"
        }
    }
}

struct ChipItem: Identifiable {
    let label: String
    let selected: Bool
    let action: () -> Void
    var id: String { label }
}

/// Manueller Regler für einen Wert, gleitet von unten herein.
struct ParamPanel: View {
    let param: CameraParam
    @ObservedObject var cam: CameraManager
    var close: () -> Void

    private var p: Preset { cam.preset }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: param.title)
                Spacer()
                Text(valueText)
                    .font(Theme.mono(22, .bold))
                    .foregroundStyle(Theme.goldGradient)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: valueText)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .accessibilityLabel(L("Schließen", "Close"))
            }
            content
        }
        .padding(18)
        .glass(26, glow: Theme.gold)
        .padding(.horizontal, 10)
    }

    private var valueText: String {
        switch param {
        case .fps: return p.fpsText
        case .shutter: return p.shutterText
        case .ev: return p.evText
        case .iso: return p.iso == nil ? "A \(cam.liveISO)" : p.isoText
        case .wb: return p.wbText
        case .tint: return p.tintText
        }
    }

    @ViewBuilder private var content: some View {
        switch param {
        case .fps:
            chips(fpsItems)
            hint(L("Verschluss passt sich automatisch an (180°-Regel, flimmerfrei).", "Shutter follows automatically (180° rule, flicker-free)."))

        case .shutter:
            chips(shutterItems)
            ValueSlider(label: L("Fein", "Fine"), value: shutterBinding, range: log2(24.0)...log2(4000.0), step: 0.05,
                        format: { v in "1/\(Int(pow(2, v).rounded()))" })

        case .ev:
            ValueSlider(label: L("Helligkeit", "Brightness"), value: evBinding, range: -2...2, step: 0.1,
                        format: { v in v == 0 ? "±0" : String(format: "%+.1f EV", v) })
            hint("Die Blende ist beim iPhone fest (f/\(String(format: "%.2g", cam.aperture))). Hier regelst du die Helligkeit.")

        case .iso:
            chips(isoItems)
            ValueSlider(label: L("Manuell", "Manual"), value: isoBinding,
                        range: log2(cam.isoRange.lowerBound)...log2(cam.isoRange.upperBound), step: 0.05,
                        format: { v in "\(Int(pow(2, v).rounded()))" })
            hint(L("Auto hält den Verschluss fest und regelt nur ISO nach.", "Auto keeps the shutter fixed and only adjusts ISO."))

        case .wb:
            chips(wbItems)
            ValueSlider(label: "Kelvin", value: wbBinding, range: 2500...10000, step: 50,
                        format: { v in "\(Int(v))K" })

        case .tint:
            ValueSlider(label: L("Grün ↔ Magenta", "Green ↔ Magenta"), value: tintBinding, range: -50...50, step: 1,
                        format: { v in "\(Int(v))" })
            chips(tintItems)
        }
    }

    // MARK: Chips

    private var fpsItems: [ChipItem] {
        let values: [Int] = [24, 25, 30, 48, 50, 60, 100, 120]
        return values.map { v in
            ChipItem(label: "\(v)", selected: abs(p.fps - Double(v)) < 0.01) {
                cam.update { preset in
                    preset.fps = Double(v)
                    preset.shutter = Prefs.flickerSafe(Double(v * 2), fps: Double(v))
                }
            }
        }
    }

    private var shutterItems: [ChipItem] {
        var items: [ChipItem] = [
            ChipItem(label: "180°", selected: abs(p.shutter - p.fps * 2) < 0.5) {
                cam.update { preset in preset.shutter = Prefs.flickerSafe(preset.fps * 2, fps: preset.fps) }
            }
        ]
        let values: [Int] = [48, 50, 60, 96, 100, 120, 250, 500, 1000, 2000]
        for v in values {
            items.append(ChipItem(label: "1/\(v)", selected: abs(p.shutter - Double(v)) < 0.5) {
                cam.update { preset in preset.shutter = Double(v) }
            })
        }
        return items
    }

    private var isoItems: [ChipItem] {
        var items: [ChipItem] = [
            ChipItem(label: "Auto", selected: p.iso == nil) { cam.update { preset in preset.iso = nil } }
        ]
        let values: [Int] = [100, 200, 400, 800, 1600, 3200]
        for v in values {
            items.append(ChipItem(label: "\(v)", selected: p.iso == Double(v)) {
                cam.update { preset in preset.iso = Double(v) }
            })
        }
        return items
    }

    private var wbItems: [ChipItem] {
        var items: [ChipItem] = [
            ChipItem(label: "Auto", selected: p.whiteBalance == nil) { cam.update { preset in preset.whiteBalance = nil } }
        ]
        let values: [(Int, String)] = [(3200, L("Glühbirne", "Tungsten")), (4000, "Neon"), (5600, L("Sonne", "Daylight")), (6500, L("Wolken", "Cloudy")), (7500, L("Schatten", "Shade"))]
        for (k, name) in values {
            items.append(ChipItem(label: name, selected: p.whiteBalance == Double(k)) {
                cam.update { preset in preset.whiteBalance = Double(k) }
            })
        }
        return items
    }

    private var tintItems: [ChipItem] {
        let values: [Int] = [-20, -10, 0, 10, 20]
        return values.map { v in
            ChipItem(label: "\(v)", selected: Int(p.tint.rounded()) == v) {
                cam.update { preset in preset.tint = Double(v) }
            }
        }
    }

    // MARK: Regler

    private var shutterBinding: Binding<Double> {
        Binding(get: { log2(p.shutter) },
                set: { v in cam.update { preset in preset.shutter = pow(2, v).rounded() } })
    }

    private var evBinding: Binding<Double> {
        Binding(get: { p.exposureBias },
                set: { v in cam.update { preset in preset.exposureBias = (v * 10).rounded() / 10 } })
    }

    private var isoBinding: Binding<Double> {
        Binding(get: { log2(p.iso ?? Double(max(cam.liveISO, 50))) },
                set: { v in cam.update { preset in preset.iso = pow(2, v).rounded() } })
    }

    private var wbBinding: Binding<Double> {
        Binding(get: { p.whiteBalance ?? 5600 },
                set: { v in cam.update { preset in preset.whiteBalance = (v / 50).rounded() * 50 } })
    }

    private var tintBinding: Binding<Double> {
        Binding(get: { p.tint },
                set: { v in cam.update { preset in preset.tint = v.rounded() } })
    }

    private func chips(_ items: [ChipItem]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(items) { item in
                Chip(text: item.label, selected: item.selected, action: item.action)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Theme.ui(12)).foregroundStyle(Theme.muted)
    }
}
