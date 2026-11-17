import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

struct VideoPickerView: UIViewControllerRepresentable {
    @Binding var selectedVideoURL: URL?
    @Environment(\.presentationMode) private var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.mediaTypes = ["public.movie"]
        picker.videoQuality = .typeHigh
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: VideoPickerView
        init(_ parent: VideoPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let mediaURL = info[.mediaURL] as? URL {
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("input_\(Int(Date().timeIntervalSince1970)).mp4")
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: mediaURL, to: dst)
                parent.selectedVideoURL = dst
            }
            parent.presentationMode.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
    @State private var videoURL: URL? = nil
    @State private var player: AVPlayer? = nil
    @State private var videoDuration: Double = 0
    @State private var playheadTime: Double = 0

    // Timeline segments for Split & Delete
    @State private var segments: [VideoSegment] = []
    @State private var selectedSegmentID: UUID? = nil

    // Edit Settings (Default 1 & Default 2 + Fade-In + Voice Overlay)
    @State private var settings: EditSettings = .default1
    @State private var activePresetIndex: Int = 1

    // Voice Overlay
    @StateObject private var voiceRecorder = VoiceRecorderManager()
    @State private var importedAudioURL: URL? = nil
    @State private var showAudioImporter: Bool = false

    // UI Sheets & Export State
    @State private var showVideoPicker: Bool = false
    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0
    @State private var statusMessage: String = ""
    @State private var exportedVideoURL: URL? = nil
    @State private var showShareSheet: Bool = false

    var activeVoiceURL: URL? {
        importedAudioURL ?? voiceRecorder.recordedURL
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.07)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        headerBar
                        videoPreviewCard
                        if videoURL != nil {
                            timelineSplitDeleteCard
                        }
                        fadeInAnimationCard
                        voiceOverlayCard
                        capCutPresetsCard
                        colorAdjustmentsCard
                        hslAdjustmentsCard
                        exportButtonSection
                    }
                    .padding(14)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showVideoPicker) {
                VideoPickerView(selectedVideoURL: $videoURL)
            }
            .sheet(isPresented: $showShareSheet) {
                if let expURL = exportedVideoURL {
                    ShareSheetView(activityItems: [expURL])
                }
            }
            .fileImporter(
                isPresented: $showAudioImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let first = urls.first {
                    let _ = first.startAccessingSecurityScopedResource()
                    let dst = FileManager.default.temporaryDirectory
                        .appendingPathComponent("voice_import_\(Int(Date().timeIntervalSince1970)).m4a")
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.copyItem(at: first, to: dst)
                    importedAudioURL = dst
                    first.stopAccessingSecurityScopedResource()
                }
            }
            .onChange(of: videoURL) { newURL in
                guard let url = newURL else { return }
                setupVideo(url: url)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Header
    private var headerBar: some View {
        HStack {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [Color.cyan, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 38, height: 38)
                    Text("TE")
                        .font(.system(size: 16, weight: .black))
                        .foregroundColor(.black)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("TABI EDIT")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(.white)
                    Text("1080p 60FPS • Split • Fade • Voice")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.cyan)
                }
            }
            Spacer()
            Button(action: { showVideoPicker = true }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                    Text(videoURL == nil ? "Import Video" : "Change")
                        .font(.system(size: 13, weight: .bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.cyan.opacity(0.18))
                .foregroundColor(.cyan)
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - Video Preview Card
    private var videoPreviewCard: some View {
        VStack(spacing: 10) {
            if let player = player {
                VideoPlayer(player: player)
                    .frame(height: 230)
                    .cornerRadius(12)

                VStack(spacing: 6) {
                    HStack {
                        Text(String(format: "Playhead: %.1fs", playheadTime))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                        Spacer()
                        Text(String(format: "Total: %.1fs", videoDuration))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    Slider(
                        value: Binding(
                            get: { playheadTime },
                            set: { newVal in
                                playheadTime = newVal
                                player.seek(to: CMTime(seconds: newVal, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            }
                        ),
                        in: 0...max(0.1, videoDuration)
                    )
                    .accentColor(.cyan)
                }
                .padding(.horizontal, 6)
            } else {
                Button(action: { showVideoPicker = true }) {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.cyan)
                        Text("Tap to Select Video from Photos")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Text("Supports Split, Delete, Fade-In, Voice Overlay & CapCut 1080p 60FPS")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .background(Color(red: 0.08, green: 0.10, blue: 0.14))
                    .cornerRadius(14)
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - Timeline Split & Delete Card
    private var timelineSplitDeleteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("TIMELINE — SPLIT & DELETE", systemImage: "scissors")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.cyan)
                Spacer()
                Text("\(segments.count) Clip(s)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.gray)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                        let isSelected = (seg.id == selectedSegmentID)
                        Button(action: {
                            selectedSegmentID = seg.id
                            playheadTime = seg.startTime
                            player?.seek(to: CMTime(seconds: seg.startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                        }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Clip \(idx + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(isSelected ? .black : .white)
                                Text(String(format: "%.1fs - %.1fs", seg.startTime, seg.endTime))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(isSelected ? .black.opacity(0.8) : .gray)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.cyan : Color(red: 0.13, green: 0.16, blue: 0.22))
                            .cornerRadius(8)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button(action: splitAtPlayhead) {
                    HStack(spacing: 5) {
                        Image(systemName: "scissors")
                        Text("Split at Playhead")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.cyan.opacity(0.2))
                    .foregroundColor(.cyan)
                    .cornerRadius(8)
                }

                Button(action: deleteSelectedSegment) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash.fill")
                        Text("Delete Clip")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.red.opacity(0.22))
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }
                .disabled(segments.count <= 1)

                Button(action: resetTimeline) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .bold))
                        .padding(9)
                        .background(Color.white.opacity(0.1))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - Fade-In Animation Card
    private var fadeInAnimationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("ANIMATION — FADE IN", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.purple)
                Spacer()
                Toggle("", isOn: $settings.fadeInEnabled)
                    .labelsHidden()
                    .tint(.purple)
            }

            if settings.fadeInEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fade-In Duration")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text(String(format: "%.1f sec", settings.fadeInDuration))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.purple)
                    }
                    Slider(value: $settings.fadeInDuration, in: 0.3...3.5, step: 0.1)
                        .accentColor(.purple)
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - Voice Overlay Card
    private var voiceOverlayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("VOICE OVERLAY & AUDIO MIXER", systemImage: "mic.fill")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.green)
                Spacer()
                if activeVoiceURL != nil {
                    Button("Clear Voice") {
                        voiceRecorder.clearRecording()
                        importedAudioURL = nil
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.red)
                }
            }

            HStack(spacing: 10) {
                Button(action: {
                    importedAudioURL = nil
                    voiceRecorder.toggleRecording()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: voiceRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        Text(voiceRecorder.isRecording
                             ? String(format: "Stop (%.1fs)", voiceRecorder.recordingSeconds)
                             : "Record Voiceover")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(voiceRecorder.isRecording ? Color.red.opacity(0.3) : Color.green.opacity(0.2))
                    .foregroundColor(voiceRecorder.isRecording ? .red : .green)
                    .cornerRadius(8)
                }

                Button(action: { showAudioImporter = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.plus")
                        Text("Import Audio")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.cyan.opacity(0.18))
                    .foregroundColor(.cyan)
                    .cornerRadius(8)
                }
            }

            if let vURL = activeVoiceURL {
                Text("Active Voice Overlay: \(vURL.lastPathComponent)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
            }

            sliderRow(title: "Original Video Volume", value: $settings.originalVolume, range: 0...1.5, format: "%.0f%%", multiplier: 100)
            sliderRow(title: "Voice Overlay Volume", value: $settings.voiceVolume, range: 0...2.0, format: "%.0f%%", multiplier: 100)
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - CapCut Default 1 & Default 2 Presets
    private var capCutPresetsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CAPCUT QUALITY PRESETS (1-CLICK)")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(.cyan)

            HStack(spacing: 10) {
                Button(action: {
                    let fadeEn = settings.fadeInEnabled
                    let fadeDur = settings.fadeInDuration
                    let origVol = settings.originalVolume
                    let voiceVol = settings.voiceVolume
                    settings = .default1
                    settings.fadeInEnabled = fadeEn
                    settings.fadeInDuration = fadeDur
                    settings.originalVolume = origVol
                    settings.voiceVolume = voiceVol
                    activePresetIndex = 1
                }) {
                    VStack(spacing: 3) {
                        Text("🔥 CapCut Default 1")
                            .font(.system(size: 13, weight: .bold))
                        Text("B:-23 C:-31 S:+39 Sh:98")
                            .font(.system(size: 10))
                            .opacity(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(activePresetIndex == 1 ? Color.cyan : Color(red: 0.13, green: 0.16, blue: 0.22))
                    .foregroundColor(activePresetIndex == 1 ? .black : .white)
                    .cornerRadius(10)
                }

                Button(action: {
                    let fadeEn = settings.fadeInEnabled
                    let fadeDur = settings.fadeInDuration
                    let origVol = settings.originalVolume
                    let voiceVol = settings.voiceVolume
                    settings = .default2
                    settings.fadeInEnabled = fadeEn
                    settings.fadeInDuration = fadeDur
                    settings.originalVolume = origVol
                    settings.voiceVolume = voiceVol
                    activePresetIndex = 2
                }) {
                    VStack(spacing: 3) {
                        Text("✨ CapCut Default 2")
                            .font(.system(size: 13, weight: .bold))
                        Text("B:-5 C:-20 S:+20 Sh:59")
                            .font(.system(size: 10))
                            .opacity(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(activePresetIndex == 2 ? Color.cyan : Color(red: 0.13, green: 0.16, blue: 0.22))
                    .foregroundColor(activePresetIndex == 2 ? .black : .white)
                    .cornerRadius(10)
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - Color Adjustments Card
    private var colorAdjustmentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LIGHT & COLOR ADJUSTMENTS")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(.cyan)

            sliderRow(title: "Brightness", value: $settings.brightness, range: -50...50)
            sliderRow(title: "Contrast", value: $settings.contrast, range: -50...50)
            sliderRow(title: "Saturation", value: $settings.saturation, range: -50...50)
            sliderRow(title: "Brilliance", value: $settings.brilliance, range: -50...50)
            sliderRow(title: "Sharpness (Crisp HD)", value: $settings.sharpness, range: 0...100)
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - HSL Adjustments Card
    private var hslAdjustmentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HSL — SATURATION BOOST ONLY")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(.purple)

            sliderRow(title: "🔴 Red Saturation", value: $settings.hslRed, range: 0...100)
            sliderRow(title: "🔵 Blue Saturation", value: $settings.hslBlue, range: 0...100)
            sliderRow(title: "🫐 Dark Blue Saturation", value: $settings.hslDarkBlue, range: 0...100)
            sliderRow(title: "🟣 Purple Saturation", value: $settings.hslPurple, range: 0...100)
            sliderRow(title: "🩷 Pink Saturation", value: $settings.hslPink, range: 0...100)
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - Export Section
    private var exportButtonSection: some View {
        VStack(spacing: 10) {
            Button(action: startExport) {
                HStack {
                    Image(systemName: isExporting ? "hourglass" : "sparkles.tv.fill")
                    Text(isExporting
                         ? String(format: "Rendering 1080p 60FPS... %.0f%%", exportProgress * 100)
                         : "🚀 Enhance & Export (1080p 60FPS)")
                        .font(.system(size: 15, weight: .heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [Color.cyan, Color.purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(videoURL == nil || isExporting)
            .opacity((videoURL == nil || isExporting) ? 0.5 : 1.0)

            if isExporting {
                ProgressView(value: exportProgress)
                    .accentColor(.cyan)
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
            }

            if exportedVideoURL != nil {
                Button(action: { showShareSheet = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share / Save Enhanced Video File")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.22))
                    .foregroundColor(.green)
                    .cornerRadius(10)
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.10, blue: 0.14))
        .cornerRadius(14)
    }

    // MARK: - Slider Helper
    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String = "%.0f",
        multiplier: Double = 1.0
    ) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(String(format: format, value.wrappedValue * multiplier))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            Slider(value: value, in: range)
                .accentColor(.cyan)
        }
    }

    // MARK: - Actions
    private func setupVideo(url: URL) {
        let asset = AVURLAsset(url: url)
        let dur = max(0.1, CMTimeGetSeconds(asset.duration))
        videoDuration = dur
        playheadTime = 0
        let firstSeg = VideoSegment(startTime: 0, endTime: dur)
        segments = [firstSeg]
        selectedSegmentID = firstSeg.id
        player = AVPlayer(url: url)
        statusMessage = ""
        exportedVideoURL = nil
    }

    private func splitAtPlayhead() {
        guard let idx = segments.firstIndex(where: { playheadTime > $0.startTime + 0.15 && playheadTime < $0.endTime - 0.15 }) else {
            statusMessage = "Move playhead inside a clip to split!"
            return
        }
        let target = segments[idx]
        let leftSeg = VideoSegment(startTime: target.startTime, endTime: playheadTime)
        let rightSeg = VideoSegment(startTime: playheadTime, endTime: target.endTime)
        segments.remove(at: idx)
        segments.insert(contentsOf: [leftSeg, rightSeg], at: idx)
        selectedSegmentID = rightSeg.id
        statusMessage = "✂️ Split clip into two parts at \(String(format: "%.1fs", playheadTime))!"
    }

    private func deleteSelectedSegment() {
        guard segments.count > 1,
              let selID = selectedSegmentID,
              let idx = segments.firstIndex(where: { $0.id == selID }) else {
            return
        }
        segments.remove(at: idx)
        selectedSegmentID = segments.first?.id
        statusMessage = "🗑️ Deleted selected clip from timeline!"
    }

    private func resetTimeline() {
        guard videoDuration > 0 else { return }
        let full = VideoSegment(startTime: 0, endTime: videoDuration)
        segments = [full]
        selectedSegmentID = full.id
        statusMessage = "↺ Timeline reset to full video."
    }

    private func startExport() {
        guard let srcURL = videoURL else { return }
        isExporting = true
        exportProgress = 0.02
        statusMessage = "Applying TABI EDIT 1080p 60FPS + Fade-In + Voice Overlay..."

        VideoEngine.shared.exportEnhancedVideo(
            sourceURL: srcURL,
            segments: segments,
            settings: settings,
            voiceURL: activeVoiceURL,
            progressHandler: { prog in
                exportProgress = prog
            },
            completion: { result in
                isExporting = false
                switch result {
                case .success(let outURL):
                    exportedVideoURL = outURL
                    VideoEngine.shared.saveToPhotoLibrary(videoURL: outURL) { _, msg in
                        statusMessage = "✅ \(msg)"
                    }
                case .failure(let err):
                    statusMessage = "❌ Error: \(err.localizedDescription)"
                }
            }
        )
    }
}
