import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum EditorError: LocalizedError {
    case noVideo, export

    var errorDescription: String? {
        switch self {
        case .noVideo: return "Im Clip wurde keine Videospur gefunden."
        case .export: return "Export fehlgeschlagen."
        }
    }
}

/// Wendet ein Bearbeitungs-Rezept auf einen Clip an: Farblook per Core Image, Schnitt und Tempo per Komposition.
enum VideoEditor {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func duration(of url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    static func makeComposition(url: URL, recipe r: EditRecipe) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw EditorError.noVideo }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, transform, fps) = try await vTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)

        let total = duration.seconds
        let startSec = min(max(r.trimStart, 0), max(total - 0.3, 0))
        let endSec = max(min(r.trimEnd ?? total, total), startSec + 0.3)
        let range = CMTimeRange(start: CMTime(seconds: startSec, preferredTimescale: 600),
                                end: CMTime(seconds: min(endSec, total), preferredTimescale: 600))

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditorError.noVideo
        }
        try cv.insertTimeRange(range, of: vTrack, at: .zero)
        cv.preferredTransform = transform
        if let aTrack, let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? ca.insertTimeRange(range, of: aTrack, at: .zero)
        }
        if abs(r.speed - 1) > 0.01 {
            let newDuration = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / r.speed)
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: newDuration)
        }

        let rotated = CGRect(origin: .zero, size: natural).applying(transform)
        let renderSize = CGSize(width: abs(rotated.width).rounded(), height: abs(rotated.height).rounded())
        let orientation = orientation(for: transform)
        let recipe = r

        let vc = AVMutableVideoComposition(asset: comp) { request in
            var image = request.sourceImage
            let size = image.extent.size
            if abs(size.width - renderSize.width) > 2 || abs(size.height - renderSize.height) > 2 {
                image = image.oriented(orientation)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x,
                                                                y: -image.extent.origin.y))
            }
            let output = apply(recipe, to: image, time: request.compositionTime.seconds)
            request.finish(with: output, context: context)
        }
        vc.renderSize = renderSize
        let rate = fps > 0 ? fps : 30
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(rate.rounded(), 24), 120)))
        return (comp, vc)
    }

    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        default: return .up
        }
    }

    /// Der eigentliche Farblook.
    static func apply(_ r: EditRecipe, to input: CIImage, time: Double) -> CIImage {
        let extent = input.extent
        var img = input

        if abs(r.exposure) > 0.001 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(r.exposure)
            img = f.outputImage ?? img
        }
        if abs(r.warmth) > 0.5 || abs(r.tint) > 0.5 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500 + CGFloat(r.warmth) * 30, y: CGFloat(-r.tint) * 0.8)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            img = f.outputImage ?? img
        }
        do {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.contrast = Float(r.contrast)
            f.saturation = r.blackWhite ? 0 : Float(r.saturation)
            f.brightness = 0
            img = f.outputImage ?? img
        }
        if r.fade > 0.01 {
            let k = CGFloat(r.fade)
            let f = CIFilter.colorMatrix()
            f.inputImage = img
            f.rVector = CIVector(x: 1 - 0.18 * k, y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: 1 - 0.18 * k, z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: 1 - 0.18 * k, w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            f.biasVector = CIVector(x: 0.09 * k, y: 0.08 * k, z: 0.08 * k, w: 0)
            img = f.outputImage ?? img
        }
        if r.sharpen > 0.01 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(r.sharpen * 0.8)
            img = f.outputImage ?? img
        }
        if r.vignette > 0.01 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = img
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(min(extent.width, extent.height) * 0.55)
            f.intensity = Float(r.vignette)
            f.falloff = 0.6
            img = f.outputImage ?? img
        }
        if r.grain > 0.01, let noise = CIFilter.randomGenerator().outputImage {
            let shift = CGFloat(Int(time * 997) % 600)
            let mono = CIFilter.colorControls()
            mono.inputImage = noise.transformed(by: CGAffineTransform(translationX: -shift, y: -shift * 0.7))
            mono.saturation = 0
            mono.contrast = 1
            let alpha = CIFilter.colorMatrix()
            alpha.inputImage = mono.outputImage
            alpha.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
            alpha.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
            alpha.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
            alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            alpha.biasVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(r.grain) * 0.14)
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = alpha.outputImage
            over.backgroundImage = img
            img = over.outputImage ?? img
        }
        return img.cropped(to: extent)
    }

    /// Vorschaubild eines Rezepts (für die Stil-Kacheln).
    static func thumbnail(url: URL, recipe: EditRecipe, at seconds: Double = 0.5) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        guard let cg = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        let out = apply(recipe, to: CIImage(cgImage: cg), time: 0)
        guard let rendered = context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    /// Exportiert den bearbeiteten Clip als neue Datei.
    static func export(url: URL, recipe: EditRecipe, progress: @escaping (Float) -> Void) async throws -> URL {
        let (comp, vc) = try await makeComposition(url: url, recipe: recipe)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHEVCHighestQuality)
            ?? AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw EditorError.export
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("KIStudio-\(UUID().uuidString).mov")
        session.outputURL = out
        session.outputFileType = .mov
        session.videoComposition = vc

        let ticker = Task {
            while !Task.isCancelled {
                progress(session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        ticker.cancel()
        progress(1)
        guard session.status == .completed else { throw session.error ?? EditorError.export }
        return out
    }

    /// Schneidet ein frisch aufgenommenes Video auf ein Bildformat zu (z. B. 1:1, 4:5, 2,39:1).
    /// Gibt nil zurück, wenn das Video schon das richtige Format hat.
    static func crop(url: URL, aspect: Double) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let w = abs(shown.width), h = abs(shown.height)
        guard w > 0, h > 0 else { return nil }
        let current = Double(w / h)
        if abs(current - aspect) / aspect < 0.02 { return nil }

        var cw = w, ch = h
        if current > aspect { cw = h * CGFloat(aspect) } else { ch = w / CGFloat(aspect) }
        cw = (cw / 2).rounded(.down) * 2
        ch = (ch / 2).rounded(.down) * 2
        let ox = (w - cw) / 2, oy = (h - ch) / 2

        let duration = try await asset.load(.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let t = transform
            .concatenating(CGAffineTransform(translationX: -shown.origin.x, y: -shown.origin.y))
            .concatenating(CGAffineTransform(translationX: -ox, y: -oy))
        layer.setTransform(t, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: cw, height: ch)
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(fps.rounded(), 24), 120)))
        comp.instructions = [instruction]
        if let fd = try await track.load(.formatDescriptions).first,
           let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] {
            comp.colorPrimaries = ext[kCVImageBufferColorPrimariesKey as String] as? String
            comp.colorTransferFunction = ext[kCVImageBufferTransferFunctionKey as String] as? String
            comp.colorYCbCrMatrix = ext[kCVImageBufferYCbCrMatrixKey as String] as? String
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("KIKamera-crop-\(UUID().uuidString).mov")
        session.outputURL = out
        session.outputFileType = .mov
        session.videoComposition = comp
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else { throw session.error ?? EditorError.export }
        return out
    }
}
