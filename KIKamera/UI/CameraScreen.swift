import SwiftUI

enum SheetKind: String, Identifiable {
    case ai, looks, settings
    var id: String { rawValue }
}

extension View {
    /// Knöpfe beim Filmen weich ausblenden.
    func recFade(_ hidden: Bool, mode: String, dy: CGFloat) -> some View {
        self
            .opacity(hidden ? (mode == "hidden" ? 0 : 0.18) : 1)
            .offset(y: hidden ? dy : 0)
            .scaleEffect(hidden ? 0.97 : 1)
            .allowsHitTesting(!hidden)
            .animation(.spring(response: 0.7, dampingFraction: 0.85), value: hidden)
    }
}

struct CameraScreen: View {
    @ObservedObject var cam: CameraManager
    @EnvironmentObject private var library: LookLibrary
    @AppStorage("recFade") private var recFade = "transparent"
    @AppStorage("dimWhileRecording") private var dimWhileRecording = false
    @AppStorage("timecodeMode") private var timecodeMode = "run"
    @AppStorage("showMeters") private var showMeters = true
    @AppStorage("showBattery") private var showBattery = true
    @AppStorage("showStorage") private var showStorage = true
    @AppStorage("gridOpacity") private var gridOpacity = 0.25
    @AppStorage("frameOpacity") private var frameOpacity = 0.6
    @AppStorage("frameColor") private var frameColor = "gold"
    @Namespace private var ns

    @State private var activeParam: CameraParam?
    @State private var sheet: SheetKind?
    @State private var showEditor = false
    @State private var highlight = false
    @State private var scanTrigger = 0
    @State private var countdown: Int?
    @State private var recPulse = false
    @State private var revealed = false
    @State private var showRevealHint = false

    private var uiHidden: Bool { cam.isRecording && !revealed && recFade != "off" }
    private var iconAngle: Angle { .degrees(cam.uiRotation) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            viewfinder.ignoresSafeArea()

            if uiHidden {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { reveal() }
            }

            VStack(spacing: 8) {
                VStack(spacing: 8) {
                    topBar
                    paramStrip
                    chipsRow
                }
                .recFade(uiHidden, mode: recFade, dy: -12)

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    messages
                    Spacer()
                    if !cam.preset.isPhoto && showMeters {
                        AudioMeter(levels: cam.audioLevels, peaks: cam.audioPeaks)
                            .opacity(uiHidden ? 0.55 : 1)
                            .animation(.easeInOut(duration: 0.6), value: uiHidden)
                    }
                }
                .padding(.horizontal, 12)

                VStack(spacing: 10) {
                    aspectPicker
                    lensRow
                }
                .recFade(uiHidden, mode: recFade, dy: 12)

                bottomBar
            }

            if cam.isRecording {
                VStack {
                    HStack(spacing: 7) {
                        Circle().fill(Color.white).frame(width: 7, height: 7).opacity(recPulse ? 1 : 0.3)
                        Text(timecode).font(Theme.mono(13, .heavy)).monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.rec.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: Theme.rec.opacity(0.5), radius: 14)
                    .rotationEffect(iconAngle)
                    .padding(.top, 6)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
                .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { recPulse = true } }
                .onDisappear { recPulse = false }
            }

            if showRevealHint {
                Text(L("Tippe aufs Bild, um die Knöpfe kurz zu zeigen", "Tap the image to show the buttons briefly"))
                    .font(Theme.ui(13, .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glass(14)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .allowsHitTesting(false)
            }

            if let param = activeParam, !uiHidden {
                VStack {
                    Spacer()
                    ParamPanel(param: param, cam: cam) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { activeParam = nil }
                    }
                    .padding(.bottom, 214)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }

            if let n = countdown {
                Text("\(n)")
                    .font(.system(size: 150, weight: .thin, design: .rounded))
                    .foregroundStyle(Theme.goldGradient)
                    .shadow(color: Theme.gold.opacity(0.6), radius: 30)
                    .rotationEffect(iconAngle)
                    .id(n)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(3)
            }

            if cam.processing {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.gold)
                        Text(L("Format wird zugeschnitten …", "Cropping to format …")).font(Theme.ui(13, .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glass(14)
                    .padding(.bottom, 230)
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: cam.isRecording)
        .animation(.easeInOut(duration: 0.3), value: showRevealHint)
        .animation(.easeInOut(duration: 0.3), value: cam.processing)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: cam.uiRotation)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { cam.start() }
        .onChange(of: cam.isRecording) { _, recording in
            revealed = false
            if recording && recFade != "off" {
                activeParam = nil
                showRevealHint = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { showRevealHint = false }
            } else {
                showRevealHint = false
            }
        }
        .onChange(of: cam.shutterRequests) { _, _ in shutterPressed() }
        .sensoryFeedback(.impact(weight: .medium), trigger: cam.isRecording)
        .sensoryFeedback(.selection, trigger: cam.preset.name)
        .sensoryFeedback(.selection, trigger: cam.preset.aspect)
        .sheet(item: $sheet) { kind in
            switch kind {
            case .ai:
                AISheet(current: cam.preset) { preset in applyLook(preset) }
                    .presentationDetents([.large])
            case .looks:
                LooksSheet(current: cam.preset) { preset in applyLook(preset) }
                    .presentationDetents([.medium, .large])
            case .settings:
                SettingsSheet(cam: cam)
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            EditorScreen()
        }
    }

    private func reveal() {
        showRevealHint = false
        revealed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { revealed = false }
    }

    private func applyLook(_ preset: Preset) {
        sheet = nil
        cam.apply(preset)
        scanTrigger += 1
        withAnimation(.easeOut(duration: 0.3)) { highlight = true }
        cam.message = L("Look aktiv: ", "Look active: ") + preset.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.6)) { highlight = false }
        }
    }

    // MARK: Sucher (Vollbild)

    private var viewfinder: some View {
        ZStack {
            if cam.cameraDenied {
                Text(L("Kein Kamerazugriff. Erlaube ihn in den iPhone-Einstellungen unter KI Kamera.", "No camera access. Allow it in iPhone Settings under KI Kamera."))
                    .font(Theme.ui(15))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)
                    .padding(30)
            } else {
                CameraPreview(cam: cam, version: cam.configVersion)
            }
            if cam.preset.grid { GridOverlay(opacity: gridOpacity) }
            FrameMask(aspect: cam.preset.aspectValue, landscape: cam.isLandscape, color: frameTint, opacity: frameOpacity)
            if cam.isRecording && dimWhileRecording && !revealed {
                Color.black.opacity(0.72)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let pt = cam.focusPoint {
                FocusBox(point: pt).id("\(pt.x)-\(pt.y)")
            }
            ScanSweep(trigger: scanTrigger)
            if cam.photoFlash {
                Color.white.opacity(0.85).allowsHitTesting(false)
            }
            if cam.isRecording {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.rec.opacity(0.7), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Oben

    private var timecode: String {
        String(format: "%02d:%02d:%02d:00", cam.seconds / 3600, (cam.seconds / 60) % 60, cam.seconds % 60)
    }

    private func timeOfDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d:00", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private var frameTint: Color {
        switch frameColor {
        case "white": return .white
        case "red": return Theme.rec
        case "cyan": return Theme.cyan
        default: return Theme.gold
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(cam.preset.isPhoto ? L("FOTO", "PHOTO") : cam.preset.resolutionText)
                    .font(Theme.mono(12, .heavy))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                Text(cam.preset.aspectLabel)
                    .font(Theme.mono(8, .bold))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(Theme.goldGradient)
                    .contentTransition(.numericText())
            }
            .fixedSize()
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.gold, lineWidth: 1))
            .rotationEffect(iconAngle)

            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(timecodeMode == "tod" ? timeOfDay(ctx.date) : timecode)
                        .font(Theme.mono(22, .bold))
                        .foregroundStyle(cam.isRecording ? Theme.rec : Theme.text)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: cam.seconds)
                }
                Text("\(cam.preset.codecText) · \(cam.preset.colorText) · \(cam.preset.stabilization == "cinematic" ? "STAB+" : "STAB")")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.text.opacity(0.7))
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                if showBattery {
                    HStack(spacing: 4) {
                        Image(systemName: batteryIcon).font(.system(size: 11))
                        Text("\(Int(cam.battery * 100))%").font(Theme.mono(10, .bold))
                    }
                    .foregroundStyle(cam.battery < 0.2 ? Theme.rec : Theme.text)
                }
                if showStorage {
                    Text(String(format: "%.0f GB", cam.freeGB)).font(Theme.mono(10, .bold)).foregroundStyle(Theme.text.opacity(0.7))
                }
            }

            Button { sheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .rotationEffect(iconAngle)
            }
            .accessibilityLabel(L("Einstellungen", "Settings"))
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
                            Text(param.label).font(Theme.mono(9, .bold)).foregroundStyle(Theme.text.opacity(0.7))
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
                                .fill(Theme.gold.opacity(0.16))
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

    private var chipsRow: some View {
        HStack(alignment: .top) {
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
            Spacer()
            Text(String(format: "%.1f×", cam.liveZoom))
                .font(Theme.mono(12, .bold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glass(12)
                .contentTransition(.numericText())
                .rotationEffect(iconAngle)
        }
        .padding(.horizontal, 12)
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let msg = cam.message, !uiHidden {
                Text(msg)
                    .font(Theme.ui(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glass(12, glow: Theme.cyan)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: cam.message)
    }

    // MARK: Unten

    private var aspectPicker: some View {
        HStack(spacing: 2) {
            ForEach(Preset.aspects, id: \.self) { a in
                let on = cam.preset.aspect == a
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { cam.update { $0.aspect = a } }
                } label: {
                    Text(a == "2.39" ? "2,39" : a)
                        .font(Theme.mono(11, .heavy))
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .frame(minWidth: 50, minHeight: 34)
                        .background {
                            if on {
                                Capsule().fill(Theme.goldGradient)
                                    .matchedGeometryEffect(id: "aspect", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(cam.isRecording)
                .accessibilityLabel(L("Bildformat ", "Aspect ratio ") + a)
            }
        }
        .padding(3)
        .glass(19)
    }

    private var lensRow: some View {
        HStack(spacing: 4) {
            ForEach(Lens.allCases) { lens in
                let on = cam.preset.lens == lens
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { cam.setLens(lens) }
                } label: {
                    Text(lens.label)
                        .font(Theme.mono(12, .bold))
                        .foregroundStyle(on ? Color.black : Theme.text.opacity(0.9))
                        .rotationEffect(iconAngle)
                        .frame(width: 56, height: 40)
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
                .accessibilityLabel(L("Objektiv ", "Lens ") + lens.focal)
            }
        }
        .padding(4)
        .glass(24)
    }

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 14) {
                sideButton(icon: "square.stack.3d.up", label: "Looks") { sheet = .looks }
                Button { sheet = .ai } label: {
                    VStack(spacing: 3) {
                        AIOrb(size: 50)
                        Text("KI").font(Theme.mono(10, .heavy)).foregroundStyle(Theme.cyan)
                    }
                    .rotationEffect(iconAngle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("KI fragen", "Ask AI"))
            }
            .recFade(uiHidden, mode: recFade, dy: 12)

            Spacer()
            recordButton
            Spacer()

            HStack(spacing: 14) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        cam.update { $0.mode = $0.isPhoto ? "video" : "photo" }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(cam.preset.isPhoto ? L("FOTO", "PHOTO") : "VIDEO")
                            .font(Theme.mono(10, .heavy))
                            .foregroundStyle(Theme.goldGradient)
                            .rotationEffect(iconAngle)
                            .frame(width: 48, height: 48)
                            .glass(16)
                        Text(L("Modus", "Mode")).font(Theme.mono(9, .bold)).foregroundStyle(Theme.text.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Video oder Foto", "Video or photo"))
                sideButton(icon: "wand.and.stars", label: "Studio") { showEditor = true }
            }
            .recFade(uiHidden, mode: recFade, dy: 12)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func sideButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .rotationEffect(iconAngle)
                    .frame(width: 48, height: 48)
                    .glass(16)
                Text(label).font(Theme.mono(9, .bold)).foregroundStyle(Theme.text.opacity(0.7))
            }
            .foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain)
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
        .accessibilityLabel(cam.preset.isPhoto ? L("Foto aufnehmen", "Take photo") : (cam.isRecording ? L("Aufnahme stoppen", "Stop recording") : L("Aufnahme starten", "Start recording")))
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
