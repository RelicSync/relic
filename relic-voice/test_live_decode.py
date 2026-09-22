import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from live_decode import LiveDecode


class RecordingEngine:
    def __init__(self): self.audio = []
    def recognize(self, audio, rate):
        self.audio.append(audio.copy())
        return {'raw': 'phrase', 'duration_ms': round(len(audio) * 1000 / rate), 'recognition_ms': 0}
    def finish(self, segments, settings, app):
        return {'raw': ' '.join(s['raw'] for s in segments), 'duration_ms': sum(s['duration_ms'] for s in segments)}


class LiveDecodeTest(unittest.TestCase):
    def test_pause_decodes_early_and_preserves_every_sample(self):
        engine = RecordingEngine()
        rate = 16000
        audio = np.concatenate([np.full(rate * 5, .1, np.float32), np.zeros(rate // 2, np.float32), np.full(rate * 2, .05, np.float32)])
        with ThreadPoolExecutor(max_workers=1) as pool:
            live = LiveDecode(engine, pool, rate)
            blocks = [audio[:rate * 6]]
            live.observe(blocks)
            self.assertEqual(len(live.jobs), 1)
            live.jobs[0].result(timeout=2)
            self.assertEqual(len(engine.audio), 1)
            blocks.append(audio[rate * 6:])
            live.observe(blocks)
            result = live.finish().result(timeout=2)
        np.testing.assert_array_equal(np.concatenate(engine.audio), audio)
        self.assertEqual(result['duration_ms'], 7500)
        self.assertEqual(result['segments'], 2)

    def test_continuous_quiet_speech_is_not_force_split(self):
        engine = RecordingEngine()
        audio = np.full(16000 * 12, .0004, np.float32)
        with ThreadPoolExecutor(max_workers=1) as pool:
            live = LiveDecode(engine, pool, 16000)
            live.observe([audio])
            self.assertEqual(live.jobs, [])
            result = live.finish().result(timeout=2)
        self.assertEqual(result['segments'], 1)
        np.testing.assert_array_equal(engine.audio[0], audio)

    def test_cancel_does_not_publish_or_decode_queued_audio(self):
        engine = RecordingEngine()
        gate = threading.Event()
        with ThreadPoolExecutor(max_workers=1) as pool:
            pool.submit(gate.wait)
            live = LiveDecode(engine, pool, 16000)
            live.observe([np.full(16000, .1, np.float32)])
            finished = live.finish()
            barrier = live.cancel()
            gate.set()
            self.assertIsNone(finished.result(timeout=2))
            barrier.result(timeout=2)
        self.assertEqual(engine.audio, [])


if __name__ == '__main__': unittest.main()
