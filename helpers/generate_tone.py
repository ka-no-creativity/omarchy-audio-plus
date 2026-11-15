#!/usr/bin/env python3
"""Generate a deterministic -24 dBFS stereo sine with raised-cosine fades."""
import math
from pathlib import Path
import struct
import wave


def generate(path):
    rate, duration, fade, amplitude = 48000, 0.4, 0.06, 10 ** (-24 / 20)
    count = round(rate * duration)
    with wave.open(str(path), 'wb') as wav:
        wav.setparams((2, 2, rate, count, 'NONE', 'not compressed'))
        for i in range(count):
            edge = min(i, count - 1 - i) / (rate * fade)
            envelope = 0.5 - 0.5 * math.cos(math.pi * min(1, edge))
            sample = round(32767 * amplitude * envelope * math.sin(2 * math.pi * 440 * i / rate))
            wav.writeframesraw(struct.pack('<hh', sample, sample))


if __name__ == '__main__':
    generate(Path(__file__).resolve().parent.parent / 'assets/test-tone.wav')
