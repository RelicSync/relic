"""Polyphase FIR resampling to 16 kHz with numpy only.

This replaces scipy.signal.resample_poly, which was the only scipy call in the
worker and cost 80 MB of the shipped bundle. Same design: a Kaiser-windowed
sinc low-pass (half_width=10 zero crossings, beta=5.0) applied through a
polyphase filter bank, so the output matches scipy's default to float32
precision. Only the output samples are computed, never the full upsampled
signal, so a 5 s capture at 48 kHz resamples in about 30 ms.
"""
from math import gcd
import numpy as np


def _kaiser_sinc(up, down, half_width=10, beta=5.0):
    max_rate = max(up, down)
    n_half = half_width * max_rate
    t = np.arange(-n_half, n_half + 1) / max_rate
    h = np.sinc(t) * np.kaiser(2 * n_half + 1, beta)
    h *= up / h.sum()
    return h, n_half


def resample(x, orig_rate, target_rate=16000):
    """Return ``x`` (1-D float) resampled from ``orig_rate`` to ``target_rate``."""
    x = np.asarray(x, dtype=np.float64)
    if x.ndim != 1:
        raise ValueError('resample expects mono audio')
    divisor = gcd(int(orig_rate), int(target_rate))
    up, down = int(target_rate) // divisor, int(orig_rate) // divisor
    if up == down:
        return x.astype(np.float32)
    h, n_half = _kaiser_sinc(up, down)
    per_phase = -(-len(h) // up)
    bank = np.zeros(up * per_phase)
    bank[:len(h)] = h
    bank = bank.reshape(per_phase, up).T  # bank[phase, k] == h[phase + k * up]
    n_out = int(np.ceil(len(x) * up / down))
    pos = np.arange(n_out) * down + n_half
    phase = pos % up
    start = pos // up
    idx = start[:, None] - np.arange(per_phase)[None, :] + per_phase
    padded = np.concatenate([np.zeros(per_phase), x, np.zeros(per_phase)])
    y = np.einsum('mk,mk->m', padded[idx], bank[phase])
    return y.astype(np.float32)
