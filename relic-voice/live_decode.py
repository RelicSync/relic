"""Decode completed phrases during capture; publish only the final transcript.

The offline recognizer stays single-threaded. Splits require a quiet pause and
never discard samples or force a cut through continuous speech. Audio stays in
memory and the same final corrections/formatting pass sees the complete text.
"""
import threading
import time
import numpy as np

FRAME_SECONDS = .02
# A phrase is handed to the recognizer at the first real pause after 5 s. Past
# 20 s a shorter pause is enough, and a phrase never runs past 30 s: someone
# who talks without stopping is cut at the quietest moment of the last 5 s, so
# the recognizer never sees more than it can take and no word is split at a
# loud point.
MIN_PHRASE, SOFT_PHRASE, MAX_PHRASE, CUT_WINDOW = 5, 20, 30, 5


class LiveDecode:
    def __init__(self, engine, pool, rate, settings=None, app=''):
        self.engine, self.pool, self.rate = engine, pool, rate
        self.settings, self.app = settings, app
        self.parts, self.levels, self.jobs = [], [], []
        self.frames = self.quiet = self.seen_blocks = 0
        self.peak_rms = 0.0
        self.canceled = threading.Event()

    def observe(self, blocks):
        # The recorder only appends immutable blocks until stop. Copy the list
        # slice, not the audio; callbacks can append while this snapshot is read.
        fresh = blocks[self.seen_blocks:]
        self.seen_blocks += len(fresh)
        width = max(1, round(self.rate * FRAME_SECONDS))
        for block in fresh:
            for start in range(0, len(block), width):
                frame = block[start:start + width]
                self.parts.append(frame)
                self.frames += len(frame)
                rms = float(np.sqrt(np.mean(frame * frame)))
                self.levels.append(rms)
                self.peak_rms = max(self.peak_rms, rms)
                # Quiet relative to this utterance, capped at -54 dB. The low
                # relative threshold also preserves softly spoken words.
                threshold = min(.002, self.peak_rms * .03)
                quiet = rms <= threshold and float(np.max(np.abs(frame))) <= max(threshold * 4, 1e-6)
                self.quiet = self.quiet + len(frame) if quiet else 0
                if self.frames >= self.rate * MIN_PHRASE and self.quiet >= self.rate * .32:
                    self._submit()
                elif self.frames >= self.rate * SOFT_PHRASE and self.quiet >= self.rate * .12:
                    self._submit()
                elif self.frames >= self.rate * MAX_PHRASE:
                    window = min(len(self.levels), max(1, round(CUT_WINDOW / FRAME_SECONDS)))
                    tail = self.levels[-window:]
                    self._submit(len(self.levels) - window + tail.index(min(tail)) + 1)

    def _submit(self, count=None):
        """Hand the first `count` frames (all by default) to the recognizer."""
        if not self.parts:
            return
        count = len(self.parts) if count is None else count
        audio = np.concatenate(self.parts[:count])
        self.parts, self.levels = self.parts[count:], self.levels[count:]
        self.frames = sum(len(p) for p in self.parts)
        self.quiet = 0
        def decode():
            if self.canceled.is_set():
                return None
            return self.engine.recognize(audio, self.rate)
        self.jobs.append(self.pool.submit(decode))

    def finish(self):
        released = time.perf_counter()
        self._submit()
        jobs = self.jobs[:]
        def complete():
            if self.canceled.is_set():
                return None
            segments = [job.result() for job in jobs]
            if self.canceled.is_set():
                return None
            result = self.engine.finish(segments, self.settings, self.app)
            result['after_stop_ms'] = round((time.perf_counter() - released) * 1000)
            result['segments'] = len(segments)
            return result
        return self.pool.submit(complete)

    def cancel(self):
        self.canceled.set()
        self.parts.clear()
        self.levels.clear()
        # The shared single-worker pool serializes the next session's decode;
        # microphone capture can restart immediately. This barrier lets tests or
        # shutdown wait for the active job; queued canceled jobs do no inference.
        return self.pool.submit(lambda: None)
