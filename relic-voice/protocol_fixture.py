"""Test adapter: a consented human recording replaces only the mic boundary.

Not included in the frozen worker. The real protocol, CPU engine, formatting,
and result path run unchanged. Hardware capture is tested separately.
"""
import argparse
import numpy as np
import soundfile as sf
import worker

parser = argparse.ArgumentParser()
parser.add_argument('--models', required=True)
parser.add_argument('--audio', required=True)
args = parser.parse_args()
audio, rate = sf.read(args.audio, dtype='float32')


class FixtureRecorder:
    def __init__(self):
        self.blocks = []
        self.frames = 0
        self.rate = rate
        self.level = 0
        self.stream = None
        self.limit_reached = False
    def start(self, device=None):
        self.blocks = [audio.copy()]
        self.frames = len(audio)
        self.level = float(np.max(np.abs(audio)))
    def stop(self):
        result = np.concatenate(self.blocks) if self.blocks else np.array([], dtype=np.float32)
        return result, rate, []


worker.Recorder = FixtureRecorder
worker.serve(args.models)
