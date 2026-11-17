import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import UIKit

struct VideoSegment: Identifiable, Equatable {
    let id: UUID
    var startTime: Double
    var endTime: Double

    var duration: Double {
        max(0, endTime - startTime)
    }

    init(id: UUID = UUID(), startTime: Double, endTime: Double) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct EditSettings {
    var presetName: String = "CapCut Default 1"
    var brightness: Double = -23
    var contrast: Double = -31
    var saturation: Double = 39
    var brilliance: Double = -9
    var sharpness: Double = 98

    var hslRed: Double = 63
    var hslBlue: Double = 15
    var hslDarkBlue: Double = 64
    var hslPurple: Double = 60
    var hslPink: Double = 60

    // Fade-In Animation
    var fadeInEnabled: Bool = true
    var fadeInDuration: Double = 1.2

    // Voice Overlay & Volume
    var originalVolume: Double = 1.0
    var voiceVolume: Double = 1.2

    static var default1: EditSettings {
        EditSettings(
            presetName: "CapCut Default 1",
            brightness: -23,
            contrast: -31,
            saturation: 39,
            brilliance: -9,
            sharpness: 98,
            hslRed: 63,
            hslBlue: 15,
            hslDarkBlue: 64,
            hslPurple: 60,
            hslPink: 60
        )
    }

    static var default2: EditSettings {
        EditSettings(
            presetName: "CapCut Default 2",
            brightness: -5,
            contrast: -20,
            saturation: 20,
            brilliance: -20,
            sharpness: 59,
            hslRed: 47,
            hslBlue: 5,
            hslDarkBlue: 43,
            hslPurple: 32,
            hslPink: 43
        )
    }
}

final class VoiceRecorderManager: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var recordedURL: URL? = nil
    @Published var recordingSeconds: Double = 0

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] allowed in
            guard let self = self, allowed else { return }
            DispatchQueue.main.async {
                do {
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    try session.setActive(true)

                    let outURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("tabi_voice_\(Int(Date().timeIntervalSince1970)).m4a")

                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44100.0,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]

                    let recorder = try AVAudioRecorder(url: outURL, settings: settings)
                    recorder.prepareToRecord()
                    recorder.record()

                    self.audioRecorder = recorder
                    self.recordedURL = outURL
                    self.recordingSeconds = 0
                    self.isRecording = true

                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                        self.recordingSeconds += 0.2
                    }
                } catch {
                    print("Voice recording error: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
    }

    func clearRecording() {
        stopRecording()
        recordedURL = nil
        recordingSeconds = 0
    }
}

final class VideoEngine {
    static let shared = VideoEngine()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func applyCapCutFilters(to inputImage: CIImage, settings: EditSettings, compositionTime: Double) -> CIImage {
        var img = inputImage
        let extent = inputImage.extent

        // 1. Exposure / Brilliance Gamma adjustment
        let brNorm = settings.brightness / 100.0
        let blNorm = settings.brilliance / 100.0
        let coNorm = settings.contrast / 100.0
        let satNorm = settings.saturation / 100.0
        let hslAvg = (settings.hslRed + settings.hslBlue + settings.hslDarkBlue + settings.hslPurple + settings.hslPink) / 500.0

        // Gamma curve for Brilliance & Brightness (keeps shadows deep like CapCut)
        let gammaPower = Float(pow(2.0, (-brNorm * 0.38) + (-blNorm * 0.45)))
        if let gammaFilter = CIFilter(name: "CIGammaAdjust") {
            gammaFilter.setValue(img, forKey: kCIInputImageKey)
            gammaFilter.setValue(gammaPower, forKey: "inputPower")
            if let out = gammaFilter.outputImage {
                img = out
            }
        }

        // 2. Color Controls (Brightness, Contrast, Global + HSL Saturation)
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(img, forKey: kCIInputImageKey)
            colorFilter.setValue(Float(brNorm * 0.08), forKey: kCIInputBrightnessKey)
            colorFilter.setValue(Float(1.0 + coNorm * 0.28), forKey: kCIInputContrastKey)
            colorFilter.setValue(Float(1.0 + satNorm * 0.85 + hslAvg * 0.55), forKey: kCIInputSaturationKey)
            if let out = colorFilter.outputImage {
                img = out
            }
        }

        // 3. Vibrance boost for HSL channels
        if let vibFilter = CIFilter(name: "CIVibrance") {
            vibFilter.setValue(img, forKey: kCIInputImageKey)
            vibFilter.setValue(Float(hslAvg * 0.9), forKey: "inputAmount")
            if let out = vibFilter.outputImage {
                img = out
            }
        }

        // 4. Crisp CapCut Sharpening (Luminance + Unsharp Mask)
        if settings.sharpness > 0 {
            let sharpFactor = Float(settings.sharpness / 100.0)
            if let sharpFilter = CIFilter(name: "CISharpenLuminance") {
                sharpFilter.setValue(img, forKey: kCIInputImageKey)
                sharpFilter.setValue(sharpFactor * 1.15, forKey: kCIInputSharpnessKey)
                if let out = sharpFilter.outputImage {
                    img = out
                }
            }
            if let unsharp = CIFilter(name: "CIUnsharpMask") {
                unsharp.setValue(img, forKey: kCIInputImageKey)
                unsharp.setValue(Float(2.2), forKey: kCIInputRadiusKey)
                unsharp.setValue(sharpFactor * 1.1, forKey: kCIInputIntensityKey)
                if let out = unsharp.outputImage {
                    img = out
                }
            }
        }

        // 5. Fade-In Animation (Smooth Black-to-Video Fade at start)
        if settings.fadeInEnabled && settings.fadeInDuration > 0.05 && compositionTime < settings.fadeInDuration {
            let progress = max(0.0, min(1.0, compositionTime / settings.fadeInDuration))
            // Smooth ease-in-out curve
            let alpha = progress * progress * (3.0 - 2.0 * progress)
            if let fadeFilter = CIFilter(name: "CIColorMatrix") {
                fadeFilter.setValue(img, forKey: kCIInputImageKey)
                let v = CGFloat(alpha)
                fadeFilter.setValue(CIVector(x: v, y: 0, z: 0, w: 0), forKey: "inputRVector")
                fadeFilter.setValue(CIVector(x: 0, y: v, z: 0, w: 0), forKey: "inputGVector")
                fadeFilter.setValue(CIVector(x: 0, y: 0, z: v, w: 0), forKey: "inputBVector")
                if let out = fadeFilter.outputImage {
                    img = out
                }
            }
        }

        return img.cropped(to: extent)
    }

    func exportEnhancedVideo(
        sourceURL: URL,
        segments: [VideoSegment],
        settings: EditSettings,
        voiceURL: URL?,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()

        guard let sourceVideoTrack = asset.tracks(withMediaType: .video).first,
              let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            completion(.failure(NSError(domain: "TabiEdit", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not read video track."])))
            return
        }

        let sourceAudioTrack = asset.tracks(withMediaType: .audio).first
        let compAudioTrack: AVMutableCompositionTrack? = sourceAudioTrack != nil
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        // Stitch active (non-deleted) segments in sequence
        var insertCursor = CMTime.zero
        let validSegments = segments.filter { $0.duration > 0.05 }

        do {
            for seg in validSegments {
                let startCM = CMTime(seconds: seg.startTime, preferredTimescale: 600)
                let durCM = CMTime(seconds: seg.duration, preferredTimescale: 600)
                let range = CMTimeRange(start: startCM, duration: durCM)

                try compVideoTrack.insertTimeRange(range, of: sourceVideoTrack, at: insertCursor)
                if let sAudio = sourceAudioTrack, let cAudio = compAudioTrack {
                    try? cAudio.insertTimeRange(range, of: sAudio, at: insertCursor)
                }
                insertCursor = CMTimeAdd(insertCursor, durCM)
            }
        } catch {
            completion(.failure(error))
            return
        }

        compVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform

        // Add Voice Overlay Track if provided
        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        if let cAudio = compAudioTrack {
            let origParam = AVMutableAudioMixInputParameters(track: cAudio)
            origParam.setVolume(Float(settings.originalVolume), at: .zero)
            audioMixParams.append(origParam)
        }

        if let vURL = voiceURL {
            let voiceAsset = AVURLAsset(url: vURL)
            if let vTrack = voiceAsset.tracks(withMediaType: .audio).first,
               let compVoiceTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let maxDur = CMTimeMinimum(voiceAsset.duration, insertCursor)
                let vRange = CMTimeRange(start: .zero, duration: maxDur)
                try? compVoiceTrack.insertTimeRange(vRange, of: vTrack, at: .zero)

                let voiceParam = AVMutableAudioMixInputParameters(track: compVoiceTrack)
                voiceParam.setVolume(Float(settings.voiceVolume), at: .zero)
                audioMixParams.append(voiceParam)
            }
        }

        // Build 60FPS CoreImage VideoComposition
        let videoComp = AVMutableVideoComposition(asset: composition) { [weak self] request in
            guard let self = self else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }
            let sec = CMTimeGetSeconds(request.compositionTime)
            let output = self.applyCapCutFilters(to: request.sourceImage, settings: settings, compositionTime: sec)
            request.finish(with: output, context: self.ciContext)
        }

        videoComp.frameDuration = CMTime(value: 1, timescale: 60) // 60 FPS Smooth

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TABI_EDIT_1080p60_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outURL)

        let preset = AVAssetExportSession.exportPresets(compatibleWith: composition)
            .contains(AVAssetExportPreset1920x1080)
            ? AVAssetExportPreset1920x1080
            : AVAssetExportPresetHighestQuality

        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            completion(.failure(NSError(domain: "TabiEdit", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize exporter."])))
            return
        }

        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComp
        exporter.shouldOptimizeForNetworkUse = true

        if !audioMixParams.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioMixParams
            exporter.audioMix = audioMix
        }

        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            DispatchQueue.main.async {
                progressHandler(Double(exporter.progress))
            }
        }

        exporter.exportAsynchronously {
            progressTimer.invalidate()
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    progressHandler(1.0)
                    completion(.success(outURL))
                case .failed, .cancelled:
                    let err = exporter.error ?? NSError(domain: "TabiEdit", code: -3, userInfo: [NSLocalizedDescriptionKey: "Export failed."])
                    completion(.failure(err))
                default:
                    break
                }
            }
        }
    }

    func saveToPhotoLibrary(videoURL: URL, completion: @escaping (Bool, String) -> Void) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion(false, "Photo Library permission denied.")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(true, "Saved 1080p 60FPS video to Photos!")
                    } else {
                        completion(false, error?.localizedDescription ?? "Failed to save video.")
                    }
                }
            }
        }
    }
}
