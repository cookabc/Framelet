import AVFoundation
import AppKit
import Combine
import FrameletCore
import UniformTypeIdentifiers

/// Recording options the user should not have to set again on every launch.
private enum SettingsKey {
    static let showsClicks = "showsClicks"
    static let codec = "recordingCodec"
    static let fps = "recordingFPS"
    static let showsCursor = "showsCursor"
    static let gifFPS = "gifFPS"
    static let gifWidth = "gifWidth"
    static let countdownSeconds = "countdownSeconds"
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
    @Published var codec: VideoCodec = .h264 {
        didSet { defaults.set(codec.rawValue, forKey: SettingsKey.codec) }
    }
    @Published var showsClicks = false {
        didSet { defaults.set(showsClicks, forKey: SettingsKey.showsClicks) }
    }
    @Published private(set) var pauseIsChanging = false
    /// How long to wait after the region is confirmed before capture starts. Raise it to capture
    /// something that has to be opened by hand, such as a menu bar panel.
    @Published var countdownSeconds = 3 {
        didSet { defaults.set(countdownSeconds, forKey: SettingsKey.countdownSeconds) }
    }
    /// Per-clip: reset from the selected recording, so it is deliberately not remembered.
    @Published var recordingTitle = "Region"
    @Published var gifStart = 0.0
    @Published var gifDuration = 10.0
    @Published private(set) var recovering = false
    weak var mainWindow: NSWindow?
    var showWindow: (() -> Void)?
    var onPhaseChange: (() -> Void)?
    private var selector: RegionSelector?
    private var panel: RecordingPanel?
    private var engine: RecordingCapturing?
    private let engineFactory: @MainActor () -> RecordingCapturing
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
    // Keep in-progress files out of the library until the encoder and validation have succeeded.
    private var takeURL: URL?
    private var sessionDirectory: URL?
    private var finalTakeURL: URL?

    var canControlRecording: Bool { phase == .recording || phase == .paused }
    var hasActiveRecording: Bool {
        switch phase {
        case .starting, .recording, .paused, .stopping, .restarting: return true
        default: return false
        }
    }

    var busy: Bool { phase != .idle || exporting || choosingDestination || recovering }
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
        },
        engineFactory: @escaping @MainActor () -> RecordingCapturing = { CaptureEngine() }
    ) {
        libraryOverride = libraryURL
        self.defaults = defaults
        self.engineFactory = engineFactory
        trashFile = trash
        defaults.register(defaults: [
            SettingsKey.codec: VideoCodec.h264.rawValue,
            SettingsKey.fps: 30,
            SettingsKey.showsCursor: true,
            SettingsKey.showsClicks: false,
            SettingsKey.gifFPS: 15,
            SettingsKey.gifWidth: 960,
            SettingsKey.countdownSeconds: 3,
        ])
        // Stored values are clamped back into the ranges the capture and export paths accept,
        // so a hand-edited or stale default cannot reach them verbatim.
        fps = min(240, max(1, defaults.integer(forKey: SettingsKey.fps)))
        showsCursor = defaults.bool(forKey: SettingsKey.showsCursor)
        showsClicks = defaults.bool(forKey: SettingsKey.showsClicks)
        codec = VideoCodec(rawValue: defaults.string(forKey: SettingsKey.codec) ?? "") ?? .h264
        gifFPS = min(30, max(1, defaults.integer(forKey: SettingsKey.gifFPS)))
        gifWidth = min(1920, max(64, defaults.integer(forKey: SettingsKey.gifWidth)))
        countdownSeconds = min(10, max(1, defaults.integer(forKey: SettingsKey.countdownSeconds)))
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
        case .selecting: selector?.confirmHovered()
        case .countdown: cancelSelection()
        case .starting, .stopping, .restarting: break
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
        // Leave time to arrange the target or reopen transient content if its owner dismissed it.
        let seconds = max(1, countdownSeconds)
        self.region = region
        recordingTitle = region.title
        clock.reset()
        elapsed = 0
        restartAfterSave = false
        takeURL = nil
        sessionDirectory = nil
        finalTakeURL = nil
        let panel = RecordingPanel(model: self)
        self.panel = panel
        panel.show(near: region)
        setPhase(.countdown(seconds))
        countdownTask = Task {
            for value in (1...seconds).reversed() {
                setPhase(.countdown(value))
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await beginRecording(region: self.region ?? region)
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

    func beginRecording(region: CaptureRegion) async {
        guard !recovering, !exporting, !choosingDestination, phase == .idle || isCountingDown else { return }
        clock.reset()
        elapsed = 0
        errorMessage = nil
        notice = nil
        self.region = region
        recordingTitle = region.title
        restartAfterSave = false
        let session = RecordingLibrary.newSessionURL(in: libraryURL)
        sessionDirectory = session
        finalTakeURL = newRecordingURL()
        takeURL = session.appendingPathComponent("take.mp4")
        setPhase(.starting)
        let engine = engineFactory()
        self.engine = engine
        guard let url = takeURL else { return }
        engine.onStarted = { [weak self, weak engine] in
            guard let self, self.engine === engine, self.phase == .starting else { return }
            self.clock.resume(at: ProcessInfo.processInfo.systemUptime)
            self.setPhase(.recording)
            self.startTicker()
        }
        engine.onFinished = { [weak self, weak engine] result in
            guard let self, let engine else { return }
            Task {
                guard self.engine === engine else { return }
                await self.takeFinished(result)
            }
        }
        do {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try await engine.start(
                region: region, url: url, fps: fps, cursor: showsCursor, codec: codec, clicks: showsClicks)
        } catch {
            guard self.engine === engine else { return }
            await takeFinished(.failure(error))
        }
    }

    func stopRecording() {
        guard canControlRecording else { return }
        guard let activeEngine = engine else { return }
        setPhase(.stopping)
        Task { await activeEngine.stop() }
    }

    func togglePause() {
        guard canControlRecording, !pauseIsChanging, let activeEngine = engine else { return }
        let wasPaused = phase == .paused
        pauseIsChanging = true
        Task {
            if wasPaused { await activeEngine.resume() } else { await activeEngine.pause() }
            guard self.engine === activeEngine else { return }
            pauseIsChanging = false
            guard canControlRecording else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if wasPaused {
                clock.resume(at: now)
                startTicker()
                setPhase(.recording)
            } else {
                clock.pause(at: now)
                elapsed = clock.elapsed(at: now)
                timer?.invalidate()
                timer = nil
                setPhase(.paused)
            }
        }
    }

    private func startTicker() {
        timer?.invalidate()
        let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = self.clock.elapsed(at: ProcessInfo.processInfo.systemUptime)
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func restartRecording() {
        guard canControlRecording else { return }
        guard let activeEngine = engine else { return }
        setPhase(.restarting)
        // Stopping naturally flows into `takeFinished`, which starts the next countdown over the
        // same region when the previous take was saved.
        restartAfterSave = true
        Task { await activeEngine.stop() }
    }

    private func takeFinished(_ result: Result<URL, Error>) async {
        guard engine != nil else { return }
        setPhase(.stopping)
        engine = nil
        clock.pause(at: ProcessInfo.processInfo.systemUptime)
        elapsed = clock.elapsed(at: ProcessInfo.processInfo.systemUptime)
        timer?.invalidate()
        timer = nil
        pauseIsChanging = false
        let restart = restartAfterSave
        restartAfterSave = false
        panel?.close()
        panel = nil
        switch result {
        case .success(let url):
            do {
                let saved = try await commitTake(url)
                setPhase(.idle)
                reloadClips(select: saved)
                if restart, let region {
                    notice = "Previous take saved"
                    beginCountdown(region)
                    return
                }
                notice = "Recording saved"
            } catch {
                setPhase(.idle)
                errorMessage =
                    "Could not save the recording: \(error.localizedDescription)\nThe take remains in the Unfinished folder."
            }
        case .failure(let error):
            let interruption = error as? CaptureInterruptionError
            reportCaptureFailure(interruption?.underlying ?? error, action: "Recording")
            if let recovered = interruption?.recoveredURL {
                do {
                    let saved = try await commitTake(recovered)
                    setPhase(.idle)
                    reloadClips(select: saved)
                    notice = "Recording interrupted; captured video saved"
                } catch {
                    setPhase(.idle)
                    errorMessage =
                        "The recording was interrupted. Its file remains in the Unfinished folder: \(error.localizedDescription)"
                }
            } else {
                pruneEmptyTake()
                setPhase(.idle)
                if sessionDirectory != nil {
                    errorMessage =
                        (errorMessage ?? "Recording interrupted.")
                        + "\nThe non-empty take was kept in the Unfinished folder; it may not be playable."
                }
            }
        }
        takeURL = nil
        finalTakeURL = nil
        sessionDirectory = nil
        showWindow?()
    }

    private func commitTake(_ url: URL) async throws -> URL {
        guard url.standardizedFileURL == takeURL?.standardizedFileURL else {
            throw SessionAssemblyError.noVideo
        }
        let asset = AVURLAsset(url: url)
        let length = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard length.isNumeric, length.seconds > 0, !tracks.isEmpty
        else { throw SessionAssemblyError.noVideo }
        let destination = finalTakeURL ?? newRecordingURL()
        try FileExport.commit(url, to: destination)
        if let sessionDirectory { RecordingLibrary.removeEmptySession(sessionDirectory, in: libraryURL) }
        takeURL = nil
        sessionDirectory = nil
        return destination
    }

    private func pruneEmptyTake() {
        guard let sessionDirectory else { return }
        if RecordingLibrary.isEmptySession(sessionDirectory) {
            RecordingLibrary.removeSession(sessionDirectory, in: libraryURL)
            self.sessionDirectory = nil
        }
    }

    private var restartAfterSave = false

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

    /// Finalizes decodable legacy segments without consuming non-empty files on a failed decode.
    func recoverUnfinishedSessions() async {
        guard !busy else { return }
        recovering = true
        defer { recovering = false }
        let sessions = RecordingLibrary.unfinishedSessions(in: libraryURL)
        guard !sessions.isEmpty else {
            // Nothing to recover, but an earlier take may have left a container empty.
            RecordingLibrary.pruneEmptySessionContainers(in: libraryURL)
            return
        }
        var recovered = 0
        var stranded = 0
        var discarded = 0
        for session in sessions {
            // A recording started while this is running must not have its session touched.
            guard phase == .idle, !exporting else { return }
            let segments = RecordingLibrary.usableSegments(in: session)
            guard !segments.isEmpty else {
                if RecordingLibrary.isEmptySession(session) {
                    RecordingLibrary.removeSession(session, in: libraryURL)
                    discarded += 1
                } else {
                    stranded += 1
                }
                continue
            }
            do {
                try await SessionAssembler.assemble(segments: segments, to: newRecordingURL())
                RecordingLibrary.removeRecoveredSegments(segments, in: session, library: libraryURL)
                recovered += 1
            } catch {
                // Failure to decode is not evidence that all the session's files are worthless.
                // Preserve them for inspection rather than silently deleting a partial recording.
                stranded += 1
            }
        }
        guard recovered > 0 || stranded > 0 || discarded > 0 else { return }
        if recovered > 0 {
            recovering = false
            reloadClips()
        }
        // A session that cannot be joined is retried on every launch, so say so once rather than
        // failing silently forever. Discarding is announced too, because the failure notice of an
        // interrupted take points at this folder and promises the segments were kept.
        var parts: [String] = []
        if recovered > 0 {
            parts.append(
                recovered == 1
                    ? "Recovered 1 unfinished recording" : "Recovered \(recovered) unfinished recordings")
        }
        if stranded > 0 {
            parts.append(
                "\(stranded) unfinished recording\(stranded == 1 ? "" : "s") could not be joined;"
                    + " the segments remain in the Unfinished folder")
        }
        if discarded > 0 {
            parts.append(
                discarded == 1
                    ? "1 that held nothing usable was discarded"
                    : "\(discarded) that held nothing usable were discarded")
        }
        notice = parts.joined(separator: "; ")
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
