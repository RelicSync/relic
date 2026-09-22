# Windows Voice preview validation

Validated on Windows x64 on 2026-09-21. The built preview is started with
`relic-voice/Try Windows Voice.cmd`. Its profile is separate from
the installed Relic profile. No installer was published.

## Model delivery

All three pinned model files are live under
`https://models.relic.space/relic-voice/v1/` in Relic's R2 bucket. A fresh local
cache downloaded all 715,727,326 bytes through that public hostname. Every file
matched the SHA-256 and byte count in `models.json`. The temporary upload worker
was removed after publication. Model download, interrupted-download resume,
checksum rejection and cancellation are covered by worker tests.

## Human audio

The frozen Windows worker processed 73 real LibriSpeech recordings, totaling
481.035 seconds and 1,150 reference words. There were 71 word errors, or 6.17%
WER. Processing, including punctuation, took 266 ms at the median and 619 ms at
p95 on a Ryzen 7 9800X3D with four CPU threads. Punctuation changed no words.
These measurements exclude first-time download and model loading.

This is one speaker reading clean speech. It verifies the complete packaged
CPU path; it is not a population accuracy estimate. Aggregate results are in
`windows-cpu-2026-09-21.json`. The fixture source is the
[pinned LibriSpeech subset](https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy/tree/5be91486e11a2d616f4ec5db8d3fd248585ac07a).
Audio and reference transcripts are not included in this repository.

## App and Windows checks

- Strict Flutter analysis passed and the release app built with its worker.
- The full Flutter suite passed: 846 tests, with 55 environment-gated skips.
  The guarded Voice persistence and real-audio tests were also run explicitly
  with an isolated profile and human audio. All six Voice tests passed.
- The controller exercised real CPU recognition, history capture, direct vault
  notes, save-before-insert, cancellation, and retry after a disk failure and
  worker shutdown. Recovered saves do not insert into a stale target.
- Voice metadata survived SQLite writes, edits, sync decoding and export.
  Normal edits and rich-text updates retained metadata in size accounting.
- Nine Python tests passed for model delivery and deterministic corrections.
- Native Windows fixtures passed hold, latch, Ctrl mode, Right Alt, Escape,
  ordinary Alt chords, normal Alt menu behavior, exclusions, held modifiers,
  focus preservation, single-attempt Unicode insertion and clipboard checks.
- Edge input, textarea and contenteditable fields received the exact fixture
  text through the actual native insertion path. The clipboard stayed intact.
- Live microphone start, audio delivery and cancellation passed. This hardware
  check did not retain or transcribe microphone audio.
- The actual settings page and native recording popup were visually checked.

## Preview boundaries

Windows x64 with AVX2/FMA/F16C, English, one recording at a time, 60-second limit.
Audio stays in memory. Preferred spelling and explicit corrections are included;
acoustic boosting and LLM rewriting are deferred. Custom hotkeys and vocabulary
import/export remain future work.

Insertion uses Unicode keyboard events. Editors that reject those events need
manual Copy from Relic. The current compatibility set is a native edit control
and the three Edge field types above. Other editors, keyboard layouts, noise
conditions, accents and speakers still need broader acceptance testing.

## Right Alt default update

The default was changed to physical Right Alt at the user's request. Native
checks passed Right Alt hold/latch, explicit Left Ctrl mode, Left Alt passthrough,
and simulated AltGr Ctrl pairs. Flutter analysis and the Voice settings widget
check passed. Labels and the recording popup now name Right Alt.

## Shadow-only popup update

The caption, dark text backing and recording dot were removed. A soft shadow
around the stationary mark pulses every 2.4 seconds during recording and every
0.55 seconds while transcribing. The native host is a transparent 112-DIP square.
The controller hides it immediately when the transcript returns, including on
empty results, cancellation and failure. Detailed status stays in Voice settings.

Real-audio controller checks passed the recording -> processing -> hidden
sequence with no text in the overlay payload. Flutter analysis and the settings
widget check passed. The actual native popup was captured at both pulse strengths
and speeds; focus preservation and window destruction checks passed.

## Dictation spacing update

Insertion adds one leading space when the accessible character immediately
before the caret or replacement selection is not whitespace. The saved transcript
is unchanged. The read-only UI Automation lookup runs on a dedicated MTA thread,
with direct lookup for native edit controls and a 350 ms insertion deadline.
Unsupported or slow providers retain ordinary insertion without an added space.

The final native fixture passed nine spacing cases: empty text, an existing
sentence, space, newline, nonbreaking space, insertion at the beginning, full
selection replacement, word replacement, and a transcript already beginning with
space. It also passed a changed-target check during the asynchronous lookup and
the existing hotkey, overlay, focus, single-attempt and clipboard checks.

The final Edge smoke run passed 21 cases across input, textarea and contenteditable
fields. Each field covered empty text, an existing sentence, space, nonbreaking
space, insertion at the beginning, full selection replacement and word replacement.
Exact text and unchanged clipboard sequence were checked after real native input.
An earlier run dropped characters in one contenteditable insertion; the complete
final run passed. SendInput compatibility still requires broader beta testing.

The Windows release build passed after this update. The isolated preview was
restarted with the rebuilt app and its packaged speech worker.

## Windows Terminal compatibility probe

Windows Terminal 1.24.11911.0 passed three final insertion cases through the real
native insertion path: an empty input line, existing text without a trailing
space, and existing text with a trailing space. All text arrived exactly as
expected, with one added separator only in the second case. Clipboard sequence
numbers stayed unchanged. No Enter key was sent.

The isolated terminal ran a synthetic raw-input receiver, not an interactive
shell. The native test now checks that the exact fixture window owns the
foreground before taking an insertion snapshot, for both browser and terminal
probes. Initial terminal attempts received no text; the final complete run with
that focus guard passed. No production code changed for this probe.

This verifies the installed terminal host and this receiver, not every shell,
full-screen terminal application, selected-text state, or agent prompt. The
user's active terminal session was not used as the test receiver.

## Release latency and PyCharm spacing update

The user's actual failing surface was PyCharm's integrated terminal, not the
standalone Windows Terminal previously tested. UIA text-range lookup is not
sufficient for Java inputs. A conservative continuity fallback now separates
consecutive dictations in the same untouched input. User editing, caret motion,
clicks, scrolling, foreground changes, clipboard changes and a 90-second timeout
invalidate it. It never guesses the contents of an inaccessible field. Native
caret lookup now runs alongside recognition instead of starting after it.

An isolated Swing text area launched using the installed PyCharm Java runtime
passed real native insertion: `First. Second. Third.`. This exercised the missing
UIA text range, consecutive dictation, a manually typed space, caret-edit
invalidation and unchanged clipboard. It did not manipulate the user's active
PyCharm terminal. The existing native checks and all 21 Edge cases also passed.

The worker now recognizes completed segments during recording, splitting only
at a quiet pause after at least five seconds. Every captured sample is retained;
continuous speech is never force-split. Corrections and punctuation see the
joined transcript once, and the existing save-before-insert path is unchanged.
Cancellation discards old results while allowing a new capture to begin; the
single decoder queue serializes inference across sessions.

In a benchmark joining 73 human clips into ten 20-60 second groups with 400 ms
quiet gaps, baseline final processing was 1,060-3,321 ms. Overlapped decoding
reduced the final processing wait to 292-555 ms. Median waits were 2,954 ms and
369 ms, respectively. The replay ran at 10x real time, stressing the queue.
Word errors were 72/1,150 before and 73/1,150 after (6.26% and 6.35%). Formatting
introduced no word mutations. This measures final CPU decoding and formatting,
not total release-to-insertion time. Long speech without a quiet pause can still
take longer. Aggregate details are in `windows-live-decode-2026-09-21.json`.

Twelve Python checks passed, including sample preservation, quiet-speech
protection and cancellation. Five real-audio Flutter persistence/controller
checks passed. A separate immediate cancel/restart protocol check produced only
the replacement session's result. Microphone shutdown alone measured 45 ms on
the default MME input in a brief test that neither retained nor transcribed audio.

The final packaged worker passed a human-audio smoke check. The Windows release
build passed and the isolated preview was restarted. Its bundled worker hash
matched the newly rebuilt package.

## Voice volume, Settings consistency and default setup

The recording mark now follows normalized microphone peak volume using a dB
reference, a -60 dB floor, a 65 ms rise and a 190 ms fall. Growth is limited to
25 percent. Stale levels decay; processing returns to the resting size while
retaining the faster shadow pulse. Reduced-motion preferences disable animation.
No changes were made to captured audio, recognition or worker packaging.

The native fixture passed hold/latch, focus, clipboard, spacing and popup cleanup
checks. Screenshots at 150 percent Windows scaling showed gold silhouette widths
of 62 px in silence, 71 px with quiet input and 77 px with louder input, returning
to 62 px in silence and processing. These were synthetic level inputs to the real
native popup. Separately, the real human-audio worker/controller test verified
positive, finite level events reach the native method channel only while
recording, and retained save-before-insert, cancellation and recovery coverage.

Voice and the main Settings pane now share the existing compact gold toggle and
row components. Voice uses Relic typography, ghost/primary buttons and field
styling. Rendered light/dark screenshots were inspected with actual fonts and
icons. The old Material switch, button and expansion-tile treatment was removed.

First Windows initialization enables Voice automatically when no explicit
preference exists. A stored false remains false. Tests covered a missing file,
an empty preference object, explicit on and explicit off without opening a mic
or downloading models. The real-audio controller test also started enabled by
default. Actual startup prepares models; capture still requires a gesture or
explicit start action.

Strict analysis and the Windows release build passed. The full Flutter suite
passed 847 tests with 56 environment-gated skips. Fifteen targeted default,
theme and shared-keyboard tests passed, and five explicit real-audio/persistence
tests passed in an isolated profile. The native fixture passed separately.
The rollout and remaining platform work are documented in `../RELEASE.md`.

## scipy removed from the worker

scipy was imported for one call, resampling microphone audio to 16 kHz. It is
now a numpy polyphase Kaiser-sinc filter in `resample.py` with the same design
as scipy's default. `test_resample.py` checks length, tone frequency, amplitude,
DC gain, and, when scipy happens to be installed for development, agreement
with `scipy.signal.resample_poly` within float32 precision at 44.1 and 48 kHz.
The bundle shrank from 191 MB to 108 MB.

The rebuilt packaged worker reprocessed the same 73 clips: 71 word errors on
1,150 words (6.17% WER), zero punctuation word mutations. The aggregate is in
`windows-cpu-2026-09-21-numpy-resample.json`; the timing columns in that run
are slower because another worker process ran alongside it. Two clips written
out at 48 kHz produced text identical to their 16 kHz originals through the
frozen worker, which is the path a real microphone takes.
