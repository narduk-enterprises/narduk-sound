# Now Playing, remote commands and AirPlay (`NardukMusicPlayback`)

`NardukMusicPlayback` (Darwin only) gives any app on narduk-sound lock screen and HomePod controls and an AirPlay
button. MediaPlayer and AVKit are linked here and nowhere in `NardukMusicEngine`.

```swift
import NardukMusicPlayback

// 1. Conform the player (the conductor driver, or the app's own) to the small transport protocol.
extension MyPlayer: NowPlayingTransport {}   // isPlaying, play(), pause(), next(); supportsNext defaults to true

// 2. Start the bridge once, publish when the track, genre or play state changes, stop when playback ends.
let bridge = NowPlayingBridge()              // keep it alive: it holds the player weakly, the handlers hold it weakly
bridge.start(transport: player)
bridge.update(NowPlayingSnapshot(title: "Night Drive", artist: "A minor", genre: "Synthwave", elapsed: 0))
bridge.stop()                                // clears Now Playing and removes the remote-command handlers

// 3. Put the AirPlay button in a toolbar.
AirPlayPicker(tint: .secondary, activeTint: .accentColor)
```

- **Remote commands** mapped: play, pause, play/pause toggle and next track. Play while playing and pause while paused
  return `.success` without calling the player; next track returns `.commandFailed` (and the control is hidden) when
  `supportsNext` is false.
- **Elapsed time** is extrapolated by the system from `elapsed` and the rate, so publish on a change, not every second.
  A snapshot with no `duration` is shown as a live stream, which suits the endless mixer.
- **Threading.** The system calls the handlers on any thread; the bridge hops to the main actor before touching the
  transport.

## Background audio (`UIBackgroundModes`)

iOS suspends an app whose audio session is not active in the background. For music to continue with the screen off
and to keep the lock screen controls, the app needs both:

1. `UIBackgroundModes` containing `audio` in its Info.plist (xcodegen: `info: properties: UIBackgroundModes: [audio]`).
2. An active `.playback` audio session, which `NardukMusicEngine` sets up (`SessionMode.playback`, not `.playAndRecord`
   unless the microphone is in use).

Without the background mode the system pauses the app when it leaves the foreground even though the session is
active, and the Now Playing entry disappears. macOS needs neither.

## AirPlay on macOS

`AVRoutePickerView` lists the outputs, but a custom `AVAudioEngine` plays to the **system output device**, not to
the picked route. On macOS the picker is therefore a shortcut to the system sound output: the engine follows only when
the chosen route becomes the system output. On iOS the session follows the route directly.

## Proof still owed

The wave L1 device test (ten minutes with the screen off on hog and an iPad with HomePods, two output switches, a phone
call, lock screen controls working) is not run by the package gate; the pure info dictionary, the command mapping and
the clear-on-stop behaviour are covered by `Tests/NardukMusicPlaybackTests`.
