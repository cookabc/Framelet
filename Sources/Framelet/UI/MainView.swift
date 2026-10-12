import FrameletCore
import SwiftUI

private let ink = Color(red: 0.12, green: 0.21, blue: 0.21)
private let accent = Color(red: 0.14, green: 0.43, blue: 0.37)
private let paper = Color(red: 0.97, green: 0.97, blue: 0.95)

struct MainView: View {
    @ObservedObject var model: RecorderModel
    @State private var pendingDeletion: RecordedClip?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(ink.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(model.selected == nil ? "Start Recording" : "Recording Preview").font(
                        .system(size: 21, weight: .semibold))
                    Spacer()
                    if let clip = model.selected {
                        Button {
                            pendingDeletion = clip
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(RecorderButtonStyle(tone: .destructive)).disabled(model.busy)
                    }
                }.frame(height: 44)
                if model.hasActiveRecording { recordingControls }
                if model.selected != nil { preview } else { emptyPreview }
                captureSettings
                if model.selected != nil { exportControls }
                HStack(spacing: 8) {
                    Text(model.notice ?? "").lineLimit(1).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if model.lastExport != nil {
                        Button("Show File") { model.revealExport() }.buttonStyle(RecorderButtonStyle())
                    }
                }.frame(height: 32)
            }.padding(22).background(paper)
        }
        .foregroundStyle(ink).tint(accent)
        .frame(minWidth: 880, minHeight: 650)
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .alert(
            "Action Incomplete",
            isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            if model.needsScreenCapturePermission {
                Button("Open System Settings") { model.openPermissions() }
            }
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Delete this recording?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Move to Trash", role: .destructive) {
                if let clip = pendingDeletion { model.deleteClip(clip) }
                pendingDeletion = nil
            }
        } message: {
            Text("Files you already exported are not deleted.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The English heading and folder button are wider than the Chinese labels this sidebar
            // was sized for, so they shrink on one line instead of wrapping onto two.
            HStack(spacing: 6) {
                Image(systemName: "viewfinder")
                Text("My Recordings").lineLimit(1).minimumScaleFactor(0.8)
            }.font(.system(size: 20, weight: .semibold)).padding(.top, 6)
            Button {
                model.beginSelection()
            } label: {
                Label("New Recording", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(RecorderButtonStyle(tone: .primary)).disabled(model.busy)
                .keyboardShortcut("n", modifiers: .command)
            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.clips.isEmpty {
                        Text("No recordings yet").font(.system(size: 12)).foregroundStyle(.secondary).padding(
                            .top, 12)
                    }
                    ForEach(model.clips) { clip in
                        Button {
                            model.select(clip)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "film").font(.system(size: 18))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(clip.title).font(.system(size: 13, weight: .medium))
                                    Text(clip.day).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(RecorderButtonStyle(tone: .row(model.selected == clip), height: 56))
                            .disabled(model.busy)
                            .contextMenu {
                                Button("Delete Recording", role: .destructive) { pendingDeletion = clip }
                                    .disabled(model.busy)
                            }
                    }
                }
            }
            Button {
                model.revealLibrary()
            } label: {
                Label("Recordings Folder", systemImage: "folder")
                    .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
            }.buttonStyle(RecorderButtonStyle())
            VStack(alignment: .leading, spacing: 7) {
                shortcut("Start / stop", RecorderShortcuts.captureLabel)
                shortcut("Pause / resume", RecorderShortcuts.pauseLabel)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(16).frame(width: 212).background(.white)
    }

    private func shortcut(_ name: String, _ key: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(key).monospaced()
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(
                accent)
            Text("Click a window, or drag an area").font(.system(size: 15))
            Button {
                model.beginSelection()
            } label: {
                Text("Choose Recording Area").frame(width: 180)
            }.buttonStyle(RecorderButtonStyle(tone: .primary)).disabled(model.busy)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var preview: some View {
        VStack(spacing: 0) {
            NativeVideoPreview(player: model.player).frame(minHeight: 120, maxHeight: .infinity).background(
                .black)
            HStack(spacing: 10) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }.buttonStyle(RecorderButtonStyle()).accessibilityLabel(
                    model.isPlaying ? "Pause preview" : "Play preview"
                )
                .disabled(model.busy || model.duration <= 0)
                Text(clock(model.playbackTime)).monospacedDigit().frame(width: 42)
                Slider(
                    value: Binding(
                        get: { min(model.playbackTime, max(model.duration, 0.1)) },
                        set: { model.seekPlayback(to: $0) }),
                    in: 0...max(model.duration, 0.1)
                ).accessibilityLabel("Playback position").disabled(model.busy || model.duration <= 0)
                Text(clock(model.duration)).monospacedDigit().frame(width: 42)
                Text(model.resolution).foregroundStyle(.secondary).lineLimit(1)
            }.font(.system(size: 11)).padding(8).background(.white)
        }.clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var captureSettings: some View {
        HStack(spacing: 16) {
            Toggle("Show cursor", isOn: $model.showsCursor).toggleStyle(.checkbox)
                .padding(.vertical, 8).contentShape(Rectangle())
            Spacer()
            Menu {
                Picker("Countdown", selection: $model.countdownSeconds) {
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                }.pickerStyle(.inline)
            } label: {
                Text("Countdown: \(model.countdownSeconds) s")
            }
            .menuStyle(.button).buttonStyle(RecorderButtonStyle()).fixedSize()
            Menu {
                Picker("Frame rate", selection: $model.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }.pickerStyle(.inline)
            } label: {
                Text("Recording: \(model.fps) fps")
            }
            .menuStyle(.button).buttonStyle(RecorderButtonStyle()).fixedSize()
            Menu {
                Picker("Codec", selection: $model.codec) {
                    ForEach(VideoCodec.allCases, id: \.self) { codec in
                        Text(codec.label).tag(codec)
                    }
                }.pickerStyle(.inline)
                Text("HEVC can reduce file size; H.264 is more widely compatible")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } label: {
                Text(model.codec.label)
            }
            .menuStyle(.button).buttonStyle(RecorderButtonStyle()).fixedSize()
        }.font(.system(size: 12)).frame(height: 40).disabled(model.busy)
    }

    private var exportControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("Animated Image").fontWeight(.medium)
                Spacer()
                Picker("Long edge", selection: $model.gifWidth) {
                    Text("640 px").tag(640)
                    Text("960 px").tag(960)
                    Text("1280 px").tag(1280)
                }.frame(width: 175)
                Picker("Frame rate", selection: $model.gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                }.frame(width: 165)
            }.disabled(model.busy).controlSize(.large)
            HStack(spacing: 14) {
                rangeField("Start", value: $model.gifStart, range: 0...max(0, model.duration - 0.1))
                rangeField("Duration", value: $model.gifDuration, range: 0.1...maxGIFDuration)
                // Reports the limit that actually applies, not just the app's own 60 s cap: on an
                // 11 s recording the field refuses anything above 11, so "Up to 60 s" misled.
                Text("Up to \(Int(maxGIFDuration.rounded())) s").font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }.disabled(model.busy || model.duration < 0.1)
                .onChange(of: model.gifStart) { _, value in
                    model.gifStart = max(0, min(value, max(0, model.duration - 0.1)))
                    model.gifDuration = max(0.1, min(model.gifDuration, maxGIFDuration))
                }
            if model.exporting {
                HStack {
                    ProgressView(value: model.exportProgress)
                    Text("\(Int(model.exportProgress * 100))%").monospacedDigit()
                    Button("Cancel") { model.cancelExport() }.buttonStyle(RecorderButtonStyle())
                }.frame(height: 44)
            } else {
                HStack(spacing: 12) {
                    Button {
                        model.export(gif: false)
                    } label: {
                        Label("Save Video", systemImage: "film").frame(maxWidth: .infinity)
                    }.buttonStyle(RecorderButtonStyle())
                    Button {
                        model.export(gif: true)
                    } label: {
                        Label("Export GIF", systemImage: "photo.on.rectangle.angled").frame(
                            maxWidth: .infinity)
                    }.buttonStyle(RecorderButtonStyle(tone: .primary))
                }.disabled(model.busy || model.duration < 0.1)
            }
        }.font(.system(size: 12))
    }

    private func rangeField(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View
    {
        HStack(spacing: 6) {
            Text(label)
            TextField(
                label,
                value: Binding(
                    get: { value.wrappedValue },
                    set: {
                        value.wrappedValue =
                            $0.isFinite ? min(max($0, range.lowerBound), range.upperBound) : range.lowerBound
                    }), format: .number.precision(.fractionLength(1))
            )
            .textFieldStyle(.roundedBorder).frame(width: 62).controlSize(.large)
            Text("s").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            Circle().fill(model.phase == .paused ? .orange : .red).frame(width: 8, height: 8)
            Text(model.phase.statusText).font(.system(size: 12))
            Text(model.formattedElapsed).monospacedDigit()
            Spacer(minLength: 0)
            Button(model.phase == .paused ? "Resume" : "Pause") { model.togglePause() }.buttonStyle(
                RecorderButtonStyle())
            Button("Record Again") { model.restartRecording() }.buttonStyle(RecorderButtonStyle())
                .help("Save this take, then start a new one")
            Button("Stop") { model.stopRecording() }.buttonStyle(RecorderButtonStyle(tone: .destructive))
        }.disabled(!model.canControlRecording)
    }

    /// The animated image cannot run past the end of the clip, whatever the app's own cap says.
    private var maxGIFDuration: Double { max(0.1, min(60, model.duration - model.gifStart)) }

    private func clock(_ time: Double) -> String {
        let value = max(0, Int(time.isFinite ? time : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
