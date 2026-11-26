import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Welche Stücke des Originalclips im fertigen Video landen, und wie Originalzeit → Videozeit umgerechnet wird.
struct Timeline {
    let segments: [(Double, Double)]
    let speed: Double

    var duration: Double { segments.reduce(0) { $0 + ($1.1 - $1.0) } / speed }

    /// Originalzeit → Zeit im fertigen Video (nil, wenn die Stelle rausgeschnitten ist).
    func outTime(_ src: Double) -> Double? {
        var acc = 0.0
        for (a, b) in segments {
            if src < a - 0.001 { return nil }
            if src <= b + 0.001 { return (acc + min(max(src - a, 0), b - a)) / speed }
            acc += b - a
        }
        return nil
    }

    /// Wie outTime, aber eine rausgeschnittene Stelle springt zum nächsten behaltenen Moment.
    func outTimeSnapping(_ src: Double) -> Double {
        var acc = 0.0
        for (a, b) in segments {
            if src <= b { return (acc + max(src - a, 0)) / speed }
            acc += b - a
        }
        return acc / speed
    }

    /// Zeiten, an denen zwei Stücke aneinanderstoßen (im fertigen Video).
    var joins: [Double] {
        var out: [Double] = []
        var acc = 0.0
        for (i, (a, b)) in segments.enumerated() {
            if i > 0 { out.append(acc / speed) }
            acc += b - a
        }
        return out
    }

    static func make(for p: EditProject, duration: Double) -> Timeline {
        let r = p.recipe
        let t0 = min(max(r.trimStart, 0), max(duration - 0.3, 0))
        let t1 = max(min(r.trimEnd ?? duration, duration), t0 + 0.3)
        var removes: [(Double, Double)] = []
        if p.cutSilences {
            let keep = p.pause / 2
            for s in p.silences where s.count == 2 {
                let a = s[0] + keep, b = s[1] - keep
                if b - a > 0.05 { removes.append((a, b)) }
            }
        }
        if p.cutMistakes {
            for c in p.cuts where c.enabled && c.end > c.start { removes.append((c.start, c.end)) }
        }
        removes.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for r in removes {
            if let last = merged.last, r.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, r.1) } else { merged.append(r) }
        }
        var kept: [(Double, Double)] = []
        var cursor = t0
        for (a, b) in merged where b > t0 && a < t1 {
            if a > cursor { kept.append((cursor, min(a, t1))) }
            cursor = max(cursor, b)
        }
        if cursor < t1 { kept.append((cursor, t1)) }
        kept = kept.filter { $0.1 - $0.0 > 0.08 }
        if kept.isEmpty { kept = [(t0, t1)] }
        return Timeline(segments: kept, speed: min(max(r.speed, 0.25), 2))
    }
}

struct CaptionChunk {
    let start: Double
    let end: Double
    let words: [(text: String, start: Double, end: Double)]
}

struct PlacedBeat {
    let beat: Beat
    let start: Double
    let end: Double
}

/// Zeichnet Untertitel und Motion Graphics auf jedes Bild. Thread-sicher, mit Zwischenspeicher.
final class OverlayRenderer {
    let size: CGSize
    let style: GraphicStyle?
    let captions: [CaptionChunk]
    let beats: [PlacedBeat]
    let captionScale: Double
    let showCaptions: Bool

    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]
    private var unit: CGFloat { min(size.width, size.height) / 1080 }
    private var portrait: Bool { size.height >= size.width }

    init(size: CGSize, style: GraphicStyle?, captions: [CaptionChunk], beats: [PlacedBeat], captionScale: Double, showCaptions: Bool) {
        self.size = size
        self.style = style
        self.captions = captions
        self.beats = beats
        self.captionScale = captionScale
        self.showCaptions = showCaptions
    }

    private func cached(_ key: String, _ make: () -> UIImage?) -> CIImage? {
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        guard let ui = make(), let cg = ui.cgImage else { return nil }
        let img = CIImage(cgImage: cg)
        lock.lock()
        if cache.count > 400 { cache.removeAll() }
        cache[key] = img
        lock.unlock()
        return img
    }

    func render(on base: CIImage, at t: Double) -> CIImage {
        var img = base
        if let style {
            for (i, pb) in beats.enumerated() where t >= pb.start && t <= pb.end {
                if let card = beatImage(pb, index: i, t: t, style: style) { img = card.composited(over: img) }
            }
        }
        if showCaptions, let cap = captionImage(at: t) { img = cap.composited(over: img) }
        return img.cropped(to: base.extent)
    }

    // MARK: Animation

    private func ease(_ x: Double) -> CGFloat {
        let c = min(max(x, 0), 1)
        return CGFloat(1 - pow(1 - c, 3))
    }

    private func place(_ image: CIImage, x: CGFloat, y: CGFloat, alpha: CGFloat, scale: CGFloat, rise: CGFloat) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        var t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(translationX: x + w / 2, y: y + h / 2 - rise))
        let moved = image.transformed(by: t)
        let fade = CIFilter.colorMatrix()
        fade.inputImage = moved
        fade.aVector = CIVector(x: 0, y: 0, z: 0, w: alpha)
        return fade.outputImage ?? moved
    }

    private func beatImage(_ pb: PlacedBeat, index: Int, t: Double, style: GraphicStyle) -> CIImage? {
        let b = pb.beat
        let tin = ease((t - pb.start) / 0.35)
        let tout = ease((pb.end - t) / 0.3)
        let alpha = min(tin, tout)
        var key = "b\(index)"
        var shownItems = b.items?.count ?? 0
        var value: Double?
        if b.kind == "list", let items = b.items, !items.isEmpty {
            shownItems = min(items.count, Int((t - pb.start - 0.25) / 0.5) + 1)
            key += "-l\(shownItems)"
        }
        if b.kind == "number", let n = b.number {
            let p = Double(ease((t - pb.start) / 1.2))
            let v = n * p
            value = abs(n) >= 100 ? v.rounded() : (v * 10).rounded() / 10
            key += "-n\(value ?? 0)"
        }
        guard let card = cached(key, { drawCard(b, style: style, shownItems: shownItems, value: value) }) else { return nil }
        let w = card.extent.width, h = card.extent.height
        let x: CGFloat, y: CGFloat
        if style.centered {
            x = (size.width - w) / 2
            y = size.height * (portrait ? 0.30 : 0.36)
        } else {
            x = size.width * 0.06
            y = size.height * (portrait ? 0.24 : 0.22)
        }
        _ = h
        let punch: CGFloat = style.centered ? 1 + 0.12 * (1 - tin) : 1
        return place(card, x: x, y: y, alpha: alpha, scale: punch, rise: (1 - tin) * 40 * unit)
    }

    private func captionImage(at t: Double) -> CIImage? {
        guard let i = captions.firstIndex(where: { t >= $0.start && t < $0.end }) else { return nil }
        let chunk = captions[i]
        let current = chunk.words.firstIndex { t >= $0.start && t < $0.end } ?? -1
        guard let img = cached("c\(i)-\(current)", { drawCaption(chunk, highlight: current) }) else { return nil }
        let x = (size.width - img.extent.width) / 2
        let y = size.height * (portrait ? 0.11 : 0.07)
        return img.transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    // MARK: Zeichnen

    private func font(_ name: String, _ size: CGFloat, fallback: UIFont.Weight) -> UIFont {
        UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: fallback)
    }

    private func text(_ s: String, _ style: GraphicStyle) -> String { style.uppercase ? s.uppercased() : s }

    private func drawCaption(_ chunk: CaptionChunk, highlight: Int) -> UIImage? {
        let st = style ?? GraphicStyle.all[0]
        let fs = 54 * unit * CGFloat(captionScale)
        let base = font(style == nil ? "AvenirNext-Bold" : st.titleFont, fs, fallback: .bold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let s = NSMutableAttributedString()
        for (i, w) in chunk.words.enumerated() {
            let color = i == highlight ? st.captionHighlight : st.captionInk
            s.append(NSAttributedString(string: (i > 0 ? " " : "") + text(w.text, st),
                                        attributes: [.font: base, .foregroundColor: color, .paragraphStyle: para]))
        }
        let maxW = size.width * 0.86
        let bounds = s.boundingRect(with: CGSize(width: maxW - 40 * unit, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let pad = 22 * unit
        let w = ceil(bounds.width) + pad * 2, h = ceil(bounds.height) + pad * 1.4
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
            UIColor.black.withAlphaComponent(0.42).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 18 * unit).fill()
            s.draw(with: CGRect(x: pad, y: pad * 0.7, width: w - pad * 2, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    private func drawCard(_ b: Beat, style st: GraphicStyle, shownItems: Int, value: Double?) -> UIImage? {
        let u = unit
        let width: CGFloat
        switch b.kind {
        case "keyword": width = min(size.width * 0.8, 720 * u)
        case "lowerThird": width = size.width * (portrait ? 0.78 : 0.42)
        default: width = st.centered ? size.width * (portrait ? 0.86 : 0.58) : size.width * (portrait ? 0.80 : 0.44)
        }
        let pad = 34 * u
        let inner = width - pad * 2
        let left = NSMutableParagraphStyle()
        left.alignment = st.centered ? .center : .left
        left.lineBreakMode = .byWordWrapping

        func attr(_ s: String, _ f: UIFont, _ c: UIColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .paragraphStyle: left])
        }
        func height(_ a: NSAttributedString) -> CGFloat {
            ceil(a.boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        }

        var blocks: [(NSAttributedString, CGFloat)] = []   // Text, Abstand danach
        let titleSize: CGFloat
        switch b.kind {
        case "keyword": titleSize = 64 * u
        case "number": titleSize = 40 * u
        case "lowerThird": titleSize = 46 * u
        default: titleSize = 58 * u
        }
        let titleFont = font(st.titleFont, titleSize, fallback: .heavy)
        let bodyFont = font(st.bodyFont, 34 * u, fallback: .medium)

        if b.kind == "number", let v = value {
            let isInt = abs(v - v.rounded()) < 0.001
            let num = (isInt ? String(Int(v.rounded())) : String(format: "%.1f", v)) + (b.unit.map { " " + $0 } ?? "")
            blocks.append((attr(num, font(st.titleFont, 120 * u, fallback: .heavy), st.accent), 6 * u))
            if !b.title.isEmpty { blocks.append((attr(text(b.title, st), titleFont, st.ink), 0)) }
        } else if b.kind == "quote" {
            blocks.append((attr("“" + b.title + "”", font(st.titleFont, 50 * u, fallback: .bold), st.ink), 10 * u))
            if let s = b.subtitle { blocks.append((attr("— " + s, bodyFont, st.accent), 0)) }
        } else {
            let titleColor = b.kind == "keyword" ? st.ink : st.ink
            blocks.append((attr(text(b.title, st), titleFont, titleColor), 12 * u))
            if let s = b.subtitle, !s.isEmpty { blocks.append((attr(s, bodyFont, st.accent), 12 * u)) }
            if b.kind == "list", let items = b.items {
                for (i, item) in items.prefix(shownItems).enumerated() {
                    blocks.append((attr("\(i + 1)  " + item, bodyFont, st.ink), 10 * u))
                }
            }
        }

        let chrome: CGFloat = st.id == "software-walkthrough" ? 34 * u : 0
        let accentBar: CGFloat = b.kind == "lowerThird" ? 10 * u : 0
        var contentH: CGFloat = 0
        for (a, gap) in blocks { contentH += height(a) + gap }
        let h = contentH + pad * 2 + chrome
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: h), format: format).image { ctx in
            let rect = CGRect(x: 0, y: 0, width: width, height: h)
            let bg = b.kind == "keyword" ? st.accent : st.card
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 10 * u), blur: 30 * u, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            bg.setFill()
            UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: st.radius * u).fill()
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            if chrome > 0 {
                for (i, c) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    c.setFill()
                    UIBezierPath(ovalIn: CGRect(x: pad + CGFloat(i) * 22 * u, y: 16 * u, width: 12 * u, height: 12 * u)).fill()
                }
            }
            if accentBar > 0 {
                st.accent.setFill()
                UIBezierPath(rect: CGRect(x: 0, y: 0, width: accentBar, height: h)).fill()
            }
            var y = pad + chrome
            for (a, gap) in blocks {
                let hh = height(a)
                if b.kind == "keyword" {
                    let m = NSMutableAttributedString(attributedString: a)
                    m.addAttribute(.foregroundColor, value: st.id == "creator-motion-graphics" || st.id == "pop-info" ? UIColor.black : UIColor.white,
                                   range: NSRange(location: 0, length: m.length))
                    m.draw(with: CGRect(x: pad + accentBar, y: y, width: inner, height: hh), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                } else {
                    a.draw(with: CGRect(x: pad + accentBar, y: y, width: inner - accentBar, height: hh), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                }
                y += hh + gap
            }
        }
    }
}

struct StudioBuild {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let timeline: Timeline
}

enum StudioEngine {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func captions(for p: EditProject, timeline: Timeline) -> [CaptionChunk] {
        var chunks: [CaptionChunk] = []
        var cur: [(text: String, start: Double, end: Double)] = []
        func flush() {
            if let f = cur.first, let l = cur.last { chunks.append(CaptionChunk(start: f.start, end: l.end + 0.25, words: cur)) }
            cur = []
        }
        for w in p.words {
            guard let s = timeline.outTime(w.start) else { continue }
            let e = timeline.outTime(w.end) ?? (s + (w.end - w.start) / timeline.speed)
            if let last = cur.last, s - last.end > 0.6 { flush() }
            cur.append((w.w, s, max(e, s + 0.08)))
            let endsSentence = w.w.hasSuffix(".") || w.w.hasSuffix("?") || w.w.hasSuffix("!")
            if cur.count >= 4 || endsSentence { flush() }
        }
        flush()
        for i in 0..<chunks.count where i + 1 < chunks.count {
            let c = chunks[i]
            chunks[i] = CaptionChunk(start: c.start, end: min(c.end, chunks[i + 1].start), words: c.words)
        }
        return chunks
    }

    static func placedBeats(for p: EditProject, timeline: Timeline) -> [PlacedBeat] {
        guard p.style != "none" else { return [] }
        return p.beats.filter(\.enabled).map { b in
            let s = timeline.outTimeSnapping(b.start)
            var e = timeline.outTimeSnapping(b.end)
            if e - s < 1.8 { e = s + 1.8 }
            return PlacedBeat(beat: b, start: s, end: min(e, timeline.duration))
        }
    }

    static func build(url: URL, project p: EditProject, preview: Bool) async throws -> StudioBuild {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw EditorError.noVideo }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, transform, fps) = try await vTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let timeline = Timeline.make(for: p, duration: duration)

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditorError.noVideo
        }
        cv.preferredTransform = transform
        let ca = aTrack == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for (a, b) in timeline.segments {
            let range = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
            try cv.insertTimeRange(range, of: vTrack, at: cursor)
            if let aTrack, let ca { try? ca.insertTimeRange(range, of: aTrack, at: cursor) }
            cursor = cursor + range.duration
        }
        if abs(timeline.speed - 1) > 0.01 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor),
                                toDuration: CMTimeMultiplyByFloat64(cursor, multiplier: 1 / timeline.speed))
        }

        // Weiche Übergänge an jedem Schnitt (kein Knacksen), wie im Editor-Skill.
        let mix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []
        if let ca {
            let voice = AVMutableAudioMixInputParameters(track: ca)
            let fade = 0.012
            for j in timeline.joins where j > fade {
                voice.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: CMTime(seconds: j - fade, preferredTimescale: 6000),
                                                           duration: CMTime(seconds: fade, preferredTimescale: 6000)))
                voice.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                    timeRange: CMTimeRange(start: CMTime(seconds: j, preferredTimescale: 6000),
                                                           duration: CMTime(seconds: fade, preferredTimescale: 6000)))
            }
            params.append(voice)
        }

        let beats = placedBeats(for: p, timeline: timeline)
        if p.sfx, !beats.isEmpty, let whoosh = SoundFX.whooshURL(),
           let sfxSource = try? await AVURLAsset(url: whoosh).loadTracks(withMediaType: .audio).first,
           let sfxTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let len = CMTime(seconds: SoundFX.whooshLength, preferredTimescale: 600)
            var end = CMTime.zero
            for b in beats {
                let at = CMTime(seconds: max(b.start - 0.12, 0), preferredTimescale: 600)
                guard at >= end else { continue }
                if at > end { sfxTrack.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
                try? sfxTrack.insertTimeRange(CMTimeRange(start: .zero, duration: len), of: sfxSource, at: at)
                end = at + len
            }
            let sp = AVMutableAudioMixInputParameters(track: sfxTrack)
            sp.setVolume(0.5, at: .zero)
            params.append(sp)
        }
        mix.inputParameters = params

        let rotated = CGRect(origin: .zero, size: natural).applying(transform)
        let full = CGSize(width: abs(rotated.width).rounded(), height: abs(rotated.height).rounded())
        let scale: CGFloat = preview ? min(1, 1280 / max(full.width, full.height)) : 1
        let render = CGSize(width: (full.width * scale / 2).rounded() * 2, height: (full.height * scale / 2).rounded() * 2)
        let orientation = VideoEditor.orientation(for: transform)
        let recipe = p.recipe
        let overlay = OverlayRenderer(size: render, style: GraphicStyle.named(p.style),
                                      captions: p.captions ? captions(for: p, timeline: timeline) : [],
                                      beats: beats, captionScale: p.captionSize, showCaptions: p.captions)

        let vc = AVMutableVideoComposition(asset: comp) { request in
            var image = request.sourceImage
            let size = image.extent.size
            if abs(size.width - full.width) > 2 || abs(size.height - full.height) > 2 {
                image = image.oriented(orientation)
            }
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
            let sx = render.width / max(image.extent.width, 1), sy = render.height / max(image.extent.height, 1)
            if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
                image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
            var out = VideoEditor.apply(recipe, to: image, time: request.compositionTime.seconds)
            out = overlay.render(on: out, at: request.compositionTime.seconds)
            request.finish(with: out.cropped(to: CGRect(origin: .zero, size: render)), context: context)
        }
        vc.renderSize = render
        let rate = fps > 0 ? fps : 30
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(rate.rounded(), 24), 60)))
        return StudioBuild(composition: comp, videoComposition: vc, audioMix: mix, timeline: timeline)
    }

    static func export(url: URL, project: EditProject, progress: @escaping (Float) -> Void) async throws -> URL {
        let built = try await build(url: url, project: project, preview: false)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHEVCHighestQuality)
            ?? AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw EditorError.export
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("KIStudio-\(UUID().uuidString).mov")
        session.outputURL = out
        session.outputFileType = .mov
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
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
}

/// Erzeugt einen kurzen Whoosh-Sound für Grafik-Einblendungen (einmal, als Datei).
enum SoundFX {
    static let whooshLength = 0.45
    private static var cachedURL: URL?

    static func whooshURL() -> URL? {
        if let u = cachedURL, FileManager.default.fileExists(atPath: u.path) { return u }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whoosh.caf")
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return nil }
        let frames = AVAudioFrameCount(rate * whooshLength)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        var low: Float = 0
        var seed: UInt32 = 12345
        for i in 0..<Int(frames) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            let p = Float(i) / Float(frames)
            let cutoff: Float = 0.02 + 0.25 * sin(p * .pi)          // Filter öffnet und schließt sich: "wusch"
            low += cutoff * (noise - low)
            let env = sin(p * .pi) * sin(p * .pi)
            data[i] = low * env * 0.9
        }
        do {
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            return nil
        }
        cachedURL = url
        return url
    }
}
