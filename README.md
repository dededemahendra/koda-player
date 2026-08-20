# Koda Player

A lightweight macOS video player that plays every format: MKV, AVI, WMV, FLV, TS, MOV,
MP4, WebM, RMVB, VOB, 3GP and the rest. [mpv](https://mpv.io) and FFmpeg do the demuxing
and decoding underneath. The app itself is a thin native AppKit shell: one window, an
auto-hiding control bar, and nothing else in the way.

```
./build-app.sh          # builds dist/Koda Player.app  (~63 MB, self-contained)
open "dist/Koda Player.app"

# or straight from a terminal, with a file or a stream
"dist/Koda Player.app/Contents/MacOS/Koda Player" ~/Movies/episode.mkv
"dist/Koda Player.app/Contents/MacOS/Koda Player" https://example.com/stream.m3u8
```

## What it does

- **Every container and codec FFmpeg supports.** No transcoding, no plugins, no "this file
  cannot be opened" dialogs.
- **Hardware decoding** through VideoToolbox, with an automatic software fallback.
- **Drag and drop** a video onto the window, or `⌘O`, or open it from Finder.
- **Streams too.** `⌘L` takes a URL, prefilled from the clipboard when it holds a link.
- **Subtitles.** Embedded tracks, sidecar `.srt`/`.ass` files picked up automatically, or
  dragged in later.
- **Multiple audio tracks** for dual-language files.
- **Chapters**, listed in the menu bar and the gear menu, with keys to walk them.
- **A-B loop** for repeating a passage, drawn as a band under the timeline.
- **Audio and subtitle sync** in 0.1s steps when a file is out of step with itself.
- **Picture controls.** Force an aspect ratio, zoom, crop to fill the window, and adjust
  brightness, contrast, saturation and gamma, from the `Video` menu or the gear button.
- **Repeat** a file until you stop it, instead of rolling on to the next one.
- **Media info** (`⌘I`). Codec, bitrate, frame rate, whether the decode is running on the
  GPU, and how many frames have been dropped, updating while it plays.
- **Remembers your settings.** Volume, mute, the colour adjustments and float-on-top come
  back the way you left them.
- **Keeps the Mac awake** while a video plays, and lets the screen sleep for audio-only
  files, where keeping it lit serves nobody.
- **Now Playing.** It appears in Control Center, and the play/pause keys on the keyboard
  or a pair of headphones work.
- **Window sizes.** `⌘1` / `⌘2` / `⌘3` for half, actual and double the video's own size,
  or pinch the trackpad to scale the window to anything in between.
- **Resumes where you left off** on files longer than two minutes.
- **A queue you can see** (`P`). The folder's videos listed in play order. Drag files or
  folders in to add them, drag rows to reorder, `⌫` to remove, click to play. When a file
  ends, the next one in the queue starts.
- Playback speed, volume up to 130%, screenshots to the Desktop.

## Keyboard

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `Space` / `K` | Play / pause | `F` or double-click | Full screen |
| `←` / `→` | Seek 5s | `Shift ←` / `Shift →` | Seek 60s |
| `J` / `L` | Seek 10s | `0`–`9` | Jump to 0–90% |
| `↑` / `↓` | Volume | `M` | Mute |
| `[` / `]` | Speed down / up | `Delete` | Normal speed |
| `,` / `.` | Frame step | `V` | Cycle subtitles |
| `<` / `>` | Previous / next chapter | `R` | Set A-B loop point |
| `Z` / `X` | Subtitle delay ∓0.1s | `⇧Z` / `⇧X` | Audio delay ∓0.1s |
| `A` | Cycle aspect ratio | `W` / `E` | Crop to fill ∓10% |
| `-` / `=` | Zoom out / in | `⇧⌘P` | Reset the picture |
| `⇧L` | Repeat this file | `I` | Media info panel |
| `⌘1` / `⌘2` / `⌘3` | Half / actual / double size | `P` | Show the queue |
| `S` | Screenshot to Desktop | `Esc` | Leave full screen |

`R` cycles: first press marks the loop start, the second marks the end, the third clears
it. Both delays reset to zero whenever a new file opens, so a correction made for one
video never follows you into the next.

Framing works the same way: a forced aspect ratio, a zoom and a crop are fixes for one
video, so they are cleared with every new file. The colour adjustments are not. Those
usually describe the display rather than the video, and they stay until you reset them.

Opening a file from Finder or `⌘O` rebuilds the queue around it, because that is a new
thing to watch. Playing a row of the queue does not, because otherwise anything you had
added would vanish the moment you used it. The queue lasts for the session and is not
written to disk.

The same line decides what survives quitting: volume, mute, the colour adjustments and
float-on-top are remembered, while everything that corrects a particular file is not.
That means sync offsets, forced aspect, zoom and crop.

## Trackpad

| Gesture | Action |
| --- | --- |
| Pinch | Resize the window. The video keeps its shape; the window follows it. |
| Pinch out, hard, once it can grow no further | Full screen |
| Pinch in while full screen | Leave full screen |
| `⌥` + pinch | Zoom the picture inside the window instead of resizing it |
| Two-finger double tap | Full screen |

## Requirements

Building needs Homebrew's mpv:

```
brew install mpv dylibbundler
```

`build-app.sh` copies libmpv and its codec libraries into the bundle, so the finished
`.app` runs on Macs without Homebrew. Without `dylibbundler` the app still builds, but it
will only run where Homebrew's mpv is installed.

For day-to-day development, `swift build && swift run` works and links against Homebrew
directly.

## How it works

| File | Role |
| --- | --- |
| `Sources/CMPV/module.modulemap` | Exposes libmpv's C API to Swift |
| `MPVPlayer.swift` | libmpv wrapper: commands, property observation, event loop |
| `MPVVideoView.swift` | mpv's render API drawing into an OpenGL surface |
| `PlayerViewController.swift` | Window contents, input, drag and drop, track menus |
| `ControlsView.swift` | The floating control bar |
| `InfoPanelView.swift` | The `⌘I` media info overlay |
| `PlaylistView.swift` | The queue panel: rows, reordering, drops |
| `NowPlayingController.swift` | Control Center, media keys, and staying awake |
| `AppDelegate.swift` | Menu bar and app lifecycle |
| `Tools/make-icon.swift` | Draws the app icon: a prism throwing a spectrum |

mpv renders through `MPV_RENDER_API_TYPE_OPENGL` rather than opening its own window,
because libmpv's `--wid` embedding is not supported on macOS. Frames are drawn on a
dedicated queue so decoding never stalls the interface.

### Troubleshooting

Two environment variables dump what the player is actually doing, which is handy when the
picture looks wrong or a file misbehaves:

```
KODA_FRAME_DUMP=/tmp/frame.png \
KODA_STATE_DUMP=/tmp/state.json \
  "dist/Koda Player.app/Contents/MacOS/Koda Player" video.mkv
```

`KODA_FRAME_DUMP` writes a rendered frame straight out of the GL back buffer (set
`KODA_FRAME_DUMP_DELAY` in seconds, default 2, to control when it samples), and
`KODA_STATE_DUMP` writes the resolution, duration, position, chapters, loop points, sync
offsets, picture settings and track list the player detected. `KODA_STATE_DUMP_DELAY`
(seconds, default 1.5) moves that sample later, which is how a chapter jump or a loop set
from the keyboard can be inspected after the fact.

A stream that loads its duration but never shows a picture is usually the server rather
than the player: mpv needs HTTP range requests to read an MP4 whose index sits at the end
of the file, and a server that ignores `Range` produces `error reading packet` and an
immediate EOF.

## Licensing

The bundled mpv/FFmpeg libraries are LGPL. Keeping them as separate dylibs inside
`Contents/Frameworks` (which is what `dylibbundler` does) satisfies the LGPL's relinking
requirement for redistribution.
