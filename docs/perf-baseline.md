# 主线程响应基线（038_Framelet）

复测命令（唯一口径，改前改后都用它）：

```bash
swift test --filter ResponsivenessBaselineTests
```

门禁与指标都在 `Tests/FrameletInteractionTests/ResponsivenessBaselineTests.swift`，
全量回归用 `swift test`（改前改后均 0 失败）。

## 测量方式

Framelet 是普通窗口 app，但 UI 自动化仍走**进程内**：`NSHostingView` 真实加载 `MainView`，
`layoutSubtreeIfNeeded` 后用 `cacheDisplay` 强制绘制成位图，再对位图做墨点覆盖率 / 差异像素断言。

- 功能门禁：`testMainViewPaints`（墨点覆盖率 > 5%，不许把窗口画成空白）、
  `testHighFrequencyValuesReachPixels`（计时读数变化必须真的上屏：> 50 差异像素；
  GIF 进度 > 20 差异像素）。这两条保证高频读数不会被"优化"成不再刷新。
- 数据源固定：临时目录里自造的 mp4 / 会话目录，不碰用户的
  `~/Library/Application Support/Framelet`。
- 两个价格指标：
  - `MAIN_RENDER_US`——每次新建 `NSHostingView` 再画一帧（含冷启动构建，接近"打开窗口"的成本）。
  - `WARM_REPAINT_US` / `WARM_BODY_LAYOUT_US`——树已经建好，模型 publish 一次之后的
    "重算 + 布局 + 位图 blit"总耗时 / 其中只算重算 + 布局。**后者才是每次 root 写入的价格**：
    实测差值约 14.5 ms 全花在 `cacheDisplay` 把 1760 × 1300 位图整窗画出来这一步，而真实窗口
    走的是 AppKit 脏区绘制，不做整窗位图，所以这 14.5 ms 是测量手段本身的成本，不能算进 app。
- 频率指标成对给出：`ROOT`＝整窗重算次数（`RecorderModel.objectWillChange`），
  `LIVE`＝读数行重算次数（`RecorderLiveState.objectWillChange`）。
  主线程占用 = ROOT 次数 × `WARM_BODY_LAYOUT`。

## 口径二：unified log / Instruments 打点

同一处写入还发一份 `studio.framelet.mac` 的日志行 + `os_signpost` 事件（仅 DEBUG，
`Sources/Framelet/Recording/PerfSignposts.swift`），让门控能否在**测试自己的计数之外**被看到：

```bash
./scripts/measure-signpost.sh            # 跑基线套件，再按 xctest PID 收日志
```

2026-10-15 实测（同一次运行）：

| 字段 | 写入次数 | 真正触发重绘 | 比例 |
|---|---|---|---|
| `elapsed` | 5 | 1 | 20% |
| `exportProgress` | 939 | 117 | 12% |

`elapsed` 5 次写入只有 1 次上架，正是"计时器 5 Hz、读数只显示整秒"的门控；
`layout_us` p50=3226 / p95=3965、`paint_us` p50=17361 / p95=18953，与口径一的 stdout 数字同量级。

日志行用 `log show --predicate 'subsystem == "studio.framelet.mac"' --info --debug` 收集
（`log` 在 zsh 里是个函数，必须写 `/usr/bin/log`）。`os_signpost` 事件不进 `log show`，
只给 Instruments 看时间轴：`live-write` 区间一次＝一次上屏的写入，`warm-repaint` 点＝一次强制整窗重绘。

## before / after

| 指标 | 改前 | 改后 |
| --- | --- | --- |
| `PLAYBACK_ROOT_PUBLISHES_1S` 播放中整窗重算/秒 | 10（时钟 10Hz，稳定窗口按旧代码频率折算；旧口径的 begin+1s+stop 总计 14） | **2**（0.8s 片段播完的两次 `isPlaying` 转换） |
| `RECORDING_ROOT_PUBLISHES_1S` 录制中整窗重算/秒 | 5（计时器 5Hz；旧口径总计 17） | **0** |
| 计时读数行重算/秒 | —（与整窗同价） | 1（读数只显示整秒，5Hz 里省掉 4 次） |
| 60 s GIF 导出的整窗重算次数 | ≈ 900（每帧一次） | **0** |
| 60 s GIF 导出的进度写入次数 `EXPORT_THROTTLE` | 900 | **81**（按整百分点节流） |
| 主线程占用（次数 × `WARM_BODY_LAYOUT` p50 3.7 ms） | 播放 37 ms/s、录制 18 ms/s、60 s GIF 导出 ≈ 3.3 s | 播放 7 ms/s、录制 0、导出 0 s |
| `WARM_BODY_LAYOUT_US` p50 / p95 | 未测（新指标） | 3 686 / 4 559 |
| `WARM_REPAINT_US` p50 / p95（含位图 blit，只作回归门禁） | 未测（新指标） | 18 268 / 21 951 |
| `MAIN_RENDER_US` p50 / p95 | 49 367 / 51 177 | 49 184 / 53 819（未变，见下） |
| `RELOAD_US` p50（200 个文件） | 982 | 975 |
| `RECOVER_US`（40 个未完成会话） | 6 932 | 6 588 |
| `GIF_EXPORT_MS`（0.8 s 片段） | 445 | 382 |

`MAIN_RENDER_US` 没降是预期的：一次整窗重画的**单价**与写多少次无关，这次砍的是**次数**。
导出进度对 0.8 s 短片段没有节流效果（每帧前进约 3 个百分点，本来就该更新），
所以那条断言是 `live ≤ calls + 2`；节流效果由 `testExportProgressThrottlesPerFrame`
直接喂 900 帧来量。

## 改了什么

1. `Sources/Framelet/Recording/RecorderLiveState.swift`（新）：`elapsed` / `playbackTime` /
   `exportProgress` 从 `RecorderModel` 搬出来，外加两个带节流的入口
   （`tickElapsed` 只在整秒变化时写，`setExportProgress` 只在整百分点变化时写）。
2. `RecorderModel`：`@Published` 三兄弟改为 `let live`；计时器改走 `live.tickElapsed`，
   `export()` 的进度闭包改走 `live.setExportProgress`。
   非视图调用方（状态栏菜单在打开时取 `formattedElapsed`）仍走模型上的同名计算属性。
3. `MainView`：把读数拆成三个小视图 `PlaybackBar` / `RecordingControlsBar` /
   `ExportProgressRow`，它们 `@ObservedObject` 观察 `live`。根视图不再读高频值，
   所以一次 tick 只重画那一行。`RecordingHUD`（浮在录制区上的控制条）同样改为观察 `live`。
4. `Sources/Framelet/UI/ControlID.swift`（新）+ 各控件的 `.controlID(...)`。

## 否掉的假设（带数字）

- **侧栏条目渲染 / 逐条日期格式化是热点**：`testWarmRepaintScalesWithClipRows` 扫 0 / 24 / 120
  个文件，整窗 paint p50 分别 19.0 / 17.8 / 19.1 ms，body+layout p50 3.78 / 3.47 / 3.85 ms——
  完全不随行数变化（`LazyVStack` 只渲染可见条目）。日期文案确实每次访问都走
  `date.formatted(...)`，但它不在热点上，没预计算。
- **目录扫描阻塞主线程**：200 个文件 `reloadClips` p50 0.98 ms、40 个会话恢复 6.9 ms。
  在 50 ms 的整窗重画面前可以忽略，没动。
- **GIF 编码占主线程**：`GIFExporter.export` 是非隔离 async 函数，从 MainActor 调用时会跳到
  全局并发执行器；测试里导出进行的同 1 秒内进度回调照常送达（39 次），主循环没被堵住。没动。
- **AVFoundation 同步读取**：全仓只有 `await asset.load(...)`，没有 `asset.duration` 这类
  阻塞式属性读取（grep 过 `\.duration`/`naturalSize`/`semaphore`/`wait(`）。没动。
- **`swiftLanguageModes [.v5]` → `.v6`**：这是数据竞争安全项，不是响应性能项，收益为 0 而风险
  在编码器路径上。试着切了 `.v6`：第一个错在
  `Sources/FrameletCore/Export/VideoExporter.swift:79`——AVFoundation 的
  `@callee_guaranteed () -> ()` 完成回调不是 `Sendable`（`RegionIsolation::SendingRisksDataRace`），
  修一个文件会带出下一个。已回退到 `.v5`，留给单独的并发迁移 pass。

## 稳定标识符

`framelet.` 前缀，值即测试契约（改名会故意让测试挂掉）：
`newRecording`、`openLibrary`、`chooseArea`、`showFile`、`playToggle`、`playbackSlider`、
`elapsed`、`pauseRecording`、`recordAgain`、`stopRecording`、`exportFormat`、`exportButton`、
`exportStart`、`exportDuration`、`resetRange`、`exportProgress`、`cancelExport`，
录制浮条：`framelet.hud.time` / `framelet.hud.stop` / `framelet.hud.pause`。

标识符是给 XCUITest 用的。进程内测试**不**断言它们能被 AX 找到：`NSHostingView` 的元素树在无
窗口 host 里是懒建的，同一份代码两次跑出 8 个和 0 个标识符，这条断言不可复现。

## 已知缺口

- **没有 XCUITest target**：Framelet 是纯 SPM 可执行包，没有 `.xcodeproj`，起一个 UI 测试
  target 要先补工程生成。当前基线是进程内的，覆盖面是"绘制结果 + 写入频率"，不覆盖真实点击。
- **Time Profiler 接不上**：SPM 的测试宿主是 Mach-O bundle（`FrameletInteractionTests`），
  `xcrun xctrace record --launch` 起不来（`posix_spawn ... Exec format error`），要 profile
  只能 `--attach` 到 `swift test` 正在跑的 `xctest` PID。打点只做到 signpost + 日志行，
  火焰图这一层没接。
- **没做真机 GUI 验证**：本机 shell 没有屏幕录制权限，`screencapture` 直接失败
  （`could not create image from display`），所以改后的界面证据只有 `cacheDisplay` 位图门禁，
  没有人工看过的真实窗口。
