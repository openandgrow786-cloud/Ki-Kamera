import AVFoundation
import Photos
import UIKit

/// Steuert die iPhone-Kamera komplett: Objektiv, Format, FPS, Verschluss, ISO, Weißabgleich, HDR, Zoom, Fokus,
/// Video- und Fotoaufnahme, Tonpegel.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "kikamera.session")
    private let meterQueue = DispatchQueue(label: "kikamera.meter")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var applied: Preset?
    private var isoTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?
    private var autoISO = true
    private var shutterDuration = CMTime(value: 1, timescale: 60)
    private var configured = false
    private var uiTimer: Timer?
    private var pinchStartZoom: CGFloat = 1

    @Published private(set) var preset: Preset = .standard
    @Published private(set) var isRecording = false
    @Published private(set) var seconds = 0
    @Published private(set) var liveISO = 0
    @Published private(set) var liveZoom: Double = 1
    @Published private(set) var aperture: Float = 1.78
    @Published private(set) var isoRange: ClosedRange<Double> = 50...3200
    @Published private(set) var configVersion = 0
    @Published private(set) var cameraDenied = false
    @Published private(set) var audioLevels: [Float] = [0, 0]
    @Published private(set) var audioPeaks: [Float] = [0, 0]
    @Published private(set) var freeGB: Double = 0
    @Published private(set) var battery: Float = 1
    @Published private(set) var focusPoint: CGPoint?
    @Published private(set) var photoFlash = false
    @Published var message: String? {
        didSet {
            guard let m = message else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                if self?.message == m { self?.message = nil }
            }
        }
    }

    // MARK: - Start

    func start() {
        let first = preset
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshDeviceInfo()
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
                self.startMeters()
            }
        }
    }

    func refreshDeviceInfo() {
        let level = UIDevice.current.batteryLevel
        battery = level < 0 ? 1 : level
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            freeGB = Double(bytes) / 1_000_000_000
        }
    }

    /// Ganzen Look anwenden (KI, Bibliothek, Code).
    func apply(_ p: Preset) {
        preset = p
        queue.async { self.applyOnQueue(p) }
    }

    /// Einzelnen Wert ändern (manuelle Regler).
    func update(_ change: (inout Preset) -> Void) {
        var p = preset
        change(&p)
        apply(p)
    }

    func setLens(_ lens: Lens) {
        update {
            $0.lens = lens
            $0.zoom = nil
        }
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
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
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
        var p = p
        if p.needsReconfigure(from: applied) {
            if movieOutput.isRecording { return }
            guard reconfigure(&p) else { return }
        }
        tune(p)
        applied = p
        let final = p
        DispatchQueue.main.async {
            if abs(self.preset.fps - final.fps) > 0.01 { self.preset.fps = final.fps }
            if abs(self.preset.shutter - final.shutter) > 0.5 { self.preset.shutter = final.shutter }
            self.configVersion += 1
        }
    }

    /// Objektiv, Format, HDR, Bildrate, Codec, Stabilisierung.
    private func reconfigure(_ p: inout Preset) -> Bool {
        guard let wanted = Self.captureDevice(for: p.lens) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

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
        guard let cam = device else { return false }

        let requestedFPS = p.fps
        do {
            try cam.lockForConfiguration()
            if let format = Self.bestFormat(for: cam, preset: p) { cam.activeFormat = format }
            let f = cam.activeFormat

            if p.hdr, f.supportedColorSpaces.contains(.HLG_BT2020) {
                cam.activeColorSpace = .HLG_BT2020
            } else if f.supportedColorSpaces.contains(.sRGB) {
                cam.activeColorSpace = .sRGB
            }

            let ranges = f.videoSupportedFrameRateRanges
            if let range = ranges.first(where: { $0.minFrameRate - 0.01 <= p.fps && p.fps <= $0.maxFrameRate + 0.01 })
                ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                p.fps = min(max(p.fps, range.minFrameRate), range.maxFrameRate)
                let frame = Self.frameDuration(for: p.fps, in: range)
                cam.activeVideoMinFrameDuration = frame
                cam.activeVideoMaxFrameDuration = frame
            }
            cam.unlockForConfiguration()

            let dims = f.supportedMaxPhotoDimensions.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
            if let dims { photoOutput.maxPhotoDimensions = dims }
            photoOutput.maxPhotoQualityPrioritization = .quality

            let isoMin = Double(f.minISO), isoMax = Double(f.maxISO)
            let ap = cam.lensAperture
            DispatchQueue.main.async {
                self.isoRange = isoMin...max(isoMax, isoMin + 1)
                self.aperture = ap
            }
        } catch {
            DispatchQueue.main.async { self.message = "Kamera-Fehler: \(error.localizedDescription)" }
        }

        for c in [movieOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = (p.lens == .front)
            }
        }
        if let c = movieOutput.connection(with: .video) {
            if c.isVideoStabilizationSupported {
                switch p.stabilization {
                case "off": c.preferredVideoStabilizationMode = .off
                case "cinematic": c.preferredVideoStabilizationMode = .cinematicExtended
                default: c.preferredVideoStabilizationMode = .auto
                }
            }
            let codec: AVVideoCodecType = p.codec.lowercased() == "h264" ? .h264 : .hevc
            if movieOutput.availableVideoCodecTypes.contains(codec) {
                movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: c)
            }
        }

        if abs(requestedFPS - p.fps) > 0.5 {
            let got = Int(p.fps.rounded())
            DispatchQueue.main.async {
                self.message = "Dieses Objektiv schafft hier max. \(got) fps, daher eingestellt."
            }
        }
        return true
    }

    /// Zoom, Fokus, Weißabgleich, Verschluss, ISO, Belichtungskorrektur. Geht auch während der Aufnahme.
    private func tune(_ p: Preset) {
        guard let cam = device, (try? cam.lockForConfiguration()) != nil else { return }
        defer { cam.unlockForConfiguration() }
        let f = cam.activeFormat

        let zoom = CGFloat(p.effectiveZoom)
        cam.videoZoomFactor = min(max(zoom, cam.minAvailableVideoZoomFactor), min(f.videoMaxZoomFactor, 15))
        let z = Double(cam.videoZoomFactor)
        DispatchQueue.main.async { self.liveZoom = z }

        if cam.focusMode != .locked, cam.isFocusModeSupported(.continuousAutoFocus) {
            cam.focusMode = .continuousAutoFocus
        }

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

        let frame = cam.activeVideoMinFrameDuration
        var dur = CMTime(seconds: 1.0 / max(p.shutter, 1), preferredTimescale: 1_000_000)
        if !p.isPhoto, frame.isValid, frame.seconds > 0, dur > frame { dur = frame }
        if dur < f.minExposureDuration { dur = f.minExposureDuration }
        if dur > f.maxExposureDuration { dur = f.maxExposureDuration }
        shutterDuration = dur

        let bias = Float(min(max(p.exposureBias, Double(cam.minExposureTargetBias)), Double(cam.maxExposureTargetBias)))
        cam.setExposureTargetBias(bias, completionHandler: nil)

        if cam.isExposureModeSupported(.custom) {
            autoISO = (p.iso == nil)
            let startISO = p.iso.map { Float($0) } ?? cam.iso
            cam.setExposureModeCustom(duration: dur, iso: min(max(startISO, f.minISO), f.maxISO), completionHandler: nil)
        }
        startISOLoop()
    }

    static func frameDuration(for fps: Double, in range: AVFrameRateRange) -> CMTime {
        if abs(fps - range.maxFrameRate) < 0.01 { return range.minFrameDuration }
        if abs(fps - range.minFrameRate) < 0.01 { return range.maxFrameDuration }
        if abs(fps - fps.rounded()) < 0.001 { return CMTime(value: 1, timescale: CMTimeScale(fps.rounded())) }
        return CMTime(value: 1001, timescale: CMTimeScale((fps * 1001).rounded()))
    }

    /// Sucht das Kameraformat, das am besten zu Modus, Auflösung, FPS und HDR passt.
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
        func photoPixels(_ f: AVCaptureDevice.Format) -> Int {
            f.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            var s = 0
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            if p.isPhoto {
                s += photoPixels(f) / 1_000_000
                if d.width == wantW && d.height == wantH { s += 5 }
                if f.isVideoBinned { s -= 3 }
                return s
            }
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

    // MARK: - Fokus und Zoom per Geste

    func focus(at devicePoint: CGPoint, viewPoint: CGPoint) {
        focusPoint = viewPoint
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.focusPoint == viewPoint { self?.focusPoint = nil }
        }
        queue.async {
            guard let cam = self.device, (try? cam.lockForConfiguration()) != nil else { return }
            if cam.isFocusPointOfInterestSupported, cam.isFocusModeSupported(.autoFocus) {
                cam.focusPointOfInterest = devicePoint
                cam.focusMode = .autoFocus
            }
            if cam.isExposurePointOfInterestSupported {
                cam.exposurePointOfInterest = devicePoint
            }
            cam.unlockForConfiguration()
        }
    }

    func pinchBegan() {
        pinchStartZoom = CGFloat(liveZoom)
    }

    func pinchChanged(scale: CGFloat) {
        let target = pinchStartZoom * scale
        queue.async {
            guard let cam = self.device, (try? cam.lockForConfiguration()) != nil else { return }
            let z = min(max(target, cam.minAvailableVideoZoomFactor), min(cam.activeFormat.videoMaxZoomFactor, 15))
            cam.videoZoomFactor = z
            cam.unlockForConfiguration()
            DispatchQueue.main.async { self.liveZoom = Double(z) }
        }
    }

    func pinchEnded() {
        let z = liveZoom
        preset.zoom = z
        queue.async { self.applied?.zoom = z }
    }

    // MARK: - Auto-ISO bei festem Verschluss

    private func startISOLoop() {
        guard isoTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 0.12)
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

    // MARK: - Tonpegel

    private func startMeters() {
        let t = DispatchSource.makeTimerSource(queue: meterQueue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.meterStep() }
        t.resume()
        meterTimer = t
    }

    private func meterStep() {
        guard let channels = movieOutput.connection(with: .audio)?.audioChannels, !channels.isEmpty else { return }
        func norm(_ db: Float) -> Float { db.isFinite ? min(max((db + 60) / 60, 0), 1) : 0 }
        var levels = channels.prefix(2).map { norm($0.averagePowerLevel) }
        var peaks = channels.prefix(2).map { norm($0.peakHoldLevel) }
        if levels.count == 1 {
            levels.append(levels[0])
            peaks.append(peaks[0])
        }
        DispatchQueue.main.async {
            self.audioLevels = levels
            self.audioPeaks = peaks
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
            let limit = self.applied?.maxDuration ?? 0
            DispatchQueue.main.async {
                self.isRecording = true
                self.seconds = 0
                self.uiTimer?.invalidate()
                self.uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.seconds += 1
                    if limit > 0, self.seconds >= limit, self.isRecording { self.toggleRecording() }
                    if self.seconds % 10 == 0 { self.refreshDeviceInfo() }
                }
            }
        }
    }

    func takePhoto() {
        queue.async {
            guard self.photoOutput.connection(with: .video) != nil else { return }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
        photoFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.photoFlash = false }
    }

    fileprivate func saveToPhotos(_ change: @escaping () -> Void, success: String) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.message = "Kein Zugriff auf Fotos, nicht gespeichert." }
                return
            }
            PHPhotoLibrary.shared().performChanges(change) { saved, _ in
                DispatchQueue.main.async {
                    self.message = saved ? success : "Speichern fehlgeschlagen."
                    self.refreshDeviceInfo()
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
        saveToPhotos({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
        }, success: "Video in Fotos gespeichert")
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.message = "Foto fehlgeschlagen." }
            return
        }
        saveToPhotos({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }, success: "Foto in Fotos gespeichert")
    }
}
