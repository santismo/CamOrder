import SwiftUI
import AVFoundation
import CamOrderStudioCore

enum MotionMedia {
    static func displaySize(at url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MotionFailure("A selected region's video is missing or unreadable.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }
}

struct MotionPane: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var motion = AutomaticMotion()
    @State private var thumbnail: CGImage?
    @State private var sourceSize: CGSize?
    @State private var previewClip: VideoClip?
    @State private var previewError: String?
    @State private var progress = 0.0
    @State private var playing = false
    @State private var playbackStart = Date()
    private var selected: VideoClip? { store.selectedClip() }
    private var canvas: CGSize { store.project.exportSettings.canvasPixelSize }
    private var previewID: String { (store.document?.folderURL.path ?? "") + (selected?.id ?? "") + (selected?.videoFile ?? "") + String(selected?.trimInSeconds ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Motion").font(.headline)
                    Spacer()
                    Text("\(store.selectedClipIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close motion")
                }
                Text("Combine zoom and pan over each selected region’s edited length.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Amount").font(.caption)
                    ForEach(["Subtle", "Gentle", "Bold"], id: \.self) { name in
                        Button(name) {
                            let amount: (Double, Double) = name == "Subtle" ? (0.08, 0.04) : (name == "Gentle" ? (0.16, 0.08) : (0.35, 0.16))
                            motion.zoomAmount = amount.0; motion.panAmount = amount.1
                        }
                    }
                }.controlSize(.small)
                Picker("Zoom", selection: $motion.zoom) {
                    ForEach(MotionZoom.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                amountSlider("Zoom", value: $motion.zoomAmount, range: 0...1).disabled(motion.zoom == .none)
                Picker("Pan toward", selection: $motion.pan) {
                    ForEach(MotionPan.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                amountSlider("Travel", value: $motion.panAmount, range: 0...0.5).disabled(motion.pan == .none)
                HStack {
                    Text("Zoom focal point").font(.caption.weight(.medium))
                    Spacer()
                    Button("Center") { motion.focalX = 0; motion.focalY = 0 }.controlSize(.mini)
                }
                motionPreview
                HStack(spacing: 8) {
                    Button {
                        if playing { progress = Date().timeIntervalSince(playbackStart).truncatingRemainder(dividingBy: 4) / 4 }
                        else { playbackStart = Date().addingTimeInterval(-progress * 4) }
                        playing.toggle()
                    } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(.plain).disabled(previewClip == nil).help("Preview a four-second motion loop using a still frame")
                    Slider(value: $progress, in: 0...1, onEditingChanged: { if $0 { playing = false } })
                    Text("Still preview").font(.caption2).foregroundStyle(.secondary)
                }
                Text("Click the picture to set a zoom anchor. Pan moves the view toward the chosen direction.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Keep edges covered", isOn: $motion.keepEdgesCovered)
                Text("Adds crop to fill the canvas throughout the move. Turn off for smaller overlay videos.")
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("Existing motion", selection: $motion.combineWithExisting) {
                    Text("Add to existing").tag(true)
                    Text("Replace").tag(false)
                }
                Text("Add another motion to combine moves. Replace starts from the region’s opening framing. Apply creates editable markers; one Undo restores the whole selection.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let error = previewError { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(16)
          }
          Divider()
          HStack {
              Text("Preview: active region").font(.caption2).foregroundStyle(.secondary)
              Spacer()
              Button(store.isApplyingMotion ? "Applying…" : "Apply motion") {
                  playing = false
                  Task { if await store.applyAutomaticMotion(motion) { dismiss() } }
              }.buttonStyle(.borderedProminent)
                  .disabled(store.isApplyingMotion || store.selectedClipIDs.isEmpty || !motion.hasMotion || sourceSize == nil || previewClip == nil)
          }.padding(14)
        }.frame(width: 370, height: 630)
            .task(id: previewID) { await loadPreview() }
            .onChange(of: motion) { _ in updatePreview() }
            .onChange(of: selected) { _ in updatePreview() }
            .onChange(of: canvas) { _ in updatePreview() }
            .disabled(store.isApplyingMotion)
    }

    private func amountSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 40, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 37, alignment: .trailing)
        }
    }

    private var motionPreview: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { clock in
            let t = playing ? clock.date.timeIntervalSince(playbackStart).truncatingRemainder(dividingBy: 4) / 4 : progress
            GeometryReader { geometry in
                let fit = min(geometry.size.width / canvas.width, geometry.size.height / canvas.height)
                let frame = CGSize(width: canvas.width * fit, height: canvas.height * fit)
                ZStack {
                    Color.black
                    if let thumbnail, let sourceSize, let clip = previewClip {
                        let pose = clip.automatedFraming(atLocalSecond: t * clip.durationSeconds)
                        let scale = min(frame.width / sourceSize.width, frame.height / sourceSize.height)
                        Image(decorative: thumbnail, scale: 1)
                            .resizable().frame(width: sourceSize.width * scale, height: sourceSize.height * scale)
                            .scaleEffect(pose.zoom).rotationEffect(.degrees(-pose.rotationDegrees))
                            .offset(x: pose.offsetX * frame.width / 2, y: pose.offsetY * frame.height / 2)
                    } else if previewError == nil { ProgressView().controlSize(.small) }
                    Image(systemName: "plus.circle").foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .offset(x: motion.focalX * frame.width / 2, y: motion.focalY * frame.height / 2)
                }.frame(width: frame.width, height: frame.height).clipped()
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if playing { progress = Date().timeIntervalSince(playbackStart).truncatingRemainder(dividingBy: 4) / 4 }
                        playing = false
                        motion.focalX = min(1, max(-1, Double(value.location.x / frame.width) * 2 - 1))
                        motion.focalY = min(1, max(-1, Double(value.location.y / frame.height) * 2 - 1))
                    })
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }.frame(height: 178).background(Color.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func updatePreview() {
        guard let selected, let sourceSize else { return }
        do {
            previewClip = try motion.applying(to: selected, sourceSize: sourceSize, canvasSize: canvas)
            previewError = nil
        } catch { previewClip = nil; previewError = error.localizedDescription }
    }
    private func loadPreview() async {
        thumbnail = nil; sourceSize = nil; previewClip = nil; previewError = nil
        guard let clip = selected, let url = store.absoluteURL(for: clip.videoFile) else { return }
        do {
            let size = try await MotionMedia.displaySize(at: url)
            try Task.checkCancellation()
            sourceSize = size
            updatePreview()
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 540)
            let frame = try await generator.image(at: CMTime(seconds: max(0, clip.trimInSeconds + (clip.playbackSyncOffsetSeconds ?? 0)), preferredTimescale: 600))
            try Task.checkCancellation()
            thumbnail = frame.image
        } catch is CancellationError { return }
        catch { previewError = "Could not preview this video: \(error.localizedDescription)" }
    }
}
