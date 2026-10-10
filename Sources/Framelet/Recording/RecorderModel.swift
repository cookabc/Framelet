import AVFoundation
import AppKit
import Combine
import FrameletCore
import UniformTypeIdentifiers

@MainActor
final class RecorderModel: ObservableObject {
    @Published var phase: RecordingPhase = .idle
    @Published var clips: [RecordedClip] = []
    @Published var selected: RecordedClip?
    @Published var player: AVPlayer?
    @Published var duration = 0.0
    @Published var resolution = ""
    @Published var playbackTime = 0.0
    @Published var isPlaying = false
    @Published var elapsed = 0.0
    @Published var errorMessage: String?
    @Published var needsScreenCapturePermission = false
    @Published var notice: String?
    @Published var exporting = false
    @Published private var choosingDestination = false
    @Published var exportProgress = 0.0
    @Published var lastExport: URL?
    @Published var fps = 30
    @Published var showsCursor = true
    @Published var recordingTitle = "区域录制"
    @Published var gifFPS = 15
    @Published var gifWidth = 960
    @Published var gifStart = 0.0
    @Published var gifDuration = 10.0
    weak var mainWindow: NSWindow?
    var showWindow: (() -> Void)?
    var onPhaseChange: (() -> Void)?
    private var selector: RegionSelector?
    private var panel: RecordingPanel?
    private var engine: CaptureEngine?
    private var countdownTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var playbackObserver: Any?
    private var playbackState: AnyCancellable?
    private var playbackEnd: AnyCancellable?
    private let libraryOverride: URL?
    private let trashFile: (URL) throws -> Void
    private var timer: Timer?
    private var clock = RecordingClock()
    private var region: CaptureRegion?
    private var segments: [URL] = []
    private var sessionDirectory: URL?
    private enum FinishIntent { case pause, stop, restart }
    private var finishIntent: FinishIntent = .stop

    var canControlRecording: Bool { phase == .recording || phase == .paused }
    var hasActiveRecording: Bool {
        switch phase {
        case .starting, .recording, .pausing, .paused, .stopping, .restarting: return true
        default: return false
        }
    }

    var busy: Bool { phase != .idle || exporting || choosingDestination }
    var libraryURL: URL {
        if let libraryOverride { return libraryOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Framelet/Recordings", isDirectory: true)
    }
    var formattedElapsed: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    init(
        libraryURL: URL? = nil,
        trash: @escaping (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        libraryOverride = libraryURL
        trashFile = trash
        reloadClips()
    }

    // MARK: - Library and preview

    func reloadClips(select url: URL? = nil) {
        do {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: libraryURL, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
            clips = files.filter { $0.pathExtension == "mp4" }.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]),
                    (values.fileSize ?? 0) > 0
                else { return nil }
                return RecordedClip(url: url, date: values.creationDate ?? .distantPast)
            }.sorted { $0.date > $1.date }
            if let target = url.flatMap({ url in clips.first { $0.url == url } })
                ?? (selected == nil ? clips.first : nil)
            {
                select(target)
            }
        } catch { errorMessage = "无法读取录制目录：\(error.localizedDescription)" }
    }

    func select(_ clip: RecordedClip) {
        guard !busy else { return }
        metadataTask?.cancel()
        clearPlayer()
        selected = clip
        player = AVPlayer(url: clip.url)
        attachPlaybackObservers()
        notice = nil
        lastExport = nil
        duration = 0
        resolution = ""
        gifStart = 0
        metadataTask = Task {
            do {
                let asset = AVURLAsset(url: clip.url)
                let seconds = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first, seconds.isFinite, seconds > 0 else {
                    throw NSError(
                        domain: "Framelet", code: 2, userInfo: [NSLocalizedDescriptionKey: "录制文件没有可播放的画面。"])
                }
                let size = try await track.load(.naturalSize)
                try Task.checkCancellation()
                guard selected?.url == clip.url else { return }
                duration = seconds
                gifDuration = min(10, seconds)
                resolution = "\(Int(size.width)) × \(Int(size.height))"
            } catch is CancellationError {} catch { errorMessage = "无法预览录制：\(error.localizedDescription)" }
        }
    }

    private func clearPlayer() {
        player?.pause()
        if let playbackObserver { player?.removeTimeObserver(playbackObserver) }
        playbackObserver = nil
        playbackState = nil
        playbackEnd = nil
        player = nil
        isPlaying = false
        playbackTime = 0
    }

    private func attachPlaybackObservers() {
        guard let player else { return }
        playbackObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.playbackTime = max(0, time.seconds.isFinite ? time.seconds : 0) }
        }
        playbackState = player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink {
            [weak self] status in
            self?.isPlaying = status == .playing
        }
        playbackEnd = NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem
        )
        .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.isPlaying = false }
    }

    func togglePlayback() {
        guard !busy, let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if playbackTime >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
        }
    }

    func seekPlayback(to time: Double) {
        guard !busy else { return }
        playbackTime = max(0, min(duration, time))
        player?.seek(to: CMTime(seconds: playbackTime, preferredTimescale: 600))
    }

    func deleteClip(_ clip: RecordedClip) {
        guard !busy, clips.contains(clip) else { return }
        do {
            try RecordingLibrary.moveToTrash(clip.url, in: libraryURL, trash: trashFile)
            if selected == clip {
                metadataTask?.cancel()
                metadataTask = nil
                clearPlayer()
                selected = nil
                duration = 0
                resolution = ""
            }
            reloadClips()
            lastExport = nil
            notice = "已移到废纸篓"
        } catch { errorMessage = "删除失败：\(error.localizedDescription)" }
    }

    // MARK: - Recording lifecycle

    private func setPhase(_ value: RecordingPhase) {
        phase = value
        onPhaseChange?()
    }

    func toggleCapture() {
        switch phase {
        case .idle: beginSelection()
        case .recording, .paused: stopRecording()
        case .selecting, .countdown: cancelSelection()
        case .starting, .pausing, .stopping, .restarting: break
        }
    }

    func beginSelection() {
        guard !busy else {
            // The button and the hot key are both disabled during an export, which would
            // otherwise look like a broken shortcut rather than a deliberate refusal.
            if exporting || choosingDestination { notice = "导出进行中，完成后才能开始新的录制。" }
            return
        }
        errorMessage = nil
        notice = nil
        needsScreenCapturePermission = false
        // SCShareableContent performs the actual authorization check. A CoreGraphics preflight
        // result must not prevent a working ScreenCaptureKit request from being attempted.
        player?.pause()
        mainWindow?.orderOut(nil)
        setPhase(.selecting)
        let selector = RegionSelector()
        self.selector = selector
        selectionTask = Task { [self, selector] in
            do {
                try await selector.begin { [weak self, weak selector] selection in
                    guard let self, self.selector === selector, self.phase == .selecting else { return }
                    self.selector = nil
                    if let selection {
                        self.beginCountdown(selection)
                    } else {
                        self.setPhase(.idle)
                        self.showWindow?()
                    }
                }
            } catch {
                guard self.selector === selector, phase == .selecting else { return }
                reportCaptureFailure(error, action: "读取应用窗口")
                selector.cancel()
            }
        }
    }

    private func beginCountdown(_ region: CaptureRegion) {
        self.region = region
        recordingTitle = region.title
        clock.reset()
        elapsed = 0
        segments = []
        sessionDirectory = RecordingLibrary.newSessionURL(in: libraryURL)
        let panel = RecordingPanel(model: self)
        self.panel = panel
        panel.show(near: region)
        setPhase(.countdown(3))
        countdownTask = Task {
            for value in (1...3).reversed() {
                setPhase(.countdown(value))
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await startRecording(region)
        }
    }

    func cancelSelection() {
        guard phase == .selecting || isCountingDown else { return }
        countdownTask?.cancel()
        countdownTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        selector?.cancel()
        selector = nil
        panel?.close()
        panel = nil
        setPhase(.idle)
        showWindow?()
    }

    var isCountingDown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    private func startRecording(_ region: CaptureRegion) async {
        setPhase(.starting)
        let engine = CaptureEngine()
        self.engine = engine
        finishIntent = .stop
        guard let directory = sessionDirectory else { return }
        let url = directory.appendingPathComponent("segment-\(UUID().uuidString).mp4")
        engine.onStarted = { [weak self, weak engine] in
            guard let self, self.engine === engine, self.phase == .starting else { return }
            self.clock.resume(at: ProcessInfo.processInfo.systemUptime)
            self.setPhase(.recording)
            // Added in `.common` mode: `scheduledTimer` only runs in `.default`, so the reading
            // would freeze while a menu is open or the user is dragging a slider.
            let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsed = self.clock.elapsed(at: ProcessInfo.processInfo.systemUptime)
                }
            }
            RunLoop.main.add(ticker, forMode: .common)
            self.timer = ticker
        }
        engine.onFinished = { [weak self, weak engine] result in
            guard let self, self.engine === engine else { return }
            Task { await self.segmentFinished(result) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await engine.start(region: region, url: url, fps: fps, cursor: showsCursor)
        } catch {
            guard self.engine === engine else { return }
            await segmentFinished(.failure(error))
        }
    }

    func stopRecording() {
        finishTake(intent: .stop)
    }

    func togglePause() {
        if phase == .recording {
            finishTake(intent: .pause)
        } else if phase == .paused, let region {
            setPhase(.starting)
            Task { await startRecording(region) }
        }
    }

    func restartRecording() { finishTake(intent: .restart) }

    private func finishTake(intent: FinishIntent) {
        guard canControlRecording else { return }
        let wasPaused = phase == .paused
        finishIntent = intent
        // The clock is frozen by `segmentFinished`, not here: the encoder keeps writing until the
        // stream actually stops, so stopping the count now would make the reading shorter than the
        // file it describes.
        setPhase(intent == .pause ? .pausing : intent == .restart ? .restarting : .stopping)
        if wasPaused {
            Task { await completeTake(restart: intent == .restart) }
        } else {
            Task { await engine?.stop() }
        }
    }

    private func freezeClock() {
        clock.pause(at: ProcessInfo.processInfo.systemUptime)
        elapsed = clock.elapsed(at: ProcessInfo.processInfo.systemUptime)
        timer?.invalidate()
        timer = nil
    }

    private func segmentFinished(_ result: Result<URL, Error>) async {
        guard engine != nil else { return }
        freezeClock()
        engine = nil
        switch result {
        case .success(let url):
            segments.append(url)
            if finishIntent == .pause {
                setPhase(.paused)
            } else {
                setPhase(finishIntent == .restart ? .restarting : .stopping)
                await completeTake(restart: finishIntent == .restart)
            }
        case .failure(let error):
            // Keep completed segments available after a window closes or resume fails.
            if !segments.isEmpty {
                setPhase(.paused)
            } else {
                panel?.close()
                panel = nil
                setPhase(.idle)
                discardSessionIfUnusable()
            }
            reportCaptureFailure(error, action: "录制")
            errorMessage = (errorMessage ?? "录制中断。") + "\n已写入的片段保留在录制文件夹中的「未完成录制」。"
            showWindow?()
        }
    }

    private func completeTake(restart: Bool) async {
        let output = newRecordingURL()
        do {
            try await SessionAssembler.assemble(segments: segments, to: output)
            // Remove only this session's intermediates, after the final video has been committed.
            if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
            segments = []
            panel?.close()
            panel = nil
            setPhase(.idle)
            reloadClips(select: output)
            if restart, let region {
                notice = "上一段已保存"
                mainWindow?.orderOut(nil)
                beginCountdown(region)
            } else {
                notice = "录制已保存"
                showWindow?()
            }
        } catch {
            setPhase(.paused)
            errorMessage = "合并录制失败：\(error.localizedDescription)\n片段已保留，可点击停止重试。"
            showWindow?()
        }
    }

    private func newRecordingURL() -> URL {
        let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        return libraryURL.appendingPathComponent("Framelet-\(stamp)-\(UUID().uuidString.prefix(6)).mp4")
    }

    // MARK: - Unfinished takes

    /// Drops a session folder that ended up holding nothing decodable, so a take that failed
    /// before the encoder wrote a frame does not leave an invisible folder behind.
    private func discardSessionIfUnusable() {
        guard let sessionDirectory,
            RecordingLibrary.usableSegments(in: sessionDirectory).isEmpty
        else { return }
        RecordingLibrary.removeSession(sessionDirectory, in: libraryURL)
        self.sessionDirectory = nil
    }

    /// Joins takes that were interrupted before their segments were assembled — quitting the app
    /// mid-recording, or a failure the user dismissed — into ordinary recordings. Otherwise those
    /// segments stay on disk where nothing in the interface can reach them.
    func recoverUnfinishedSessions() async {
        guard phase == .idle, !exporting else { return }
        var recovered = 0
        for session in RecordingLibrary.unfinishedSessions(in: libraryURL) {
            let segments = RecordingLibrary.usableSegments(in: session)
            guard !segments.isEmpty else {
                RecordingLibrary.removeSession(session, in: libraryURL)
                continue
            }
            do {
                try await SessionAssembler.assemble(segments: segments, to: newRecordingURL())
                RecordingLibrary.removeSession(session, in: libraryURL)
                recovered += 1
            } catch {
                // Assembly never consumes its sources, so a transient failure is simply retried on
                // the next launch. Only a session with nothing decodable is safe to discard.
                if let failure = error as? SessionAssemblyError, case .noVideo = failure {
                    RecordingLibrary.removeSession(session, in: libraryURL)
                }
            }
        }
        guard recovered > 0 else { return }
        reloadClips()
        notice = "已恢复 \(recovered) 段未完成的录制"
    }

    // MARK: - Export

    func export(gif: Bool) {
        guard !busy, let clip = selected, duration > 0 else { return }
        player?.pause()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [gif ? .gif : .mpeg4Movie]
        savePanel.nameFieldStringValue = clip.exportName + (gif ? ".gif" : ".mp4")
        savePanel.title = gif ? "导出动图" : "保存视频"
        savePanel.prompt = "保存"
        savePanel.nameFieldLabel = "文件名："
        savePanel.canCreateDirectories = true
        guard let window = mainWindow else { return }
        let settings = GIFSettings(start: gifStart, duration: gifDuration, fps: gifFPS, maxWidth: gifWidth)
        choosingDestination = true
        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.choosingDestination = false
            guard response == .OK, let destination = savePanel.url else { return }
            self.exporting = true
            self.exportProgress = 0
            self.notice = nil
            self.exportTask = Task { [weak self] in
                guard let self else { return }
                do {
                    if gif {
                        try await GIFExporter.export(video: clip.url, to: destination, settings: settings) {
                            [weak self] value in
                            Task { @MainActor [weak self] in self?.exportProgress = value }
                        }
                    } else {
                        let copyTask = Task.detached {
                            try FileExport.copyVideo(from: clip.url, to: destination)
                        }
                        try await withTaskCancellationHandler {
                            try await copyTask.value
                        } onCancel: {
                            copyTask.cancel()
                        }
                    }
                    lastExport = destination
                    notice = "导出完成"
                } catch is CancellationError { notice = "已取消导出" } catch {
                    errorMessage = "导出失败：\(error.localizedDescription)"
                }
                exporting = false
                exportTask = nil
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    // MARK: - Recovery and file navigation

    private func reportCaptureFailure(_ error: Error, action: String) {
        needsScreenCapturePermission = CaptureFailure.isPermissionDenied(error)
        if needsScreenCapturePermission {
            errorMessage = "系统拒绝了屏幕录制请求。请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中检查本应用的授权。若已允许，请退出后从「应用程序」重新打开。"
        } else {
            let detail = error as NSError
            errorMessage =
                "\(action)失败：\(error.localizedDescription)\n错误：\(detail.domain) (\(detail.code))。这不一定是授权问题，请重试。"
        }
    }

    func openPermissions() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func revealLibrary() { NSWorkspace.shared.open(libraryURL) }
    func revealExport() { if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) } }
}
