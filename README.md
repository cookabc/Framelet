# Framelet

原生 macOS 窗口与区域录屏工具。选择窗口或拖选区域后开始录制，支持暂停、继续和重新录制，可预览并导出视频或循环动图。当前版本仅录画面，所有处理均在本机完成。

## 环境要求

- macOS 15 或更高版本。
- 开发和测试需要 Xcode 16 或更新版本提供的 Swift 6 工具链，无第三方依赖。
- 构建并安装应用需要本机有效的 Apple Development 或 Developer ID 签名身份；单独编译和测试不需要签名证书。

## 使用

从 `/Applications/Framelet.app` 启动应用。首次录制时，按系统提示允许屏幕录制。

| 操作 | 方式 |
| --- | --- |
| 开始／停止 | `⌃⇧⌘R`，或点击「新建录制」和「停止」 |
| 暂停／继续 | `⌃⇧⌘P`，或点击浮动条中的对应按钮 |
| 选择窗口 | 悬停高亮后单击或按回车确认 |
| 选择区域 | 拖拽框选，松开后确认 |
| 取消选择 | 按退出键或点击鼠标右键 |
| 重新录制 | 点击浮动条中的重录按钮，先保存当前视频，再沿用原范围录制 |
| 导出 | 点击「保存视频」或「导出动图」 |
| 删除 | 点击「删除」，或右键点击历史片段；确认后移到废纸篓 |

确认范围后倒数 3 秒开始录制。暂停期间不计入视频时长。关闭主窗口后，应用仍在菜单栏运行。快捷键采用独占注册；若已被其他应用占用，请使用窗口或菜单栏按钮。

## 录制与文件

- 区域模式可在任一显示器上框选，一次限定在一台显示器内。
- 窗口模式跟随选中的窗口，输出尺寸固定为开始时的尺寸；窗口缩放后可能出现留边，关闭窗口后无法继续录制该窗口。
- 默认每秒 30 帧，可选每秒 60 帧，并可选择是否显示鼠标。输出为 H.264 视频，长边最多 3840 像素。
- 动图循环播放，可设起点、时长、帧率和长边尺寸；最长 60 秒，默认使用前 10 秒，短视频使用实际时长。
- 视频和动图分别保存为 `.mp4` 和 `.gif`，均不含声音。
- 原始录制保存在 `~/Library/Application Support/Framelet/Recordings/`。关闭窗口或导出文件不会删除原始录制；删除原始录制也不影响已导出的副本。
- 暂停时保存媒体片段，停止时连续拼接。成片保存成功后才清理中间片段；失败时保留在录制目录下的「未完成录制」文件夹。
- 导出先写临时文件，成功后再替换目标文件。取消或失败时保留已有目标文件。

## 开发与安装

```sh
# 编译与测试，不安装应用
swift build
swift test

# 正常退出运行中的应用后，构建、签名并安装
bash scripts/build.sh
open /Applications/Framelet.app
```

`Package.swift` 可直接用 Xcode 打开。构建脚本生成图标、包装应用并安装到 `/Applications/Framelet.app`。首次选择的签名身份保存在 `.framelet-signing-identity` 中，后续构建继续使用同一身份；证书不可用时会报错，不回退为临时签名。可通过 `FRAMELET_SIGN_IDENTITY` 环境变量显式指定签名身份。

本机签名配置、证书、环境文件、构建缓存和安装包均由 `.gitignore` 排除。不要提交录制内容或个人签名配置。对外分发另需 Developer ID 签名与公证，当前脚本只负责本机构建安装。

### 代码格式

仓库使用 `.editorconfig` 和 `.swift-format` 统一格式：

```sh
xcrun swift-format format --in-place --recursive Sources Tests scripts Package.swift
xcrun swift-format lint --strict --recursive Sources Tests scripts Package.swift
```

### 验证范围

`swift test` 覆盖坐标转换、窗口命中、权限错误分类、暂停计时、媒体拼接、动图导出、文件保护和删除边界。交互测试直接运行选择视图的事件处理，检查首次点击、双击、拖拽、回车确认和面板属性。

GitHub Actions 在推送和拉取请求时运行测试、发布模式编译，以及构建脚本和应用信息文件检查。CI 不安装应用、不使用签名证书，也不请求屏幕录制权限。

实际屏幕捕获、全屏空间、外接显示器和窗口关闭等场景仍需授权后的本机测试，自动测试不能替代这些验证。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/Framelet/Application/` | 应用入口、菜单栏和快捷键 |
| `Sources/Framelet/Capture/` | 选择面板、鼠标事件和屏幕捕获 |
| `Sources/Framelet/Recording/` | 录制状态、协调逻辑和浮动控制条 |
| `Sources/Framelet/Library/` | 录制条目与文件命名 |
| `Sources/Framelet/UI/` | 主界面、视频预览和按钮样式 |
| `Sources/FrameletCore/` | 捕获几何、计时、拼接、导出和文件管理 |
| `Tests/FrameletCoreTests/` | 核心逻辑与媒体集成测试，`Support/` 提供合成视频 |
| `Tests/FrameletInteractionTests/` | 选择视图和录制库交互回归测试 |
| `Resources/`、`scripts/` | 应用信息、图标生成和构建安装脚本 |

## 权限排查

若已经授权仍无法录制，先退出旧副本，从「应用程序」重新打开，并检查该副本的屏幕录制权限。更换签名身份或运行位置后，旧授权可能不再适用。应用使用系统捕获请求的实际结果判断权限，不自行修改或重置系统授权。

底层使用 Apple 的 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 和 [Image I/O](https://developer.apple.com/documentation/imageio)。
