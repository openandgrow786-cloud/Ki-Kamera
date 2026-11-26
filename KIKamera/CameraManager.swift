import AVFoundation
import Photos
import UIKit

/// Steuert die iPhone-Kamera komplett: Objektiv, Format, FPS, Verschluss, ISO, Weißabgleich, HDR, Aufnahme.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "kikamera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var isoTimer: DispatchSourceTimer?
    private var autoISO = true
    private var shutterDuration = CMTime(value: 1, timescale: 60)
    private var configured = false
    private var uiTimer: Timer?

    @Published private(set) var preset: Preset = .standard
    @Published private(set) var isRecording = false
    @Published private(set) var seconds = 0
    @Published private(set) var liveISO = 0
    @Published private(set) var aperture: Float = 1.78
    @Published private(set) var configVersion = 0
    @Published private(set) var cameraDenied = false
    @Published var message: String? {
        didSet {
            guard let m = message else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.message == m { self?.message = nil }
            }
        }
    }

    // MARK: - Start

    func start() {
        let first = preset
        Task {
            let video = await AVCaptureDevice.requestAccess(for: .video)
            let audio = await AVCaptureDevice.requestAccess(for: .audio)
            guard video else {
                await MainActor.run { self.cameraDenied = true }
                return
            }
            self.queue.async {
                self.configureSession(withAudio: audio)
                self.applyOnQueue(first)
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func apply(_ p: Preset) {
        preset = p
        queue.async { self.applyOnQueue(p) }
    }

    func setLens(_ lens: Lens) {
        var p = preset
        p.lens = lens
        apply(p)
    }

    private func configureSession(withAudio: Bool) {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if withAudio,
           let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()
    }

    // MARK: - Einstellungen anwenden

    static func captureDevice(for lens: Lens) -> AVCaptureDevice? {
        let found: AVCaptureDevice?
        switch lens {
        case .front:
            found = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .ultra:
            found = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .wide, .wide2x:
            found = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .tele:
            found = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        }
        return found ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func applyOnQueue(_ p: Preset) {
        guard !movieOutput.isRecording, let wanted = Self.captureDevice(for: p.lens) else { return }

        session.beginConfiguration()
        if device?.uniqueID != wanted.uniqueID {
            if let old = videoInput { session.removeInput(old) }
            if let input = try? AVCaptureDeviceInput(device: wanted), session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                device = wanted
            } else if let old = videoInput, session.canAddInput(old) {
                session.addInput(old)
            }
        }
        guard let cam = device else {
            session.commitConfiguration()
            return
        }

        var usedFPS = p.fps
        var ap: Float = cam.lensAperture
        var problem: String?

        do {
            try cam.lockForConfiguration()

            if let format = Self.bestFormat(for: cam, preset: p) { cam.activeFormat = format }
            let f = cam.activeFormat

            // HDR (HLG, 10 Bit) oder normales SDR
            if p.hdr, f.supportedColorSpaces.contains(.HLG_BT2020) {
                cam.activeColorSpace = .HLG_BT2020
            } else if f.supportedColorSpaces.contains(.sRGB) {
                cam.activeColorSpace = .sRGB
            }

            // Bildrate
            let ranges = f.videoSupportedFrameRateRanges
            let range = ranges.first { $0.minFrameRate - 0.01 <= p.fps && p.fps <= $0.maxFrameRate + 0.01 }
                ?? ranges.max { $0.maxFrameRate < $1.maxFrameRate }
            var frame = CMTime(value: 1, timescale: 30)
            if let range {
                usedFPS = min(max(p.fps, range.minFrameRate), range.maxFrameRate)
                frame = Self.frameDuration(for: usedFPS, in: range)
                cam.activeVideoMinFrameDuration = frame
                cam.activeVideoMaxFrameDuration = frame
            }

            // Zoom (48 mm = 2x auf der Hauptkamera)
            let zoom: CGFloat = p.lens == .wide2x ? 2.0 : 1.0
            cam.videoZoomFactor = min(max(zoom, cam.minAvailableVideoZoomFactor), f.videoMaxZoomFactor)

            if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }

            // Weißabgleich
            if let kelvin = p.whiteBalance, cam.isWhiteBalanceModeSupported(.locked) {
                let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(kelvin), tint: Float(p.tint))
                var g = cam.deviceWhiteBalanceGains(for: tt)
                let maxG = cam.maxWhiteBalanceGain
                g.redGain = min(max(g.redGain, 1), maxG)
                g.greenGain = min(max(g.greenGain, 1), maxG)
                g.blueGain = min(max(g.blueGain, 1), maxG)
                cam.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
            } else if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                cam.whiteBalanceMode = .continuousAutoWhiteBalance
            }

            // Verschluss fest, ISO fest oder automatisch nachgeregelt
            var dur = CMTime(seconds: 1.0 / max(p.shutter, 1), preferredTimescale: 1_000_000)
            if dur > frame { dur = frame }
            if dur < f.minExposureDuration { dur = f.minExposureDuration }
            if dur > f.maxExposureDuration { dur = f.maxExposureDuration }
            shutterDuration = dur
            if cam.isExposureModeSupported(.custom) {
                autoISO = (p.iso == nil)
                let startISO = p.iso.map { Float($0) } ?? cam.iso
                let iso = min(max(startISO, f.minISO), f.maxISO)
                cam.setExposureModeCustom(duration: dur, iso: iso, completionHandler: nil)
            }

            ap = cam.lensAperture
            cam.unlockForConfiguration()
        } catch {
            problem = "Kamera-Fehler: \(error.localizedDescription)"
        }

        if let c = movieOutput.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }   // Hochformat
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = (p.lens == .front)
            }
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .auto }
            let codec: AVVideoCodecType = p.codec.lowercased() == "h264" ? .h264 : .hevc
            if movieOutput.availableVideoCodecTypes.contains(codec) {
                movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: c)
            }
        }
        session.commitConfiguration()
        startISOLoop()

        if problem == nil, abs(usedFPS - p.fps) > 0.5 {
            problem = "Dieses Objektiv schafft hier max. \(Int(usedFPS.rounded())) fps, daher eingestellt."
        }
        let finalFPS = usedFPS
        DispatchQueue.main.async {
            self.aperture = ap
            if abs(self.preset.fps - finalFPS) > 0.5 { self.preset.fps = finalFPS }
            self.configVersion += 1
            if let problem { self.message = problem }
        }
    }

    static func frameDuration(for fps: Double, in range: AVFrameRateRange) -> CMTime {
        if abs(fps - range.maxFrameRate) < 0.01 { return range.minFrameDuration }
        if abs(fps - range.minFrameRate) < 0.01 { return range.maxFrameDuration }
        if abs(fps - fps.rounded()) < 0.001 { return CMTime(value: 1, timescale: CMTimeScale(fps.rounded())) }
        return CMTime(value: 1001, timescale: CMTimeScale((fps * 1001).rounded()))
    }

    /// Sucht das Kameraformat, das am besten zu Auflösung, FPS und HDR passt.
    static func bestFormat(for cam: AVCaptureDevice, preset p: Preset) -> AVCaptureDevice.Format? {
        let wantW: Int32 = p.resolutionText == "1080p" ? 1920 : 3840
        let wantH: Int32 = p.resolutionText == "1080p" ? 1080 : 2160
        let tenBit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        func supports(_ f: AVCaptureDevice.Format) -> Bool {
            f.videoSupportedFrameRateRanges.contains { $0.minFrameRate - 0.01 <= p.fps && p.fps <= $0.maxFrameRate + 0.01 }
        }
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            var s = 0
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            if d.width == wantW && d.height == wantH { s += 100 }
            if supports(f) { s += 50 }
            let hlg = f.supportedColorSpaces.contains(.HLG_BT2020)
            let isTen = CMFormatDescriptionGetMediaSubType(f.formatDescription) == tenBit
            if p.hdr {
                if hlg { s += 20 }
                if isTen { s += 10 }
            } else {
                if !hlg { s += 10 }
                if !isTen { s += 5 }
            }
            if f.isVideoBinned { s -= 3 }
            return s
        }

        return cam.formats.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            return supports(a) ? maxFPS(a) < maxFPS(b) : maxFPS(a) > maxFPS(b)
        }.first
    }

    // MARK: - Auto-ISO bei festem Verschluss

    private func startISOLoop() {
        isoTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 0.15)
        t.setEventHandler { [weak self] in self?.isoStep() }
        t.resume()
        isoTimer = t
    }

    private func isoStep() {
        guard let cam = device else { return }
        if autoISO, cam.exposureMode == .custom {
            let offset = Double(cam.exposureTargetOffset)   // EV: + zu hell, - zu dunkel
            if abs(offset) > 0.08 {
                let f = cam.activeFormat
                var next = Float(Double(cam.iso) * pow(2.0, -offset * 0.5))
                next = min(max(next, f.minISO), f.maxISO)
                if abs(next - cam.iso) > 0.5, (try? cam.lockForConfiguration()) != nil {
                    cam.setExposureModeCustom(duration: shutterDuration, iso: next, completionHandler: nil)
                    cam.unlockForConfiguration()
                }
            }
        }
        let current = Int(cam.iso)
        DispatchQueue.main.async {
            if self.liveISO != current { self.liveISO = current }
        }
    }

    // MARK: - Aufnahme

    func toggleRecording() {
        queue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            guard self.movieOutput.connection(with: .video) != nil else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("KIKamera-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.seconds = 0
                self.uiTimer?.invalidate()
                self.uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.seconds += 1
                }
            }
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.uiTimer?.invalidate()
            self.uiTimer = nil
        }
        var ok = true
        if let error = error as NSError? {
            ok = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        }
        guard ok else {
            DispatchQueue.main.async { self.message = "Aufnahme fehlgeschlagen." }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.message = "Kein Zugriff auf Fotos, Video nicht gespeichert." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }) { saved, _ in
                try? FileManager.default.removeItem(at: outputFileURL)
                DispatchQueue.main.async {
                    self.message = saved ? "In Fotos gespeichert" : "Speichern fehlgeschlagen."
                }
            }
        }
    }
}
