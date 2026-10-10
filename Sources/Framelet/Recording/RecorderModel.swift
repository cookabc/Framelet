import AVFoundation
import AppKit
import Combine
import FrameletCore
import UniformTypeIdentifiers

/// Recording options the user should not have to set again on every launch.
private enum SettingsKey {
    static let fps = "recordingFPS"
    static let showsCursor = "showsCursor"
    static let gifFPS = "gifFPS"
    static let gifWidth = "gifWidth"
}

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
    // These outlive a single take, so they are remembered across launches.
    @Published var fps = 30 {
        didSet { defaults.set(fps, forKey: SettingsKey.fps) }
    }
    @Published var showsCursor = true {
        didSet { defaults.set(showsCursor, forKey: SettingsKey.showsCursor) }
    }
    @Published var gifFPS = 15 {
        didSet { defaults.set(gifFPS, forKey: SettingsKey.gifFPS) }
    }
    @Published var gifWidth = 960 {
        didSet { defaults.set(gifWidth, forKey: SettingsKey.gifWidth) }
    }
    /// Per-clip: reset from the selected recording, so it is deliberately not remembered.
    @Published var recordingTitle = "Region"
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
    private let defaults: UserDefaults
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
        defaults: UserDefaults = .standard,
        trash: @escaping (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        libraryOverride = libraryURL
        self.defaults = defaults
        trashFile = trash
        defaults.register(defaults: [
            SettingsKey.fps: 30,
            SettingsKey.showsCursor: true,
            SettingsKey.gifFPS: 15,
            SettingsKey.gifWidth: 960,
        ])
        fps = defaults.integer(forKey: SettingsKey.fps)
        showsCursor = defaults.bool(forKey: SettingsKey.showsCursor)
        gifFPS = defaults.integer(forKey: SettingsKey.gifFPS)
        gifWidth = defaults.integer(forKey: SettingsKey.gifWidth)
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
        } catch { errorMessage = "Could not read the recordings folder: \(error.localizedDescription)" }
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
                        domain: "Framelet", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "This recording has no playable video."])
                }
                let size = try await track.load(.naturalSize)
                try Task.checkCancellation()
                guard selected?.url == clip.url else { return }
                duration = seconds
                gifDuration = min(10, seconds)
                resolution = "\(Int(size.width)) × \(Int(size.height))"
            } catch is CancellationError {} catch {
                errorMessage = "Could not preview the recording: \(error.localizedDescription)"
            }
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
            notice = "Moved to Trash"
        } catch { errorMessage = "Delete failed: \(error.localizedDescription)" }
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
            if exporting || choosingDestination {
                notice = "An export is running. You can start a new recording once it finishes."
            }
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
                reportCaptureFailure(error, action: "Reading app windows")
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
        // Pausing an already-paused take has nothing to stop and would strand the phase at
        // .pausing. `togglePause` never asks for it; this keeps the function total anyway.
        guard !(wasPaused && intent == .pause) else { return }
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
            let kept: Bool
            if !segments.isEmpty {
                setPhase(.paused)
                kept = true
            } else {
                panel?.close()
                panel = nil
                setPhase(.idle)
                kept = !discardSessionIfUnusable()
            }
            reportCaptureFailure(error, action: "Recording")
            // Only promise the segments were kept when a folder with something in it survived.
            if kept {
                errorMessage =
                    (errorMessage ?? "Recording was interrupted.")
                    + "\nThe segments written so far are in the Unfinished folder inside the recordings folder."
            }
            showWindow?()
        }
    }

    private func completeTake(restart: Bool) async {
        let output = newRecordingURL()
        do {
            try await SessionAssembler.assemble(segments: segments, to: output)
            // Remove only this session's intermediates, after the final video has been committed.
            if let sessionDirectory { RecordingLibrary.removeSession(sessionDirectory, in: libraryURL) }
            segments = []
            panel?.close()
            panel = nil
            setPhase(.idle)
            reloadClips(select: output)
            if restart, let region {
                notice = "Previous take saved"
                mainWindow?.orderOut(nil)
                beginCountdown(region)
            } else {
                notice = "Recording saved"
                showWindow?()
            }
        } catch {
            setPhase(.paused)
            errorMessage =
                "Could not join the recording: \(error.localizedDescription)\nThe segments were kept; press Stop to try again."
            showWindow?()
        }
    }

    /// Names a new recording after the local time it was made. `Date.ISO8601FormatStyle` reports
    /// UTC, which put a filename eight hours away from the time the interface shows for the same
    /// recording.
    private func newRecordingURL() -> URL {
        let stamp = Self.recordingNameFormatter.string(from: Date())
        return libraryURL.appendingPathComponent("Framelet-\(stamp)-\(UUID().uuidString.prefix(6)).mp4")
    }

    private static let recordingNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    // MARK: - Unfinished takes

    /// Drops a session folder that ended up holding nothing decodable, so a take that failed
    /// before the encoder wrote a frame does not leave an invisible folder behind.
    /// Returns whether a folder with usable segments is still on disk.
    private func discardSessionIfUnusable() -> Bool {
        guard let sessionDirectory else { return false }
        guard RecordingLibrary.usableSegments(in: sessionDirectory).isEmpty else { return true }
        RecordingLibrary.removeSession(sessionDirectory, in: libraryURL)
        self.sessionDirectory = nil
        return false
    }

    /// Joins takes that were interrupted before their segments were assembled — quitting the app
    /// mid-recording, or a failure the user dismissed — into ordinary recordings. Otherwise those
    /// segments stay on disk where nothing in the interface can reach them.
    func recoverUnfinishedSessions() async {
        let sessions = RecordingLibrary.unfinishedSessions(in: libraryURL)
        guard !sessions.isEmpty else {
            // Nothing to recover, but an earlier take may have left the container empty.
            RecordingLibrary.pruneEmptySessionContainer(in: libraryURL)
            return
        }
        var recovered = 0
        var stranded = 0
        for session in sessions {
            // A recording started while this is running must not have its session touched.
            guard phase == .idle, !exporting else { return }
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
                // Assembly never consumes its sources, so nothing is lost by leaving a session in
                // place. Only a session with nothing decodable is safe to discard outright.
                if let failure = error as? SessionAssemblyError, case .noVideo = failure {
                    RecordingLibrary.removeSession(session, in: libraryURL)
                } else {
                    stranded += 1
                }
            }
        }
        guard recovered > 0 || stranded > 0 else { return }
        if recovered > 0 { reloadClips() }
        // A session that cannot be joined is retried on every launch, so say so once rather than
        // failing silently forever.
        switch (recovered, stranded) {
        case (let joined, 0):
            notice =
                joined == 1 ? "Recovered 1 unfinished recording" : "Recovered \(joined) unfinished recordings"
        case (0, let stuck):
            notice =
                "\(stuck) unfinished recording\(stuck == 1 ? "" : "s") could not be joined."
                + " The segments remain in the Unfinished folder."
        case (let joined, let stuck):
            notice =
                "Recovered \(joined); \(stuck) could not be joined and remain in the Unfinished folder."
        }
    }

    // MARK: - Export

    func export(gif: Bool) {
        guard !busy, let clip = selected, duration > 0 else { return }
        player?.pause()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [gif ? .gif : .mpeg4Movie]
        savePanel.nameFieldStringValue = clip.exportName + (gif ? ".gif" : ".mp4")
        savePanel.title = gif ? "Export GIF" : "Save Video"
        savePanel.prompt = "Save"
        savePanel.nameFieldLabel = "File name:"
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
                    notice = "Export complete"
                } catch is CancellationError { notice = "Export cancelled" } catch {
                    errorMessage = "Export failed: \(error.localizedDescription)"
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
            errorMessage =
                "The system denied the screen recording request. Check this app under System Settings → Privacy & Security → Screen & System Audio Recording. If it is already allowed, quit the app and open it again from Applications."
        } else {
            let detail = error as NSError
            errorMessage =
                "\(action) failed: \(error.localizedDescription)\nError: \(detail.domain) (\(detail.code)). This is not necessarily a permissions problem; try again."
        }
    }

    func openPermissions() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func revealLibrary() { NSWorkspace.shared.open(libraryURL) }
    func revealExport() { if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) } }
}
