# Framelet

A native macOS window and area screen recorder. Pick a window or drag out an area, then record —
pause, resume and restart are supported, and takes can be previewed and exported as a video or a
looping animated image. This version records picture only, and all processing happens on this Mac.

<p align="center">
  <img src="docs/images/overview.png" width="720" alt="Framelet's main window: a recordings sidebar next to the start panel with the cursor, countdown and frame rate options">
</p>

## Requirements

- macOS 15 or later.
- The Swift 6 toolchain from Xcode 16 or later for development and tests. No third-party dependencies.
- Building and installing the app needs a valid Apple Development or Developer ID signing identity on
  this Mac. Compiling and testing on their own need no certificate.

## Using it

Launch the app from `/Applications/Framelet.app`. The first time you record, allow screen recording
when the system asks.

| Action | How |
| --- | --- |
| Start / stop | `⌥⌘R`, or the "New Recording" and "Stop" buttons |
| Pause / resume | `⌥⌘P`, or the matching buttons on the floating bar |
| Choose a window or menu panel | Hover to highlight, then click, press Return or press the recording shortcut again |
| Choose an area | Drag out the area and release |
| Cancel choosing | Press Escape or right-click |
| Move the recorded area | Click "Move area", then drag inside the area; release to finish or right-click to cancel. Dragging the handle directly also works |
| Draw on the recording | The pencil button on the floating bar, then draw over the area |
| Undo a mark / clear all marks | The undo and eraser buttons that appear while drawing |
| Record again | The record-again button on the floating bar saves the current video first, then records again over the same region |
| Export | Choose MP4 or GIF, set the start and duration, then save |
| Delete | "Delete", or right-click a recording in the list, then confirm to move it to the Trash |

Recording starts after a countdown, three seconds by default and settable to 5 or 10. Paused time is
not counted towards the video's length. Closing the main window leaves the app running in the menu
bar.

The shortcuts are registered as exclusive global hot keys, so they can collide with another app.
Registration reports the collision rather than assuming success, and the app then falls back to the
next combination it can claim — `⌃⌘R` and `⌃⌘P`, then `⌃⇧⌘R` and `⌃⇧⌘P`. Whichever combination is
actually in use is shown in the window, selector and menu bar, and the status line says so
when the preferred one was taken.

### Capturing something that closes when you click

Open the panel, press the recording shortcut (`⌥⌘R` by default), then move the pointer over the panel
to highlight it. **Press the same shortcut again to confirm without clicking.** Return also confirms
when the selector shows that hint. Keep the panel open through the countdown and stop with the
recording shortcut when finished.

The selector never becomes the key window. Return and Escape are temporarily registered only while
choosing and released when the selector closes; a key already owned by another app is omitted from
the hints. Right-click always cancels. Keyboard confirmation closes the selector immediately; mouse
confirmation still absorbs a second click to avoid sending it through to the underlying window.

Menu panels are recorded as a fixed screen area, including whatever later appears in that area.
Some apps dismiss their panels on outside clicks or shortcuts themselves. For these, drag out the
area first and reopen the panel during the countdown, which can be raised to 5 or 10 seconds.
"Record Again" reuses the same area. Normal windows still use window capture and dragging still
selects an arbitrary area.

## Recording, annotations and files

- Area mode selects on any display, but one take remains within a single display. Moving the controls
  only moves the controls. Click "Move area" to activate a dashed-border movement surface and drag
  inside it, or drag the handle directly. Releasing finishes the move; right-click cancels the mode.
- Area mode requests best-resolution composed display frames and crops them before encoding. Only
  selected pixels are saved. Selections are aligned inward to the display pixel grid and even output
  dimensions, trimming at most a few edge pixels instead of resampling the whole small area. Processing
  whole-display frames can use more GPU memory than capturing a source rectangle directly.
- Window mode follows the selected window and locks the output dimensions at the start of the take.
  System scaling handles later size changes; closing the target may interrupt capture.
- 30 fps is the default, with 60 fps available. The cursor can be shown or hidden. Optional native
  ScreenCaptureKit click feedback is off by default and needs no global keyboard monitoring.
- Video is H.264 by default, or HEVC, with the long edge capped at 3840 pixels. Screen-content bitrate
  targets scale with encoded pixels and frame rate, with a 2 Mbps floor for small recordings. This can
  use more disk space than system-default compression; it remains lossy. HEVC can reduce file size,
  but the result depends on content and the available encoder, not a fixed reduction ratio.
- Pausing gates frames without restarting capture and removes the actual pause from the media
  timeline. Static content before a pause and after resume still contributes active recording time.

### Drawing on an area recording

Use the pencil button to enter drawing mode. Pen, highlighter, arrow, five colours, undo and clear
are shown inside the expanded control bar. Outside drawing mode, the drawing surface ignores mouse
input and leaves the target usable. Neither panel becomes the key window.

The preview and encoded video use the same annotation painter. Finished marks remain visible, and
static content is refreshed when marks change. Undo and clear change future frames, not frames
already saved. Marks use desktop coordinates and disappear from the picture when the recording area
moves away from them. Window mode deliberately has no fixed-area drawing or movement controls;
its control bar says that it follows the window and that drag-selecting an area enables annotations.

There are no global keyboard taps or key bubbles. The app's registered control shortcuts do not read
ordinary typing. Click feedback is provided by ScreenCaptureKit itself.

### Preview, trim and export

- Videos are silent `.mp4`; animated images are looping `.gif`.
- Preview defaults to "Original size": one video pixel per display pixel, shrinking only when the
  clip does not fit. "Fit window" can enlarge a small clip and look softer. This switch changes
  preview only, not the recording or exported resolution; enlarging a small video cannot add detail.
- Choose an export format, set its start and duration, and save a new file. Video defaults to the whole
  clip. Full, silent MP4 exports copy the recording; shorter ranges use native passthrough export.
  Passthrough preserves encoded media but does not promise arbitrary frame-accurate cuts for every codec.
- GIF defaults to the first 10 seconds or the entire shorter clip, with a 60-second limit. Frame rate
  and long edge are configurable. The shared palette is derived from sampled original RGB values;
  GIF's 256-colour limit and histogram binning can still change colours.
- Dithering is on by default for smoother gradients; turn it off to keep fills flat. It is not a
  lossless-colour switch. GIF frame delays use cumulative centisecond boundaries to avoid timing drift.
- Exports stage beside the destination and replace it only after success. Cancellation or failure
  preserves an existing file. Exporting over an original or its hard/symbolic link is rejected.

### Library and recovery

Original recordings live in `~/Library/Application Support/Framelet/Recordings/`. Closing the window
or exporting never deletes them. Delete requires confirmation and moves an original to the Trash;
exported copies stay untouched.

A current take is staged in an `Unfinished` session directory. Only a completed, validated video enters
its final library name. If a stream interruption still permits finalization, the file is saved with
an interruption notice, not reported as a normal success. Non-empty failed files remain available for
inspection, even when they cannot be decoded; recovery does not promise to repair a truncated MP4.

On launch, Framelet attempts to recover current single-file takes and legacy segmented takes. Failed
recovery retains the sources. Only confirmed empty directories or zero-byte video husks are discarded;
unreadable files and unknown session contents are not silently deleted.

Frame rate, cursor visibility, click feedback, codec, countdown and GIF quality settings are remembered
between launches, together with the main window's size and position. Export ranges reset for each clip
and each selected format.

The full feature inventory, removals and scope decisions are in
[功能全集与取舍](docs/features.md).

## Development and installation

Clone the repository with `git clone https://github.com/cookabc/Framelet.git`, then:

```sh
# Compile and test without installing the app
swift build
swift test

# Quit the running app, then build, sign and install it
bash scripts/build.sh
open /Applications/Framelet.app
```

`Package.swift` opens directly in Xcode. The build script generates the icon, wraps the executable into
an app bundle and installs it to `/Applications/Framelet.app`. The first identity it picks is stored in
`.framelet-signing-identity` and reused by later builds. If no usable certificate is found it fails
rather than falling back to ad-hoc signing. An identity can also be named explicitly with the
`FRAMELET_SIGN_IDENTITY` environment variable.

Local signing configuration, certificates, environment files, build caches and installed bundles are
all excluded by `.gitignore`. Do not commit recordings or personal signing configuration. Distributing
the app to others additionally needs Developer ID signing and notarisation; this script only handles
building and installing locally. For packaging without installation, run
`bash scripts/build.sh --package-only`; it keeps the saved local signing identity unchanged.

### Code formatting

The repository uses `.editorconfig` and `.swift-format` to keep formatting consistent, and CI enforces
it:

```sh
xcrun swift-format format --in-place --recursive Sources Tests scripts Package.swift
xcrun swift-format lint --strict --recursive Sources Tests scripts Package.swift
```

### What the tests cover

`swift test` covers capture geometry, window selection, permission error classification, media
encoding and decoding, repeated pauses and static-frame duration, fixed-size crop movement, HEVC,
annotation placement and static-screen refresh, shared GIF palettes and dithering, frame delays,
non-destructive video trimming, cancellation, source-link protection, recovery and deletion boundaries.

Interaction tests directly drive selection and annotation input, check non-activating panels and
small-screen control layouts, and inject a capture implementation to verify the first take's overlay
wiring, pause/resume, accepted movement, interrupted-file preservation and per-clip export ranges.
The minimum main-window size is rendered for both export formats.

GitHub Actions runs the tests, a release-mode build, the formatting lint, and checks of the build script
and the app's information file on every push and pull request. It does not install the app, use a
signing certificate, or ask for screen recording permission.

Real screen capture, full-screen spaces, external displays and closing a recorded window still need
hands-on testing on an authorised machine. The automated tests are no substitute for those.

For an opt-in live regression check, keep a popup open and run
`FRAMELET_LIVE_PANEL_OWNER=magpie swift test --filter LivePanelCaptureTests` on a Mac with screen
recording access. It drives a partial-area drag through the real recorder, pauses, resumes and saves
a video to a temporary directory printed as `LIVE_PANEL_CAPTURE`. Inspect that video to check the
popup pixels; the test only asserts lifecycle and file creation. Test-process activation can dismiss
transient panels, so a persistent test window at popup level is also suitable. The ordinary test suite
skips this live check and separately verifies crop orientation, Retina scaling, encoded colors, output
dimensions and static-frame duration using synthetic frames.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/Framelet/Application/` | App entry point, menu bar and shortcuts |
| `Sources/Framelet/Capture/` | Selection panels, mouse events and screen capture |
| `Sources/Framelet/Recording/` | Recording state, coordination and the floating control bar |
| `Sources/Framelet/Library/` | Recording entries and file naming |
| `Sources/Framelet/UI/` | Main window, video preview and button styles |
| `Sources/FrameletCore/` | Capture geometry, timing, assembly, export and file management |
| `Tests/FrameletCoreTests/` | Core logic and media integration tests; `Support/` synthesises video |
| `Tests/FrameletInteractionTests/` | Regression tests for the selection view and the recording library |
| `Resources/`, `scripts/` | App information, icon generation and the build/install script |

## Permission troubleshooting

If recording still fails after granting permission, quit any older copy, reopen the app from
Applications, and check the permission for that copy. Permission can stop applying after the signing
identity or the location changes. The app decides from the actual result of the system capture request
and never edits or resets the system's permission itself.

Under the hood it uses Apple's [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
and [Image I/O](https://developer.apple.com/documentation/imageio).

## License

Framelet is released under the [MIT License](LICENSE).
