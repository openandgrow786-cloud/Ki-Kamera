import AVFoundation
import CoreTransferable
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Video aus der Fotomediathek als Datei laden.
struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest)
        }
    }
}

/// Bricht Chips automatisch in mehrere Zeilen um.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Regler mit Beschriftung und Wert.
struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(format(value))
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: range, step: step)
                .tint(Theme.gold)
        }
    }
}

/// Eingabezeile für KI-Befehle.
struct PromptField: View {
    let placeholder: String
    @Binding var text: String
    var busy = false
    var send: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(Theme.ui(16))
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                ZStack {
                    Circle().fill(Theme.goldGradient)
                    if busy {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .disabled(busy)
            .accessibilityLabel("Senden")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glass(24, glow: Theme.cyan)
    }
}

enum PhotoSaver {
    static func saveVideo(_ url: URL, done: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { done(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                DispatchQueue.main.async { done(ok) }
            }
        }
    }
}

/// Befehle ohne API-Key verstehen: kleine Änderungen am aktuellen Look oder eingebaute Looks.
enum LocalAI {
    static func interpret(_ text: String, current: Preset) -> Preset {
        let t = text.lowercased()
        var p = current
        var changed = false

        if t.contains("wärmer") { p.whiteBalance = (p.whiteBalance ?? 5600) - 500; changed = true }
        if t.contains("kälter") || t.contains("kühler") { p.whiteBalance = (p.whiteBalance ?? 5600) + 500; changed = true }
        if t.contains("heller") { p.exposureBias = min(p.exposureBias + 0.5, 2); changed = true }
        if t.contains("dunkler") { p.exposureBias = max(p.exposureBias - 0.5, -2); changed = true }
        for f in [24, 25, 30, 48, 50, 60, 100, 120] where t.contains("\(f) fps") || t.contains("\(f)fps") {
            p.fps = Double(f)
            p.shutter = Double(f * 2)
            changed = true
        }
        if t.contains("countdown") { p.countdown = 3; changed = true }
        if t.contains("raster aus") { p.grid = false; changed = true }
        if t.contains("raster an") { p.grid = true; changed = true }

        if changed {
            p.note = "Ohne API-Key: Änderung am aktuellen Look."
            return p
        }
        var m = Preset.match(text: text)
        m.note = (m.note ?? "") + " (Eingebauter Look, ohne API-Key.)"
        return m
    }
}
