"""Regenerate the project's original PCM effects. Standard library only."""
import math
from pathlib import Path
import struct
import wave

destination = Path(__file__).resolve().parents[1] / "assets" / "audio"
sample_rate = 22050


def write_effect(name, duration, partials, decay):
    samples = bytearray()
    for index in range(int(sample_rate * duration)):
        time = index / sample_rate
        attack = min(1.0, time / 0.003)
        tail = min(1.0, (duration - time) / 0.015)
        value = sum(amplitude * math.sin(2 * math.pi * frequency * time)
                    for frequency, amplitude in partials)
        value *= attack * tail * math.exp(-decay * time) * 0.6
        samples.extend(struct.pack("<h", round(max(-1, min(1, value)) * 32767)))
    with wave.open(str(destination / (name + ".wav")), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(samples)


if __name__ == "__main__":
    destination.mkdir(parents=True, exist_ok=True)
    write_effect("peg", 0.10, [(1568, 0.6), (2372, 0.22), (3310, 0.08)], 37)
    write_effect("launch", 0.13, [(392, 0.55), (784, 0.3), (1176, 0.08)], 23)
    write_effect("land", 0.32, [(784, 0.45), (988, 0.25), (1175, 0.2)], 12)
    print("Generated 3 original mono PCM effects in assets/audio")
