"""Decode completed phrases during capture; publish only the final transcript.

The offline recognizer stays single-threaded. Splits require a quiet pause and
never discard samples or force a cut through continuous speech. Audio stays in
memory and the same final corrections/formatting pass sees the complete text.
"""
import threading
import time
import numpy as np


class LiveDecode:
    def __init__(self, engine, pool, rate, settings=None, app=''):
        self.engine, self.pool, self.rate = engine, pool, rate
        self.settings, self.app = settings, app
        self.parts, self.jobs = [], []
        self.frames = self.quiet = self.seen_blocks = 0
        self.peak_rms = 0.0
        self.canceled = threading.Event()

    def observe(self, blocks):
        # The recorder only appends immutable blocks until stop. Copy the list
        # slice, not the audio; callbacks can append while this snapshot is read.
        fresh = blocks[self.seen_blocks:]
        self.seen_blocks += len(fresh)
        width = max(1, round(self.rate * .02))
        for block in fresh:
            for start in range(0, len(block), width):
                frame = block[start:start + width]
                self.parts.append(frame)
                self.frames += len(frame)
                rms = float(np.sqrt(np.mean(frame * frame)))
                self.peak_rms = max(self.peak_rms, rms)
                # Quiet relative to this utterance, capped at -54 dB. The low
                # relative threshold also preserves softly spoken words.
                threshold = min(.002, self.peak_rms * .03)
                quiet = rms <= threshold and float(np.max(np.abs(frame))) <= max(threshold * 4, 1e-6)
                self.quiet = self.quiet + len(frame) if quiet else 0
                if self.frames >= self.rate * 5 and self.quiet >= self.rate * .32:
                    self._submit()

    def _submit(self):
        if not self.parts:
            return
        audio = np.concatenate(self.parts)
        self.parts = []
        self.frames = self.quiet = 0
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
        # The shared single-worker pool serializes the next session's decode;
        # microphone capture can restart immediately. This barrier lets tests or
        # shutdown wait for the active job; queued canceled jobs do no inference.
        return self.pool.submit(lambda: None)
