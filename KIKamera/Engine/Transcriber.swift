import AVFoundation
import Speech

enum TranscribeError: LocalizedError {
    case denied, unavailable, noAudio, failed(String)

    var errorDescription: String? {
        switch self {
        case .denied: return L("Spracherkennung nicht erlaubt. Erlaube sie in den iPhone-Einstellungen unter KI Kamera.",
                               "Speech recognition not allowed. Allow it in iPhone Settings under KI Kamera.")
        case .unavailable: return L("Spracherkennung für diese Sprache gerade nicht verfügbar.", "Speech recognition is not available for this language right now.")
        case .noAudio: return L("Der Clip hat keine Tonspur.", "The clip has no audio track.")
        case .failed(let m): return L("Transkription fehlgeschlagen: ", "Transcription failed: ") + m
        }
    }
}

/// Transkribiert auf dem iPhone (Apple Spracherkennung) und findet Pausen über die Lautstärke.
enum Transcriber {
    static func authorize() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
    }

    /// Tonspur als m4a herauslösen (die Spracherkennung mag reine Audiodateien am liebsten).
    static func extractAudio(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TranscribeError.noAudio }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscribeError.noAudio
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        session.outputURL = out
        session.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else { throw TranscribeError.failed(session.error?.localizedDescription ?? "audio") }
        return out
    }

    static func transcribe(url: URL, language: String) async throws -> [Word] {
        guard await authorize() else { throw TranscribeError.denied }
        let locale = Locale(identifier: language == "en" ? "en-US" : "de-DE")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { throw TranscribeError.unavailable }
        let audio = try await extractAudio(from: url)
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let words: [Word] = try await withCheckedThrowingContinuation { cont in
            var done = false
            let lock = NSLock()
            func finish(_ result: Result<[Word], Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                cont.resume(with: result)
            }
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let ws = result.bestTranscription.segments.map {
                        Word(w: $0.substring, start: $0.timestamp, end: $0.timestamp + max($0.duration, 0.05))
                    }
                    finish(.success(ws))
                } else if let error {
                    let ns = error as NSError
                    // "Keine Sprache erkannt" ist kein echter Fehler: dann eben ohne Wörter.
                    if ns.code == 1110 || ns.code == 203 { finish(.success([])) } else { finish(.failure(TranscribeError.failed(error.localizedDescription))) }
                }
            }
        }
        try? FileManager.default.removeItem(at: audio)
        return words
    }

    /// Pausen finden wie im Editor-Skill: Lautstärke in 10-ms-Schritten, Schwelle aus Grundrauschen und Sprache.
    static func silences(url: URL, minGap: Double = 0.6) async throws -> [[Double]] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        reader.startReading()

        let hop = Int(rate / 100)
        var db: [Float] = []
        var carry: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / 4)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            carry.append(contentsOf: samples)
            var i = 0
            while i + hop <= carry.count {
                var sum: Float = 0
                for k in i..<(i + hop) { sum += carry[k] * carry[k] }
                db.append(20 * log10(sqrt(sum / Float(hop)) + 1e-9))
                i += hop
            }
            carry.removeFirst(i)
        }
        guard db.count > 10 else { return [] }

        let sorted = db.sorted()
        let floor = sorted[Int(Double(sorted.count) * 0.10)]
        let loud = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
        let threshold = max(floor + 6, floor + 0.28 * (loud - floor))
        let speech = db.map { $0 > threshold }
        let k = 6
        var held = [Bool](repeating: false, count: speech.count)
        for (i, s) in speech.enumerated() where s {
            for j in max(0, i - k)...min(speech.count - 1, i + k) { held[j] = true }
        }
        var runs: [[Double]] = []
        var i = 0
        while i < held.count {
            if !held[i] {
                var j = i
                while j < held.count && !held[j] { j += 1 }
                if Double(j - i) / 100 >= minGap { runs.append([Double(i) / 100, Double(j) / 100]) }
                i = j
            } else {
                i += 1
            }
        }
        return runs
    }
}
