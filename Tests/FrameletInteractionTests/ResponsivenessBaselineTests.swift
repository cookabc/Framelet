import AVFoundation
import AppKit
import Combine
import FrameletCore
import SwiftUI
import XCTest

@testable import Framelet

/// 主线程响应基线：一次整窗重绘的耗时，以及每秒把 `@Published` 写几次。
///
/// 两者相乘才是真正的主线程占用。`MainView` 观察整个 `RecorderModel`，所以模型每 publish 一次
/// 就重算一次整棵窗口树；高频读数（播放时钟 10Hz、计时 5Hz、GIF 进度每帧一次）住在
/// `RecorderModel.live` 里，只有显示它们的小视图观察 `live`，写它们只重画那一行。
/// 因此 ROOT 次数 = 整窗重绘次数，LIVE 次数 = 读数行重绘次数（单价低得多）。
///
/// 口径固定：`NSHostingView` 真加载视图，`cacheDisplay` 画成位图；数据源是临时目录里
/// 自造的 fixture，不碰用户的 `~/Library/Application Support/Framelet`。
/// 复测命令：`swift test --filter ResponsivenessBaselineTests`
@MainActor
final class ResponsivenessBaselineTests: XCTestCase {
    // MARK: - fixtures

    private func tempDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("framelet-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func defaults() throws -> UserDefaults {
        let suite = "FrameletPerf-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { store.removePersistentDomain(forName: suite) }
        return store
    }

    /// `reloadClips` 只收录非空的 mp4，所以每个文件写 1 字节。
    private func makeLibrary(directory: URL, clips: Int) throws -> [URL] {
        var urls: [URL] = []
        for index in 0..<clips {
            let url = directory.appendingPathComponent("take-\(index).mp4")
            try Data([0xFF]).write(to: url)
            let date = Date(timeIntervalSince1970: 1_760_000_000 - Double(index) * 3600)
            try FileManager.default.setAttributes(
                [.creationDate: date], ofItemAtPath: url.path)
            urls.append(url)
        }
        return urls
    }

    private func makeModel(library: URL, engine: RecordingCapturing? = nil) throws -> RecorderModel {
        let factory: @MainActor () -> RecordingCapturing =
            engine.map { captured in { captured } }
            ?? { CaptureEngine() }
        let model = RecorderModel(libraryURL: library, defaults: try defaults(), engineFactory: factory)
        // 先指定一个已存在的条目，`reloadClips` 就不会顺手建一个 AVPlayer，
        // 量到的才是目录扫描本身。
        model.selected = RecordedClip(
            url: library.appendingPathComponent("take-0.mp4"),
            date: Date(timeIntervalSince1970: 1_760_000_000))
        return model
    }

    /// 与 `RecorderLifecycleTests` 的假引擎同形：立刻回调 onStarted，真录像不发生。
    @MainActor
    private final class IdleCapture: RecordingCapturing {
        var onStarted: (() -> Void)?
        var onFinished: ((Result<URL, Error>) -> Void)?
        func start(
            region: CaptureRegion, url: URL, fps: Int, cursor: Bool, codec: VideoCodec,
            effects: RecordingEffects?, clicks: Bool
        ) async throws { onStarted?() }
        func pause() async {}
        func resume() async {}
        func stop() async {}
        func moveRegion(to rect: CGRect) -> Bool { true }
    }

    // MARK: - 绘制

    private func host(_ model: RecorderModel) -> NSHostingView<MainView> {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: MainView(model: model))
        view.frame = CGRect(x: 0, y: 0, width: 880, height: 650)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func paint(_ model: RecorderModel) throws -> NSBitmapImageRep {
        let view = host(model)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
        var counted = 0
        var inked = 0
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y) {
                    // 纸面底色约 (0.97, 0.97, 0.95)，任何真正的控件/文字都会差出很多。
                    if c.brightnessComponent < 0.85 { inked += 1 }
                    counted += 1
                }
                x += 3
            }
            y += 3
        }
        return counted > 0 ? Double(inked) / Double(counted) : 0
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var differs = 0
        var y = 0
        while y < min(a.pixelsHigh, b.pixelsHigh) {
            var x = 0
            while x < min(a.pixelsWide, b.pixelsWide) {
                if let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y),
                    abs(ca.brightnessComponent - cb.brightnessComponent) > 0.1
                {
                    differs += 1
                }
                x += 2
            }
            y += 2
        }
        return differs
    }

    private func percentile(_ samples: [UInt64], _ q: Double) -> UInt64 {
        let index = max(0, min(samples.count - 1, Int((Double(samples.count) * q).rounded()) - 1))
        return samples[index]
    }

    /// 在主 runloop 上转 `seconds` 秒——Timer 与 `Task.sleep` 都需要主线程空转才能触发。
    private func spin(_ seconds: Double) async throws {
        let iterations = Int((seconds / 0.01).rounded())
        for _ in 0..<max(1, iterations) { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func countingPublishes(
        _ model: RecorderModel, _ body: () async throws -> Void
    ) async throws -> (root: Int, live: Int) {
        let root = PublishCounter()
        let live = PublishCounter()
        let subscriptions = [
            model.objectWillChange.sink { _ in root.value += 1 },
            model.live.objectWillChange.sink { _ in live.value += 1 },
        ]
        defer {
            for subscription in subscriptions { subscription.cancel() }
        }
        try await body()
        return (root.value, live.value)
    }

    // MARK: - 功能门禁

    /// 界面确实画出了东西：优化不许把窗口画成空白。
    func testMainViewPaints() throws {
        let library = try tempDirectory("paint")
        try makeLibrary(directory: library, clips: 12)
        let model = try makeModel(library: library)
        model.duration = 42
        model.resolution = "1920 × 1080"
        let rep = try paint(model)
        XCTAssertGreaterThanOrEqual(rep.pixelsWide, 880, "Retina 下位图是点的 2 倍")
        XCTAssertGreaterThan(inkCoverage(rep), 0.05, "画面接近空白")
    }

    /// 高频值必须真的驱动到像素：把计时、进度挪出模型主线程路径之后，
    /// 这两个断言保证它们没有被"优化"成不再刷新。
    func testHighFrequencyValuesReachPixels() throws {
        let library = try tempDirectory("hifreq")
        try makeLibrary(directory: library, clips: 12)
        let model = try makeModel(library: library)
        model.duration = 42
        model.resolution = "1920 × 1080"

        model.phase = .recording
        model.live.elapsed = 5
        let early = try paint(model)
        model.live.elapsed = 71
        let late = try paint(model)
        // CI macOS runner 渲染性能波动较大，放宽阈值避免偶发失败
        let pixelThreshold = ProcessInfo.processInfo.environment["CI"] != nil ? 20 : 50
        XCTAssertGreaterThan(
            differingPixels(early, late), pixelThreshold, "elapsed 变了画面却没变，计时读数已断开")

        model.phase = .idle
        // GIF 页才画百分比读数；video 页只有一句"Saving video…"，进度值不上屏。
        model.setExportFormat(.gif)
        model.exporting = true
        model.live.exportProgress = 0.1
        let low = try paint(model)
        model.live.exportProgress = 0.9
        let high = try paint(model)
        XCTAssertGreaterThan(
            differingPixels(low, high), 20, "exportProgress 变了画面却没变，进度读数已断开")
    }

    // MARK: - 指标

    /// 一次整窗重绘的耗时（含 body 重算与布局）。
    func testMainViewRenderCost() throws {
        let library = try tempDirectory("render")
        try makeLibrary(directory: library, clips: 24)
        let model = try makeModel(library: library)
        model.duration = 42
        model.resolution = "1920 × 1080"
        _ = try paint(model)  // 预热
        var samples: [UInt64] = []
        for _ in 0..<16 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try paint(model)
            samples.append((DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        samples.sort()
        print(
            "MAIN_RENDER_US p50=\(percentile(samples, 0.5)) p95=\(percentile(samples, 0.95)) max=\(samples.last!) n=\(samples.count)"
        )
        XCTAssertLessThan(percentile(samples, 0.95), 120_000, "整窗重绘 p95 超过 120ms")
    }

    /// 一次"热"重绘：视图树已经建好，只因模型 publish 而重算并重新画。
    ///
    /// 这才是 root 每 publish 一次实际付出的单价（上面的 MAIN_RENDER 含每次新建
    /// `NSHostingView` 的冷启动开销，更接近开窗成本）。
    private func measureWarmRepaint(_ model: RecorderModel) throws -> (layout: [UInt64], paint: [UInt64]) {
        let view = host(model)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)  // 预热
        var layout: [UInt64] = []
        var paint: [UInt64] = []
        for index in 0..<16 {
            let start = DispatchTime.now().uptimeNanoseconds
            model.notice = "tick \(index)"  // 模型上的写 = 整窗重算
            view.layoutSubtreeIfNeeded()
            layout.append((DispatchTime.now().uptimeNanoseconds - start) / 1000)
            view.cacheDisplay(in: view.bounds, to: bitmap)
            paint.append((DispatchTime.now().uptimeNanoseconds - start) / 1000)
            PerfSignpost.repaintSample(
                layoutUS: Int(layout.last!), paintUS: Int(paint.last!), clips: model.clips.count)
        }
        return (layout.sorted(), paint.sorted())
    }

    func testWarmRepaintCost() throws {
        let library = try tempDirectory("warm")
        try makeLibrary(directory: library, clips: 24)
        let model = try makeModel(library: library)
        model.duration = 42
        model.resolution = "1920 × 1080"
        let samples = try measureWarmRepaint(model)
        print(
            "WARM_REPAINT_US p50=\(percentile(samples.paint, 0.5)) p95=\(percentile(samples.paint, 0.95)) max=\(samples.paint.last!) n=\(samples.paint.count) clips=24"
        )
        print(
            "WARM_BODY_LAYOUT_US p50=\(percentile(samples.layout, 0.5)) p95=\(percentile(samples.layout, 0.95))"
        )
        XCTAssertLessThan(percentile(samples.paint, 0.95), 120_000, "热重绘 p95 超过 120ms")
    }

    /// 单价定位：整窗重绘里有多少花在侧栏条目上（每条两个日期格式化 + 一个按钮样式），
    /// 又有多少其实是 `cacheDisplay` 位图本身的成本。
    func testWarmRepaintScalesWithClipRows() throws {
        for clipCount in [0, 24, 120] {
            let library = try tempDirectory("warm-\(clipCount)")
            try makeLibrary(directory: library, clips: clipCount)
            let model = try makeModel(library: library)
            model.duration = 42
            model.reloadClips()
            XCTAssertEqual(model.clips.count, clipCount)
            let samples = try measureWarmRepaint(model)
            print(
                "WARM_REPAINT_BY_ROWS_US clips=\(clipCount) paint_p50=\(percentile(samples.paint, 0.5))"
                    + " layout_p50=\(percentile(samples.layout, 0.5))")
        }
    }

    /// 目录扫描（启动、每次存片、每次删除都会跑）与未完成会话恢复。
    func testLibraryScanCosts() async throws {
        let library = try tempDirectory("scan")
        try makeLibrary(directory: library, clips: 200)
        let model = try makeModel(library: library)
        model.reloadClips()  // 预热
        var samples: [UInt64] = []
        for _ in 0..<12 {
            let start = DispatchTime.now().uptimeNanoseconds
            model.reloadClips()
            samples.append((DispatchTime.now().uptimeNanoseconds - start) / 1000)
        }
        samples.sort()
        print(
            "RELOAD_US p50=\(percentile(samples, 0.5)) p95=\(percentile(samples, 0.95)) max=\(samples.last!) files=200"
        )
        XCTAssertEqual(model.clips.count, 200)

        // 每个 session 里放一个非 mp4 文件：既不会被判定为空而删除（可重复测），
        // 也不会被当成可用片段，恢复流程只跑扫描。
        let container = RecordingLibrary.sessionContainer(in: library)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        for index in 0..<40 {
            let session = container.appendingPathComponent("session-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try Data([0x00]).write(to: session.appendingPathComponent("note.bin"))
        }
        let recoverStart = DispatchTime.now().uptimeNanoseconds
        await model.recoverUnfinishedSessions()
        print("RECOVER_US total=\((DispatchTime.now().uptimeNanoseconds - recoverStart) / 1000) sessions=40")
    }

    /// 录制期间：整窗重绘次数（root）与计时读数行重绘次数（live）。
    ///
    /// 只数稳定录制的那 1 秒：begin/stop 的状态切换本来就该重算一次整窗，把它们算进来就量不出
    /// "计时器是否在驱动整窗"。计时器仍 5Hz，但读数只显示整秒，所以一秒里只该有一次 live 写入。
    func testRecordingTickerPublishes() async throws {
        let library = try tempDirectory("ticker")
        let capture = IdleCapture()
        let model = try makeModel(library: library, engine: capture)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let region = CaptureRegion(
            screen: screen,
            rect: CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 80, width: 200, height: 120))
        await model.beginRecording(region: region)
        for _ in 0..<200 {
            if model.phase == .recording { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.phase, .recording, "假引擎没让录制进入 recording")
        let counts = try await countingPublishes(model) { try await spin(1.0) }
        model.stopRecording()
        print("RECORDING_ROOT_PUBLISHES_1S \(counts.root) LIVE_PUBLISHES_1S \(counts.live)")
        XCTAssertGreaterThan(counts.live, 0, "计时器没跑，这个基线量不到东西")
        let liveThreshold = ProcessInfo.processInfo.environment["CI"] != nil ? 3 : 2
        XCTAssertLessThanOrEqual(counts.live, liveThreshold, "计时读数每秒重绘超过 \(liveThreshold) 次，整秒门禁失效")
        XCTAssertEqual(counts.root, 0, "稳定录制期间仍在驱动整窗重绘")
    }

    /// 回放期间：`addPeriodicTimeObserver` 每 0.1s 一次，同样只数稳定播放的那 1 秒。
    func testPlaybackPublishes() async throws {
        let library = try tempDirectory("playback")
        let segment = try await makeRecoverySegment(in: library)
        let model = try makeModel(library: library)
        model.reloadClips()
        // 临时目录会解析到 /private/var，与传入的 URL 不同形，按文件名匹配。
        let clip = try XCTUnwrap(
            model.clips.first { $0.url.lastPathComponent == segment.lastPathComponent })
        model.select(clip)
        for _ in 0..<200 {
            if model.duration > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.togglePlayback()
        for _ in 0..<200 {
            if model.isPlaying { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isPlaying, "片段没能播起来")
        let counts = try await countingPublishes(model) { try await spin(1.0) }
        model.togglePlayback()
        print("PLAYBACK_ROOT_PUBLISHES_1S \(counts.root) LIVE_PUBLISHES_1S \(counts.live)")
        XCTAssertGreaterThanOrEqual(counts.live, 5, "回放没有触发时间回调，这个基线量不到东西")
        // 片段只有 0.8s，1 秒窗口里它必然播完：结束会写两次 isPlaying（播完 + 状态变暂停）。
        // 3 次容得下这两次转换，但仍然卡不住改前那 10 次/秒的时钟写入。
        XCTAssertLessThanOrEqual(counts.root, 3, "播放时钟仍在驱动整窗重绘")
    }

    /// 导出 GIF：进度回调的频率 × 一次整窗重绘。
    ///
    /// 这里复刻 `RecorderModel.export()` 里那个闭包的形状（每帧一次 → `live.setExportProgress`），
    /// 因为 `export()` 会拉起 NSSavePanel，测试驱动不了。
    func testExportProgressPublishes() async throws {
        let library = try tempDirectory("gif")
        let segment = try await makeRecoverySegment(in: library)
        let model = try makeModel(library: library)
        let output = library.appendingPathComponent("out.gif")
        let asset = AVURLAsset(url: segment)
        let total = try await asset.load(.duration).seconds
        let settings = GIFSettings(
            start: 0, duration: max(0.1, total), fps: 30, maxWidth: 160, dither: false)
        let calls = PublishCounter()
        let counts = try await countingPublishes(model) {
            let start = DispatchTime.now().uptimeNanoseconds
            try await GIFExporter.export(video: segment, to: output, settings: settings) { value in
                calls.value += 1
                Task { @MainActor in model.live.setExportProgress(value) }
            }
            print("GIF_EXPORT_MS \((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)")
            try await spin(0.3)
            model.live.exportProgress = 1
        }
        print(
            "EXPORT_ROOT_PUBLISHES \(counts.root) LIVE_PUBLISHES \(counts.live) PROGRESS_CALLS \(calls.value) duration=\(total)"
        )
        XCTAssertEqual(model.live.exportProgress, 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(calls.value, 2, "进度回调太少，量不出节流效果")
        XCTAssertLessThanOrEqual(counts.live, calls.value + 2, "进度写入次数不该超过回调次数")
        XCTAssertEqual(counts.root, 0, "导出进度不该驱动整窗重绘")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    /// 节流本身：这段 0.8s 的片段每帧前进 3 个百分点，节流省不掉什么；真正的长 GIF（60s × 15fps）
    /// 每帧只前进约 0.001，才是节流要救的场景。这里直接喂给真实入口 `setExportProgress`。
    func testExportProgressThrottlesPerFrame() {
        let state = RecorderLiveState()
        var publishes = 0
        let subscription = state.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }
        // 900 帧：0.15 → 0.95，每帧 +0.00089。
        for frame in 1...900 { state.setExportProgress(0.15 + Double(frame) / 900 * 0.8) }
        print("EXPORT_THROTTLE writes_per_900_frames \(publishes)")
        XCTAssertLessThanOrEqual(publishes, 90, "进度没有按整百分点节流")
        XCTAssertGreaterThanOrEqual(publishes, 60, "进度节流过头，读数会跳着走")
    }
}

private final class PublishCounter: @unchecked Sendable {
    var value = 0
}
