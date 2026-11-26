import AVFoundation
import SwiftUI

// MARK: - Live-Bild mit Tippen (Fokus) und Pinch (Zoom)

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onPinch: ((UIGestureRecognizer.State, CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: p), p)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        onPinch?(g.state, g.scale)
    }
}

struct CameraPreview: UIViewRepresentable {
    let cam: CameraManager
    let version: Int

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = cam.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        let cam = self.cam
        view.onTap = { device, point in cam.focus(at: device, viewPoint: point) }
        view.onPinch = { state, scale in
            switch state {
            case .began: cam.pinchBegan()
            case .changed: cam.pinchChanged(scale: scale)
            case .ended, .cancelled, .failed: cam.pinchEnded()
            default: break
            }
        }
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        if let c = view.previewLayer.connection, c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
    }
}

// MARK: - Overlays

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3, y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }
}

/// Fokus-Rahmen, der beim Tippen einrastet.
struct FocusBox: View {
    let point: CGPoint
    @State private var settle = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.gold, lineWidth: 1.5)
            Circle().fill(Theme.gold).frame(width: 4, height: 4)
        }
        .frame(width: 74, height: 74)
        .scaleEffect(settle ? 1 : 1.5)
        .opacity(settle ? 1 : 0)
        .shadow(color: Theme.gold.opacity(0.6), radius: 8)
        .position(point)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { settle = true } }
        .allowsHitTesting(false)
    }
}

/// Tonpegel links/rechts, wie bei Profi-Kameras.
struct AudioMeter: View {
    let levels: [Float]
    let peaks: [Float]
    private let segments = 18

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<2, id: \.self) { ch in
                VStack(spacing: 2) {
                    ForEach((0..<segments).reversed(), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color(for: i, channel: ch))
                            .frame(width: 6, height: 3)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("0").font(Theme.mono(7)).foregroundStyle(Theme.muted)
                Spacer()
                Text("-20").font(Theme.mono(7)).foregroundStyle(Theme.muted)
                Spacer()
                Text("-60").font(Theme.mono(7)).foregroundStyle(Theme.muted)
            }
            .frame(height: CGFloat(segments) * 5 - 2)
        }
        .padding(8)
        .glass(10)
        .animation(.linear(duration: 0.06), value: levels)
        .allowsHitTesting(false)
    }

    private func color(for i: Int, channel ch: Int) -> Color {
        let level = ch < levels.count ? levels[ch] : 0
        let peak = ch < peaks.count ? peaks[ch] : 0
        let frac = Float(i + 1) / Float(segments)
        let lit = frac <= level
        let isPeak = abs(frac - peak) < 1 / Float(segments) && peak > 0.05
        let base: Color = frac > 0.9 ? Theme.rec : (frac > 0.72 ? Theme.gold : Theme.cyan)
        if lit || isPeak { return base }
        return Color.white.opacity(0.08)
    }
}

/// Lichtstreifen, der beim Anwenden eines KI-Looks über das Bild fährt.
struct ScanSweep: View {
    let trigger: Int
    @State private var progress: CGFloat = -0.2
    @State private var visible = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Theme.cyan.opacity(0.55), Theme.gold.opacity(0.35), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .offset(y: progress * geo.size.height - 60)
                .opacity(visible ? 1 : 0)
                .blendMode(.screen)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            progress = -0.2
            visible = true
            withAnimation(.easeInOut(duration: 1.0)) { progress = 1.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { visible = false }
        }
    }
}
