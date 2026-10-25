# Testing

All numbers below were measured on 2026-10-25. The machine was a MacBook
with an Apple M1 and 8 GB of RAM, running macOS 26.6.2. murmur used
`ggml-large-v3-turbo-q5_0.bin` on Metal with language `auto`. Raw outputs land in `bench/out/` (not committed).

## Test suite

```bash
scripts/swift.sh test
```

**60 tests in 12 suites, all passing** (about 15 s). The integration tests use
`ggml-tiny.bin` and speech generated with macOS `say`, so no microphone is
needed.

| Suite | What it covers |
|---|---|
| RingTests | wraparound, overflow drops newest and counts them, power-of-two sizing, a 2M-sample producer/consumer stress run (order preserved, nothing lost) |
| ResamplerTests | 44.1/48/24/96 kHz → 16 kHz (length and level), 16 kHz passthrough, reuse across sessions |
| SpeechTests | NaN/Inf/out-of-range repair, silence and low noise rejected, speech found and padded, a lone click ignored |
| WAVTests | PCM16 round trip, garbage and truncated headers throw, data chunk overrunning the file tolerated, stereo float downmix |
| ConfigTests | defaults for missing keys, unsafe values clamped, first run writes defaults, malformed JSON, model path resolution |
| LogTests | rotation keeps N files and stays bounded, one JSON object per line, level filtering |
| FnTrackerTests | fn edges, other keys ignored, resync releases a key-up lost while the tap was disabled |
| TextTests | WER, non-speech annotation stripping, decoder-loop detection |
| BufferTests | fixed-capacity buffer, fixed-size pool, process stats |
| PasteTests | against a private pasteboard: an app that reads 600 ms late still pastes the dictation (not the old clipboard), the clipboard is restored right after the read, restored after a timeout when nothing reads, a copy made during the paste is kept, a failed keystroke restores and errors |
| PipelineTests | the real pipeline with a scriptable fake model (see faults below) |
| IntegrationTests | the real pipeline with whisper.cpp (see below) |

### Integration test: WAV through the full pipeline

`IntegrationTests.wavThroughFullPipelineInRealTime` plays a spoken sentence
into the ring at real-time speed from its own thread, as the microphone
callback would. From there it goes through the real drain, resampler, silence
trim, whisper.cpp and the ordered output. It asserts WER < 0.25 and latency
< 10 s. `deviceRateAudioIsResampled` does the same from 48 kHz.

### Fault tests

| Fault | Test(s) | Result |
|---|---|---|
| Device loss mid-recording | `deviceLossMidRecordingKeepsWhatWasSaidAndRecovers` (fake model), `deviceLossWithRealModel` | The audio up to the loss is transcribed. The next dictation works normally. No crash. |
| Corrupt audio chunk (NaN, ±Inf, 1e9) | `corruptChunkIsRepairedBeforeTheModel`, `corruptChunkWithRealModel` | Samples repaired before the model. The model never sees a non-finite value, and the sentence still comes through (WER < 0.4). |
| Model error | `repeatedModelErrorsTriggerReloadAndRecovery`, `modelErrorsRecoverWithRealModel` | Each failure gets the error sound and a log line. After 2 in a row the model is reloaded, and the next dictation succeeds. |
| Inference hang | `modelTimeoutIsAFailureNotAHang`, `inferenceDeadlineAbortsAndEngineSurvives` | A real whisper.cpp call is aborted via its abort callback when the deadline passes. The same engine transcribes correctly afterwards. |
| Missing / corrupt model file | `missingModelIsRetriedWithoutCrashing`, `missingModelFileIsAnErrorNotACrash`, `corruptModelFileIsAnErrorNotACrash` | An error, not a crash. Presses are refused with the error sound until the model loads, and loading is retried. |
| Audio start failure | `failedStartIsReportedAndTheNextPressWorks` | Error sound. The next press works. |
| Output (paste) failure | `outputFailureDoesNotStopLaterDictations` | Logged. Later dictations are unaffected. |
| Backlog | `backlogRefusesNewPressInsteadOfGrowing` | With every buffer busy, a press is refused (error sound). Capacity returns once the backlog drains. |
| Over-long recording | `recordingIsCappedAtMaxDuration` | Ends at `max_record_seconds` and is transcribed. |

## Latency: end of speech → text output

`murmur bench --runs 3 bench/audio/*.wav`. Each clip is played
into the pipeline in real time, as a person speaking. The clock starts at
key release (end of the clip) and stops when the text is handed to the
output, which is the moment Cmd+V would be posted.

Corpus: 11 synthetic clips from `bench/make_corpus.sh` (0.5–36 s; English,
German, Lithuanian).

| | n | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| bench (3 runs per clip) | 33 | **2169 ms** | **2462 ms** | 5280 ms | 5280 ms |
| 1 h soak (corpus looped) | 313 | 2169 ms | 2485 ms | 5154 ms | 5165 ms |

Per clip (median of 3):

| clip | audio | latency |
|---|---|---|
| tiny | 0.5 s | 2021 ms |
| yes | 1.9 s | 2045 ms |
| short | 4.1 s | 2095 ms |
| german | 5.7 s | 2169 ms |
| code | 6.0 s | 2144 ms |
| lithuanian | 6.1 s | 2214 ms |
| note | 7.3 s | 2190 ms |
| email | 7.4 s | 2201 ms |
| numbers | 7.4 s | 2160 ms |
| paragraph | 15.7 s | 2437 ms |
| long | 36.2 s | 5136 ms |

**What this means:**
- **Latency is flat at about 2.1 s for anything under 30 s.** Whisper always
  encodes a full 30 s window, and on an M1 GPU that costs about 1.9 s for
  large-v3-turbo, close to the hardware's limit. Clips over 30 s need a
  second window, hence `long`.
- **It's predictable.** Run-to-run spread is ±20 ms, the worst case is set by
  audio length alone, and nothing depends on a network.

### Speed-ups tried

| change | effect |
|---|---|
| Auto language detection re-encoded the first window (whisper.cpp) | **Patched:** auto-language dictations went from 4.05 s to 2.15 s, with identical text |
| Detection used the previous call's `audio_ctx` (whisper.cpp) | **Patched:** wrong-language garbage after any shortened call |
| `fast_decode` (shortened window, `audio_ctx` = clip + 384 frames) | p50 1093 ms, but p99 18.3 s (decoder loops and full-window fallback), mean WER 0.127 vs 0.097, and one clip gained an invented sentence. **Off by default.** |
| Smaller padding (64–256 frames) | Faster still, but frequent garbage ("It's the", repeated sentences). Rejected. |

Accuracy, mean WER over the corpus with the default settings: **0.097**. Most
of that is formatting rather than mistakes ("March 14th at 3.30" for "March
fourteenth at three thirty", "30-second"). Lithuanian has one real word
boundary error.

## Soak test: 1 hour

```bash
murmur soak --minutes 60 --speed 1 --corpus bench/audio --csv bench/out/soak.csv
```

The 11-clip corpus was looped through the real pipeline at real-time
playback for 60 minutes. That's 313 dictations, back to back, far heavier
than real use. Resources were sampled every 30 s (88 samples).

| | start | min | max | end |
|---|---|---|---|---|
| memory footprint | 733 MB | 702 MB | 764 MB | **706 MB** |
| resident (RSS) | 712 MB | 630 MB | 712 MB | 662 MB |
| threads | 31 (loading) | 7 | 31 | **8** |

Footprint by quarter of the hour (mean): 760 → 708 → 706 → 706 MB.

**Memory plateaued:** it settled at 706 MB after about 20 minutes and stayed
there, with no upward trend. Threads stayed at 7–8 after model load.
Failures: **0 of 313**. CPU averaged 2.3% of one core; inference itself runs
on the GPU. Latency in the last quarter matched the first (p50 2169 ms
overall).

The ~700 MB is the resident model plus compute buffers, allocated once at
startup and reused for every dictation.

## Not covered by these tests

- **Real microphone, real fn key and real paste.** Not exercised in this
  run: they need murmur installed and granted Accessibility and Microphone
  access. The code paths below the hardware (ring, drain, resampler, model,
  output ordering) are the ones tested above. `murmur mic-test` checks the
  real microphone path in one command.
- **Physical device unplug, sleep/wake and revoked permissions.** Device
  loss is simulated at the source boundary (the same event the CoreAudio
  listeners raise). The CoreAudio listeners, the IOKit sleep handler and the
  Accessibility-revoked handler are written but were not triggered on
  hardware.
- **Multi-day uptime.** The soak ran 1 hour.
