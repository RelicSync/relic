"""CPU-only recognition through the pinned transcribe.cpp C ABI."""
from pathlib import Path
import os
import sys
import time
import numpy as np
from resample import resample
from model_store import MANIFEST
from corrections import finish_text
from punctuation import Punctuator


class Engine:
    def __init__(self, folder, threads=4):
        root = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
        native = root / 'native'
        if not native.exists():
            native = root / '.build' / 'bin' / 'Release'
        os.environ['TRANSCRIBE_LIBRARY'] = str(native / 'transcribe.dll')
        if not getattr(sys, 'frozen', False):
            sys.path.insert(0, str(root / '_vendor' / 'transcribe.cpp' / 'bindings' / 'python' / 'src'))
        import transcribe_cpp
        self.model = transcribe_cpp.Model(Path(folder) / MANIFEST['files'][0]['name'], backend='cpu')
        self.session = self.model.session(n_threads=threads)
        try:
            self.punctuator = Punctuator(Path(folder), threads)
        except Exception:
            self.close()
            raise

    def recognize(self, audio, rate):
        start = time.perf_counter()
        pcm = np.asarray(audio, dtype=np.float32)
        if pcm.ndim == 2:
            pcm = pcm.mean(axis=1)
        if pcm.ndim != 1 or not np.isfinite(pcm).all() or rate <= 0 or len(pcm) > 60.1 * rate:
            raise ValueError('Invalid or oversized audio')
        if rate != 16000:
            pcm = resample(pcm, rate, 16000)
        pcm = np.ascontiguousarray(pcm, dtype=np.float32)
        duration = len(pcm) / 16000
        # Conservative silence guard; no claim of a general noise classifier.
        speech = len(pcm) >= 1600 and float(np.max(np.abs(pcm))) > 0.002 and float(np.sqrt(np.mean(pcm**2))) > 0.0003
        raw = self.session.run(pcm, timestamps='none').text.strip() if speech else ''
        return dict(raw=raw, duration_ms=round(duration * 1000),
                    recognition_ms=round((time.perf_counter() - start) * 1000))

    def finish(self, segments, settings=None, app=''):
        start = time.perf_counter()
        raw = ' '.join(segment['raw'] for segment in segments if segment['raw'])
        text, applied, warning = finish_text(raw, settings or {}, self.punctuator, app)
        formatting_ms = round((time.perf_counter() - start) * 1000)
        recognition_ms = sum(segment['recognition_ms'] for segment in segments)
        return dict(text=text, raw=raw,
                    duration_ms=sum(segment['duration_ms'] for segment in segments),
                    processing_ms=recognition_ms + formatting_ms,
                    recognition_ms=recognition_ms, formatting_ms=formatting_ms,
                    model=MANIFEST['version'], applied_rules=applied, warning=warning)

    def transcribe(self, audio, rate, settings=None, app=''):
        return self.finish([self.recognize(audio, rate)], settings, app)

    def close(self):
        self.session.close()
        self.model.close()
