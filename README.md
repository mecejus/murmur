# murmur

Hold **fn**, speak, let go: the words are pasted wherever your cursor is.
Speech recognition runs entirely on your Mac with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp). Nothing is sent
anywhere, and no API key is needed.

It's built to run for weeks without slowing down or falling over. See
[Built for long uptime](#built-for-long-uptime).

## Requirements

- A Mac with Apple Silicon (M1 or later), macOS 14 or newer
- The Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- About 1 GB of disk (the default model is 550 MB) and about 800 MB of memory while running

## Install

```bash
git clone https://github.com/mecejus/murmur.git ~/Projects/murmur
cd ~/Projects/murmur
./install.sh
```

The installer builds murmur, signs it with a certificate it creates on this
Mac, downloads the speech model (once, checksum-verified), and starts it as a
launchd service that comes back by itself if it ever exits. Run `./install.sh`
again to update.

## Permissions

macOS asks for two permissions on first start:

| Permission | Why | Where |
|---|---|---|
| **Accessibility** | to see the fn key and to paste (Cmd+V) | System Settings → Privacy & Security → Accessibility |
| **Microphone** | to hear you | System Settings → Privacy & Security → Microphone |

Click **Open System Settings** and switch murmur on. murmur notices the grant
within a few seconds and starts on its own. If an older build of murmur is
already in the Accessibility list, remove it with the minus (−) button first.

Also set **System Settings → Keyboard → Press 🌐 key to → Do Nothing** so fn
doesn't open the emoji picker.

Check where things stand at any time:

```bash
murmur check        # permissions, model, paths
murmur mic-test     # record 4 s from the microphone and transcribe it
```

(`murmur` is installed to `~/.local/bin`. Add that to your `PATH`, or use the full path.)

## Configuration

`~/.config/murmur/config.json` is created on first run. Every key is
optional:

| Key | Default | Meaning |
|---|---|---|
| `model` | `ggml-large-v3-turbo-q5_0.bin` | model file; relative names resolve in `~/Library/Application Support/murmur/models` |
| `language` | `auto` | `auto`, or an ISO-639-1 code such as `en` or `lt` |
| `prompt` | `""` | text that primes spelling and vocabulary (names, jargon) |
| `threads` | `0` | CPU threads for decoding (0 = performance cores) |
| `gpu` | `true` | Metal acceleration |
| `fast_decode` | `false` | shortened audio window for short clips: median about 2× faster, but it sometimes adds invented words and has slow outliers (see TESTING.md) |
| `max_record_seconds` | `300` | longest single dictation |
| `queue_depth` | `2` | finished dictations that may wait while one is transcribed; a press beyond that is refused with the error sound |
| `sounds` | `true` | start / stop / error chimes |
| `log_level` | `info` | `debug`, `info`, `warn`, `error` |
| `log_max_bytes` / `log_keep` | `1048576` / `3` | log rotation |

Restart the service after editing:
`launchctl kickstart -k gui/$(id -u)/com.murmur`

### Other models

Any ggml Whisper model works. Download one from
[huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp)
into the models folder and set `model`. On an M1, `large-v3-turbo` takes
about 2 s per short dictation (TESTING.md). Smaller models such as `small` or
`base` are much faster and less accurate, especially outside English.

## Running as a service

| | |
|---|---|
| status | `launchctl print gui/$(id -u)/com.murmur \| grep -E 'state\|pid'` |
| restart | `launchctl kickstart -k gui/$(id -u)/com.murmur` |
| stop until next login | `launchctl bootout gui/$(id -u)/com.murmur` |
| start again | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.murmur.plist` |
| log | `~/Library/Logs/murmur/murmur.log` (JSON lines, rotated at 1 MB, 3 kept) |

The log records each dictation's length, latency and outcome, never the
words. Run `murmur` in a terminal to see the text as it's heard.

## Commands

```
murmur                 run the service (what launchd starts)
murmur transcribe a.wav b.wav   transcribe files through the full pipeline
murmur bench *.wav     end-of-speech → text latency (real-time playback)
murmur soak            long-running stability run with memory/CPU/threads sampling
murmur mic-test        microphone → model check
murmur check           permissions, model, paths
murmur config          effective configuration
```

## Uninstall

```bash
./uninstall.sh            # keeps config and models
./uninstall.sh --purge    # removes them too
```

## Built for long uptime

Dictation daemons tend to degrade over days in a few predictable ways. Here's
what murmur does about each:

| Failure mode | What murmur does |
|---|---|
| Waiting on a network or a stuck request | Transcription is local, and every model call has a deadline (whisper.cpp's abort callback) |
| One slow dictation holding up the ones behind it | A single worker with fixed-size buffers. A press when all buffers are busy is refused with the error sound instead of queueing without limit |
| Going deaf after unplugging a mic, switching AirPods or sleep | Input is rebuilt on device change, disconnect, sleep/wake and failed starts. A device that goes silent is caught by its callback count |
| A hung audio driver freezing the hotkey | Every CoreAudio call has a timeout and runs off the hotkey path. A hung unit is disarmed at once and released when the call returns |
| Glitches or pauses on the real-time audio thread | A C callback that only copies into a lock-free ring. No allocation, lock or language runtime on that thread |
| Background CPU and wakeups while idle | Nothing runs between dictations: no output stream, no polling |
| Crash or restart loops on startup errors | A missing model, denied microphone and similar problems are logged and retried. Exiting is a last resort, and launchd restarts the process |
| Logs filling the disk | Logs rotate at a fixed size. Dictated text is never logged |

### Why Swift

- **Predictable latency.** Swift uses reference counting, not a tracing
  garbage collector, so the process never pauses to collect. The one
  real-time path is plain C anyway.
- **Native APIs without a binding layer.** CoreAudio (AUHAL, device
  listeners), CGEventTap, Accessibility, NSPasteboard and IOKit power events
  are all called directly. The stability fixes above depend on these APIs,
  and every binding layer is another place for bugs.
- **whisper.cpp links straight in.** Its C API imports into Swift, and SwiftPM
  compiles the vendored C/C++/Objective-C sources into the same binary.
- **Small footprint.** One 8 MB binary with no dylibs. The Swift runtime ships
  with macOS. It builds with the Command Line Tools alone.

Rust would give the same latency guarantees. On macOS it would also mean
hand-maintained FFI bindings for each framework above.

### Design

```
fn key ─▶ event tap thread ──press/release──▶ state queue
                                               │ start/stop (with timeouts)
CoreAudio IO thread ─▶ C callback ─▶ lock-free ring (4 s)
                                               │ drain every 20 ms
                                state queue: resample → fixed buffer (pool of queue_depth+2)
                                               │ on release
                                worker thread: sanitize → trim silence → whisper (deadline)
                                               │ in order
                                output queue: paste (pasteboard saved and restored)
```

Every queue and buffer is fixed-size:
- The ring drops samples and counts them if the drain falls 4 s behind.
- The buffer pool refuses new presses when full.
- Recordings stop at `max_record_seconds`.
- Log records beyond 2048 pending are dropped and counted.

## Development

```bash
scripts/swift.sh build -c release
scripts/swift.sh test          # integration tests need ggml-tiny.bin in the models folder
                               # (if the test build says "plugin for module 'TestingMacros' not found",
                               #  remove .build/out/*/Debug: stale state from a release build)
bench/make_corpus.sh           # synthetic speech corpus for bench/soak
```

`scripts/swift.sh` is plain `swift` plus a workaround for a broken Command
Line Tools install (a stale `PackageDescription` interface that makes every
`Package.swift` fail to link). whisper.cpp is vendored by
`scripts/vendor_whisper.py`, which also applies two small fixes to it (see
the script).

## License

MIT. whisper.cpp is MIT (`Vendor/whisper/LICENSE`).
