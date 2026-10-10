# Framelet

A native macOS window and area screen recorder. Pick a window or drag out an area, then record —
pause, resume and restart are supported, and takes can be previewed and exported as a video or a
looping animated image. This version records picture only, and all processing happens on this Mac.

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
| Choose a window | Hover to highlight, then click or press Return |
| Choose an area | Drag out the area and release |
| Cancel choosing | Press Escape or right-click |
| Record again | The record-again button on the floating bar saves the current video first, then records again over the same region |
| Export | "Save Video" or "Export GIF" |
| Delete | "Delete", or right-click a recording in the list, then confirm to move it to the Trash |

Recording starts after a countdown, three seconds by default and settable to 5 or 10. Paused time is
not counted towards the video's length. Closing the main window leaves the app running in the menu
bar.

The shortcuts are registered as exclusive global hot keys, so they can collide with another app.
Registration reports the collision rather than assuming success, and the app then falls back to the
next combination it can claim — `⌃⌘R` and `⌃⌘P`, then `⌃⇧⌘R` and `⌃⇧⌘P`. Whichever combination is
actually in use is what the window, the menu bar and this file report, and the status line says so
when the preferred one was taken.

### Capturing something that closes when you click

A menu bar panel, a dropdown or a context menu disappears the moment anything is clicked, so it
cannot be captured by clicking on it — clicking to choose it is what dismisses it. Choose the area it
appears in *first*, while it is closed, then open it during the countdown: the floating bar prompts
you at that point. Raise the countdown to 5 or 10 seconds if three is not enough time. The area is
remembered by "Record Again" on the floating bar, so a second take over the same area needs no
selection at all.

## Recording and files

- Area mode can select on any display, but one capture stays within a single display.
- Window mode follows the window you picked and locks the output size to the size it had when the
  capture started. Resizing the window afterwards can leave blank edges, and closing it means the
  recording cannot continue.
- 30 frames per second by default, 60 as an option, and the cursor can be shown or hidden. Output is
  H.264 video, with the long edge capped at 3840 pixels.
- Animated images loop, with a configurable start, duration, frame rate and long edge. They are capped
  at 60 seconds and default to the first 10 seconds, or the whole clip when it is shorter.
- Videos and animated images are saved as `.mp4` and `.gif`, both without sound.
- Original recordings live in `~/Library/Application Support/Framelet/Recordings/`. Closing the window
  or exporting does not delete them, and deleting an original leaves any exported copy alone.
- Pausing writes a media segment and stopping joins the segments back together. The intermediate
  segments are only cleaned up once the joined video has been saved; if that fails they are kept in an
  "Unfinished" folder inside the recordings folder.
- On the next launch, segments left in "Unfinished" are joined into ordinary recordings and added to
  the list, and folders holding nothing usable are discarded. A failed join never consumes the
  original segments, so it can simply be retried on the next launch; a session that cannot be joined
  at all is reported in the status line rather than retried in silence.
- Exports are written to a temporary file and only replace the destination on success, so cancelling or
  failing leaves any existing file untouched. Cancelling a video export stops the copy immediately
  instead of waiting for the whole file.
- The recording options — frame rate, cursor visibility, countdown length, and the animated image's
  frame rate and long edge — are remembered between launches, along with the main window's size and
  position. The animated image's start and duration are reset per recording, since they describe the
  selected clip.

## Development and installation

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
building and installing locally.

### Code formatting

The repository uses `.editorconfig` and `.swift-format` to keep formatting consistent, and CI enforces
it:

```sh
xcrun swift-format format --in-place --recursive Sources Tests scripts Package.swift
xcrun swift-format lint --strict --recursive Sources Tests scripts Package.swift
```

### What the tests cover

`swift test` covers coordinate conversion, window hit testing, permission error classification,
pause-aware timing, media assembly, animated image export, file protection and deletion boundaries, the
enumeration and cleanup of unfinished takes with their segment order, the chunk boundaries of
cancellable copying, and that the recording options survive a relaunch. The interaction tests drive the
selection view's event handling directly, covering the first click, double click, drag, Return to
confirm, and the panel's properties.

GitHub Actions runs the tests, a release-mode build, the formatting lint, and checks of the build script
and the app's information file on every push and pull request. It does not install the app, use a
signing certificate, or ask for screen recording permission.

Real screen capture, full-screen spaces, external displays and closing a recorded window still need
hands-on testing on an authorised machine. The automated tests are no substitute for those.

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
