import unittest
import numpy as np
from resample import resample


def tone(rate, hz=440.0, seconds=2.0, amplitude=0.3):
    t = np.arange(int(rate * seconds)) / rate
    return (amplitude * np.sin(2 * np.pi * hz * t)).astype(np.float32)


class ResampleTest(unittest.TestCase):
    def test_identity_at_target_rate(self):
        x = tone(16000)
        y = resample(x, 16000)
        self.assertEqual(y.dtype, np.float32)
        np.testing.assert_allclose(y, x, atol=1e-6)

    def test_length_and_tone_preserved_from_common_mic_rates(self):
        for rate in (44100, 48000, 96000):
            x = tone(rate)
            y = resample(x, rate)
            self.assertEqual(len(y), int(np.ceil(len(x) * 16000 / rate)))
            spectrum = np.abs(np.fft.rfft(y[1600:-1600]))
            peak_hz = np.fft.rfftfreq(len(y) - 3200, 1 / 16000)[int(np.argmax(spectrum))]
            self.assertAlmostEqual(peak_hz, 440.0, delta=2.0, msg=str(rate))
            self.assertAlmostEqual(float(np.max(np.abs(y[1600:-1600]))), 0.3, delta=0.003, msg=str(rate))

    def test_dc_gain_is_unity(self):
        y = resample(np.full(48000, 0.5, dtype=np.float32), 48000)
        np.testing.assert_allclose(y[800:-800], 0.5, atol=1e-3)

    def test_rejects_stereo(self):
        with self.assertRaises(ValueError):
            resample(np.zeros((100, 2)), 48000)

    def test_matches_scipy_when_available(self):
        try:
            from scipy.signal import resample_poly
        except ImportError:
            self.skipTest('scipy is a dev-only comparison, not a dependency')
        rng = np.random.default_rng(0)
        for rate in (44100, 48000):
            x = (tone(rate) + 0.02 * rng.standard_normal(rate * 2)).astype(np.float32)
            expected = resample_poly(x, 160, rate // 100)
            np.testing.assert_allclose(resample(x, rate), expected, atol=1e-6)
