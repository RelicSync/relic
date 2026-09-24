"""Bounded microphone capture with device-native sample rate."""
import numpy as np
import sounddevice as sd
# A voice note can run ten minutes. Audio is decoded in phrases while it is
# recorded and dropped once handed over, so memory stays at about one phrase.
MAX_SECONDS = 600


def input_devices():
    result = [(None, "System default microphone")]
    hosts = sd.query_hostapis()
    for index, device in enumerate(sd.query_devices()):
        if device["max_input_channels"]:
            result.append((index, f"{device['name']} ({hosts[device['hostapi']]['name']})"))
    return result


class Recorder:
    def __init__(self):
        self.stream = None
        self.blocks = []
        self.frames = 0
        self.level = 0.0
        self.warnings = set()
        self.rate = 16000
        self.limit_reached = False

    def start(self, device=None):
        self.blocks, self.frames, self.warnings = [], 0, set()
        self.level, self.limit_reached = 0.0, False
        info = sd.query_devices(device, "input")
        self.rate = int(info["default_samplerate"])

        def callback(data, frames, timing, status):
            if status:
                self.warnings.add(str(status))
            remaining = MAX_SECONDS * self.rate - self.frames
            block = data[:max(0, remaining), 0].copy()
            if block.size:
                self.blocks.append(block)
                self.frames += len(block)
                self.level = float(np.max(np.abs(block)))
            if self.frames >= MAX_SECONDS * self.rate:
                self.limit_reached = True
                raise sd.CallbackStop()

        stream = sd.InputStream(device=device, channels=1, samplerate=self.rate,
                                dtype="float32", callback=callback)
        try:
            stream.start()
        except Exception:
            stream.close()
            raise
        self.stream = stream

    def stop(self):
        if self.stream is not None:
            try:
                self.stream.stop()
            finally:
                self.stream.close()
                self.stream = None
        return (np.concatenate(self.blocks) if self.blocks else np.array([], dtype=np.float32),
                self.rate, sorted(self.warnings))
