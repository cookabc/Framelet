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
                    Text(model.selected == nil ? "开始录制" : "录制预览").font(.system(size: 21, weight: .semibold))
                    Spacer()
                    if let clip = model.selected {
                        Button {
                            pendingDeletion = clip
                        } label: {
                            Label("删除", systemImage: "trash")
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
                        Button("显示文件") { model.revealExport() }.buttonStyle(RecorderButtonStyle())
                    }
                }.frame(height: 32)
            }.padding(22).background(paper)
        }
        .foregroundStyle(ink).tint(accent)
        .frame(minWidth: 880, minHeight: 650)
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .alert(
            "操作未完成",
            isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            if model.needsScreenCapturePermission { Button("打开系统设置") { model.openPermissions() } }
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "删除这段录制？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("移到废纸篓", role: .destructive) {
                if let clip = pendingDeletion { model.deleteClip(clip) }
                pendingDeletion = nil
            }
        } message: {
            Text("已导出的文件不会删除。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("我的录制", systemImage: "viewfinder")
                .font(.system(size: 20, weight: .semibold)).padding(.top, 6)
            Button {
                model.beginSelection()
            } label: {
                Label("新建录制", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(RecorderButtonStyle(tone: .primary)).disabled(model.busy)
                .keyboardShortcut("n", modifiers: .command)
            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.clips.isEmpty {
                        Text("暂无录制").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
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
                                Button("删除录制", role: .destructive) { pendingDeletion = clip }
                                    .disabled(model.busy)
                            }
                    }
                }
            }
            Button {
                model.revealLibrary()
            } label: {
                Label("录制文件夹", systemImage: "folder").frame(maxWidth: .infinity)
            }.buttonStyle(RecorderButtonStyle())
            VStack(alignment: .leading, spacing: 7) {
                shortcut("开始／停止", RecorderShortcuts.captureLabel)
                shortcut("暂停／继续", RecorderShortcuts.pauseLabel)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(16).frame(width: 190).background(.white)
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
            Text("点击选窗口，拖拽选区域").font(.system(size: 15))
            Button {
                model.beginSelection()
            } label: {
                Text("选择录制范围").frame(width: 180)
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
                }.buttonStyle(RecorderButtonStyle()).accessibilityLabel(model.isPlaying ? "暂停预览" : "播放预览")
                    .disabled(model.busy || model.duration <= 0)
                Text(clock(model.playbackTime)).monospacedDigit().frame(width: 42)
                Slider(
                    value: Binding(
                        get: { min(model.playbackTime, max(model.duration, 0.1)) },
                        set: { model.seekPlayback(to: $0) }),
                    in: 0...max(model.duration, 0.1)
                ).accessibilityLabel("播放进度").disabled(model.busy || model.duration <= 0)
                Text(clock(model.duration)).monospacedDigit().frame(width: 42)
                Text(model.resolution).foregroundStyle(.secondary).lineLimit(1)
            }.font(.system(size: 11)).padding(8).background(.white)
        }.clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var captureSettings: some View {
        HStack(spacing: 16) {
            Toggle("显示鼠标", isOn: $model.showsCursor).toggleStyle(.checkbox)
                .padding(.vertical, 8).contentShape(Rectangle())
            Spacer()
            Menu {
                Picker("帧率", selection: $model.fps) {
                    Text("每秒 30 帧").tag(30)
                    Text("每秒 60 帧").tag(60)
                }.pickerStyle(.inline)
            } label: {
                Text("录制：每秒 \(model.fps) 帧")
            }
            .menuStyle(.button).buttonStyle(RecorderButtonStyle()).fixedSize()
        }.font(.system(size: 12)).frame(height: 40).disabled(model.busy)
    }

    private var exportControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("动图设置").fontWeight(.medium)
                Spacer()
                Picker("长边", selection: $model.gifWidth) {
                    Text("640 像素").tag(640)
                    Text("960 像素").tag(960)
                    Text("1280 像素").tag(1280)
                }.frame(width: 175)
                Picker("帧率", selection: $model.gifFPS) {
                    Text("每秒 10 帧").tag(10)
                    Text("每秒 15 帧").tag(15)
                    Text("每秒 20 帧").tag(20)
                }.frame(width: 165)
            }.disabled(model.busy).controlSize(.large)
            HStack(spacing: 14) {
                rangeField("起点", value: $model.gifStart, range: 0...max(0, model.duration - 0.1))
                rangeField(
                    "时长", value: $model.gifDuration,
                    range: 0.1...max(0.1, min(60, model.duration - model.gifStart)))
                Text("最长 60 秒").font(.system(size: 10)).foregroundStyle(.secondary)
            }.disabled(model.busy || model.duration < 0.1)
                .onChange(of: model.gifStart) { _, value in
                    model.gifStart = max(0, min(value, max(0, model.duration - 0.1)))
                    model.gifDuration = max(0.1, min(model.gifDuration, model.duration - model.gifStart))
                }
            if model.exporting {
                HStack {
                    ProgressView(value: model.exportProgress)
                    Text("\(Int(model.exportProgress * 100))%").monospacedDigit()
                    Button("取消") { model.cancelExport() }.buttonStyle(RecorderButtonStyle())
                }.frame(height: 44)
            } else {
                HStack(spacing: 12) {
                    Button {
                        model.export(gif: false)
                    } label: {
                        Label("保存视频", systemImage: "film").frame(maxWidth: .infinity)
                    }.buttonStyle(RecorderButtonStyle())
                    Button {
                        model.export(gif: true)
                    } label: {
                        Label("导出动图", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity)
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
            Text("秒").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            Circle().fill(model.phase == .paused ? .orange : .red).frame(width: 8, height: 8)
            Text(model.phase.statusText).font(.system(size: 12))
            Text(model.formattedElapsed).monospacedDigit()
            Spacer(minLength: 0)
            Button(model.phase == .paused ? "继续" : "暂停") { model.togglePause() }.buttonStyle(
                RecorderButtonStyle())
            Button("重录") { model.restartRecording() }.buttonStyle(RecorderButtonStyle())
                .help("保存当前录制后重新开始")
            Button("停止") { model.stopRecording() }.buttonStyle(RecorderButtonStyle(tone: .destructive))
        }.disabled(!model.canControlRecording)
    }

    private func clock(_ time: Double) -> String {
        let value = max(0, Int(time.isFinite ? time : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
