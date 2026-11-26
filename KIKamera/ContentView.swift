import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var cam = CameraManager()
    @State private var showKI = false
    @State private var showSettings = false
    @State private var highlight = false

    private struct Stat: Identifiable {
        let id: String
        let value: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            stats
            viewfinder
            lensRow
            controls
        }
        .background(Color.kBG.ignoresSafeArea())
        .statusBarHidden(true)
        .onAppear { cam.start() }
        .sheet(isPresented: $showKI) {
            KISheet { preset in
                cam.apply(preset)
                showKI = false
                flash()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(current: cam.preset)
        }
    }

    private func flash() {
        withAnimation { highlight = true }
        cam.message = "Alles eingestellt. Drück jetzt nur noch Aufnahme."
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation { highlight = false }
        }
    }

    private var timecode: String {
        String(format: "00:%02d:%02d:00", cam.seconds / 60, cam.seconds % 60)
    }

    // MARK: Kopfzeile

    private var header: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(cam.preset.resolutionText)
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.top, 3)
                    .padding(.bottom, 2)
                Text("16:9")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.kBG)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(Color.white)
            }
            .fixedSize()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1.5))

            Text(timecode)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundStyle(cam.isRecording ? Color.kRec : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.kMuted)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Einstellungen")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var stats: some View {
        let p = cam.preset
        let items = [
            Stat(id: "FPS", value: p.fpsText),
            Stat(id: "VERSCHL.", value: p.shutterText),
            Stat(id: "BLENDE", value: String(format: "f/%.3g", cam.aperture)),
            Stat(id: p.iso == nil ? "ISO A" : "ISO", value: p.iso == nil ? "\(cam.liveISO)" : p.isoText),
            Stat(id: "WB", value: p.wbText),
            Stat(id: "TINT", value: p.tintText)
        ]
        return HStack(alignment: .top, spacing: 4) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.id)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.kMuted)
                    Text(item.value)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(highlight ? Color.kAccent : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Sucher

    private var viewfinder: some View {
        ZStack {
            if cam.cameraDenied {
                Text("Kein Kamerazugriff. Erlaube ihn in den iPhone-Einstellungen unter KI Kamera.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.kMuted)
                    .padding()
            } else {
                CameraPreview(session: cam.session, version: cam.configVersion)
            }

            VStack {
                HStack {
                    chip(icon: "sparkles", text: cam.preset.name, accent: true)
                    Spacer()
                    chip(icon: nil, text: cam.preset.lens.longLabel, accent: false)
                }
                Spacer()
                if cam.isRecording {
                    HStack {
                        HStack(spacing: 7) {
                            Circle().fill(Color.white).frame(width: 8, height: 8)
                            Text("REC").font(.system(size: 12, weight: .bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.kRec)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                } else if let msg = cam.message {
                    Text(msg)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.kBG)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .transition(.opacity)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kPanel)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.2), value: cam.message)
    }

    private func chip(icon: String?, text: String, accent: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).foregroundStyle(Color.kAccent)
            }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(accent ? Color.white : Color.white.opacity(0.8))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.kLine))
    }

    // MARK: Objektive und Knöpfe

    private var lensRow: some View {
        HStack(spacing: 8) {
            ForEach(Lens.allCases) { lens in
                let on = cam.preset.lens == lens
                Button { cam.setLens(lens) } label: {
                    Text(lens.label)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 56, minHeight: 44)
                        .padding(.horizontal, 4)
                        .foregroundStyle(on ? Color.kBG : Color.white.opacity(0.85))
                        .background(on ? Color.white : Color.kPanel)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.white : Color.kLine))
                }
                .disabled(cam.isRecording)
            }
        }
        .padding(.top, 12)
    }

    private var controls: some View {
        HStack {
            Button { showKI = true } label: {
                VStack(spacing: 3) {
                    Image(systemName: "sparkles").font(.system(size: 22))
                    Text("KI").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Color.kAccent)
                .frame(width: 64, height: 64)
                .background(Color.kAccent.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.kAccent))
            }
            .disabled(cam.isRecording)
            .accessibilityLabel("KI fragen")

            Spacer()

            Button { cam.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 84, height: 84)
                    if cam.isRecording {
                        RoundedRectangle(cornerRadius: 8).fill(Color.kRec).frame(width: 32, height: 32)
                    } else {
                        Circle().fill(Color.kRec).frame(width: 66, height: 66)
                    }
                }
            }
            .accessibilityLabel(cam.isRecording ? "Aufnahme stoppen" : "Aufnahme starten")

            Spacer()

            Button {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "play.rectangle").font(.system(size: 22))
                    Text("Clips").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 64, height: 64)
                .background(Color.kPanel)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.kLine))
            }
            .accessibilityLabel("Meine Clips")
        }
        .padding(.horizontal, 34)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }
}

// MARK: - Live-Bild

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let version: Int

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        if let c = view.previewLayer.connection, c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
    }
}
