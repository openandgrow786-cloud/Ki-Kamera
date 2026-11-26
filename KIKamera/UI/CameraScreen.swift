import SwiftUI

enum SheetKind: String, Identifiable {
    case ai, looks, settings
    var id: String { rawValue }
}

struct CameraScreen: View {
    @StateObject private var cam = CameraManager()
    @EnvironmentObject private var library: LookLibrary
    @Namespace private var ns

    @State private var activeParam: CameraParam?
    @State private var sheet: SheetKind?
    @State private var showEditor = false
    @State private var highlight = false
    @State private var scanTrigger = 0
    @State private var countdown: Int?
    @State private var recPulse = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                paramStrip
                viewfinder
                lensRow
                modeSwitch
                bottomBar
            }

            if let param = activeParam {
                ParamPanel(param: param, cam: cam) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { activeParam = nil }
                }
                .padding(.bottom, 128)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }

            if let n = countdown {
                Text("\(n)")
                    .font(.system(size: 150, weight: .thin, design: .rounded))
                    .foregroundStyle(Theme.goldGradient)
                    .shadow(color: Theme.gold.opacity(0.6), radius: 30)
                    .id(n)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .zIndex(3)
            }
        }
        .statusBarHidden(true)
        .onAppear { cam.start() }
        .sensoryFeedback(.impact(weight: .medium), trigger: cam.isRecording)
        .sensoryFeedback(.selection, trigger: cam.preset.name)
        .sheet(item: $sheet) { kind in
            switch kind {
            case .ai:
                AISheet(current: cam.preset) { preset in applyLook(preset) }
                    .presentationDetents([.large])
            case .looks:
                LooksSheet(current: cam.preset) { preset in applyLook(preset) }
                    .presentationDetents([.medium, .large])
            case .settings:
                SettingsSheet()
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            EditorScreen()
        }
    }

    private func applyLook(_ preset: Preset) {
        sheet = nil
        cam.apply(preset)
        scanTrigger += 1
        withAnimation(.easeOut(duration: 0.3)) { highlight = true }
        cam.message = "Look aktiv: \(preset.name)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.6)) { highlight = false }
        }
    }

    // MARK: Kopfzeile

    private var timecode: String {
        String(format: "%02d:%02d:%02d:00", cam.seconds / 3600, (cam.seconds / 60) % 60, cam.seconds % 60)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(cam.preset.isPhoto ? "FOTO" : cam.preset.resolutionText)
                    .font(Theme.mono(12, .heavy))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                Text(cam.preset.isPhoto ? "HEIF" : "16:9")
                    .font(Theme.mono(8, .bold))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(Theme.goldGradient)
            }
            .fixedSize()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.gold, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if cam.isRecording {
                        Circle().fill(Theme.rec).frame(width: 8, height: 8)
                            .opacity(recPulse ? 1 : 0.25)
                            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { recPulse = true } }
                            .onDisappear { recPulse = false }
                    }
                    Text(timecode)
                        .font(Theme.mono(24, .bold))
                        .foregroundStyle(cam.isRecording ? Theme.rec : Theme.text)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: cam.seconds)
                }
                Text("\(cam.preset.codec.uppercased()) · \(cam.preset.hdr ? "HLG HDR" : "SDR") · \(cam.preset.stabilization == "cinematic" ? "STAB+" : "STAB")")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.muted)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: batteryIcon).font(.system(size: 11))
                    Text("\(Int(cam.battery * 100))%").font(Theme.mono(10, .bold))
                }
                .foregroundStyle(cam.battery < 0.2 ? Theme.rec : Theme.text)
                Text(String(format: "%.0f GB", cam.freeGB)).font(Theme.mono(10, .bold)).foregroundStyle(Theme.muted)
            }

            Button { sheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Einstellungen")
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var batteryIcon: String {
        switch cam.battery {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Werte-Leiste

    private func value(for param: CameraParam) -> (String, Bool) {
        let p = cam.preset
        switch param {
        case .fps: return (p.isPhoto ? "—" : p.fpsText, false)
        case .shutter: return (p.shutterText, false)
        case .ev: return (p.evText, false)
        case .iso: return (p.iso == nil ? "\(cam.liveISO)" : p.isoText, p.iso == nil)
        case .wb: return (p.whiteBalance == nil ? "AWB" : p.wbText, p.whiteBalance == nil)
        case .tint: return (p.tintText, false)
        }
    }

    private var paramStrip: some View {
        HStack(spacing: 0) {
            ForEach(CameraParam.allCases) { param in
                let v = value(for: param)
                let selected = activeParam == param
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        activeParam = selected ? nil : param
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 3) {
                            Text(param.label).font(Theme.mono(9, .bold)).foregroundStyle(Theme.muted)
                            if v.1 {
                                Text("A").font(Theme.mono(8, .heavy)).foregroundStyle(Theme.bg)
                                    .padding(.horizontal, 3)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.cyan))
                            }
                        }
                        Text(v.0)
                            .font(Theme.mono(16, .bold))
                            .foregroundStyle(highlight || selected ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.text))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: v.0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Theme.gold.opacity(0.12))
                                .matchedGeometryEffect(id: "paramSel", in: ns)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glass(14)
        .padding(.horizontal, 10)
    }

    // MARK: Sucher

    private var viewfinder: some View {
        ZStack {
            if cam.cameraDenied {
                Text("Kein Kamerazugriff. Erlaube ihn in den iPhone-Einstellungen unter KI Kamera.")
                    .font(Theme.ui(15))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)
                    .padding(30)
            } else {
                CameraPreview(cam: cam, version: cam.configVersion)
            }

            if cam.preset.grid { GridOverlay() }

            if let pt = cam.focusPoint {
                FocusBox(point: pt).id("\(pt.x)-\(pt.y)")
            }

            ScanSweep(trigger: scanTrigger)

            VStack {
                HStack(alignment: .top) {
                    lookChip
                    Spacer()
                    Text(String(format: "%.1f×", cam.liveZoom))
                        .font(Theme.mono(12, .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glass(12)
                        .contentTransition(.numericText())
                }
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if cam.isRecording {
                            HStack(spacing: 6) {
                                Circle().fill(Color.white).frame(width: 7, height: 7)
                                Text("REC").font(Theme.mono(12, .heavy))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.rec, in: RoundedRectangle(cornerRadius: 6))
                            .transition(.scale.combined(with: .opacity))
                        }
                        if let msg = cam.message {
                            Text(msg)
                                .font(Theme.ui(13, .semibold))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .glass(12, glow: Theme.cyan)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    Spacer()
                    if !cam.preset.isPhoto {
                        AudioMeter(levels: cam.audioLevels, peaks: cam.audioPeaks)
                    }
                }
            }
            .padding(12)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: cam.message)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: cam.isRecording)

            if cam.photoFlash {
                Color.white.opacity(0.85).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(cam.isRecording ? AnyShapeStyle(Theme.rec) : AnyShapeStyle(Theme.hairline),
                              lineWidth: cam.isRecording ? 2 : 1)
        )
        .shadow(color: cam.isRecording ? Theme.rec.opacity(0.35) : .clear, radius: 18)
        .padding(.horizontal, 10)
    }

    private var lookChip: some View {
        Button { sheet = .looks } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.aiGradient)
                Text(cam.preset.name).lineLimit(1)
            }
            .font(Theme.ui(12, .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .glass(14, glow: highlight ? Theme.cyan : nil)
        }
        .buttonStyle(.plain)
    }

    // MARK: Objektive, Modus, Knöpfe

    private var lensRow: some View {
        HStack(spacing: 4) {
            ForEach(Lens.allCases) { lens in
                let on = cam.preset.lens == lens
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { cam.setLens(lens) }
                } label: {
                    Text(lens.label)
                        .font(Theme.mono(12, .bold))
                        .foregroundStyle(on ? Color.black : Theme.text.opacity(0.85))
                        .frame(width: 58, height: 40)
                        .background {
                            if on {
                                Capsule().fill(Theme.goldGradient)
                                    .matchedGeometryEffect(id: "lens", in: ns)
                                    .shadow(color: Theme.gold.opacity(0.5), radius: 8)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(cam.isRecording)
                .accessibilityLabel("Objektiv \(lens.focal)")
            }
        }
        .padding(4)
        .glass(24)
    }

    private var modeSwitch: some View {
        HStack(spacing: 28) {
            ForEach(["video", "photo"], id: \.self) { mode in
                let on = cam.preset.mode == mode
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        cam.update { $0.mode = mode }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Text(mode == "video" ? "VIDEO" : "FOTO")
                            .font(Theme.mono(12, .heavy))
                            .tracking(2)
                            .foregroundStyle(on ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.muted))
                        ZStack {
                            if on {
                                Capsule().fill(Theme.goldGradient).frame(width: 18, height: 3)
                                    .matchedGeometryEffect(id: "mode", in: ns)
                            }
                        }
                        .frame(height: 3)
                    }
                    .frame(minWidth: 60, minHeight: 32)
                }
                .buttonStyle(.plain)
                .disabled(cam.isRecording)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            sideButton(icon: "square.stack.3d.up", label: "Looks") { sheet = .looks }
            Spacer()
            Button { sheet = .ai } label: {
                VStack(spacing: 3) {
                    AIOrb(size: 50)
                    Text("KI").font(Theme.mono(10, .heavy)).foregroundStyle(Theme.cyan)
                }
            }
            .buttonStyle(.plain)
            .disabled(cam.isRecording)
            .accessibilityLabel("KI fragen")
            Spacer()
            recordButton
            Spacer()
            sideButton(icon: "wand.and.stars", label: "Studio") { showEditor = true }
            Spacer()
            sideButton(icon: "photo.on.rectangle", label: "Clips") {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func sideButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 48, height: 48)
                    .glass(16)
                Text(label).font(Theme.mono(9, .bold)).foregroundStyle(Theme.muted)
            }
            .foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain)
        .disabled(cam.isRecording)
    }

    private var recordButton: some View {
        Button(action: shutterPressed) {
            ZStack {
                Circle()
                    .strokeBorder(cam.isRecording ? AnyShapeStyle(Theme.rec) : AnyShapeStyle(Theme.goldGradient), lineWidth: 3)
                    .frame(width: 80, height: 80)
                    .shadow(color: (cam.isRecording ? Theme.rec : Theme.gold).opacity(0.5), radius: 12)
                if cam.isRecording {
                    Circle()
                        .stroke(Theme.rec.opacity(0.5), lineWidth: 2)
                        .frame(width: 80, height: 80)
                        .scaleEffect(recPulse ? 1.25 : 1)
                        .opacity(recPulse ? 0 : 1)
                }
                RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 32, style: .continuous)
                    .fill(cam.preset.isPhoto ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.rec))
                    .frame(width: cam.isRecording ? 30 : 64, height: cam.isRecording ? 30 : 64)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: cam.isRecording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cam.preset.isPhoto ? "Foto aufnehmen" : (cam.isRecording ? "Aufnahme stoppen" : "Aufnahme starten"))
    }

    private func shutterPressed() {
        if activeParam != nil {
            withAnimation { activeParam = nil }
        }
        if cam.isRecording {
            cam.toggleRecording()
            return
        }
        guard countdown == nil else { return }
        let seconds = cam.preset.countdown
        let action = { cam.preset.isPhoto ? cam.takePhoto() : cam.toggleRecording() }
        guard seconds > 0 else { action(); return }
        for i in 0..<seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { countdown = seconds - i }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds)) {
            withAnimation { countdown = nil }
            action()
        }
    }
}
