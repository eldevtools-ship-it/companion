#!/usr/bin/env python3
"""Synthesise Compagnon's sounds into Compagnon/Resources/sounds/.

Every sound is made here from sine and triangle tones, a little noise and short
envelopes: no recorded samples, nothing borrowed. Same names as the ones the app
plays (SoundEngine.swift). Standard library only:

    python3 scripts/gen-sounds.py
"""
import math
import os
import random
import struct
import wave

RATE = 48000
OUT = os.path.join(os.path.dirname(__file__), "..", "Compagnon", "Resources", "sounds")
random.seed(42)


# ── Notes ─────────────────────────────────────────────────────────────────────

def note(name):
    """'C5' → Hz (A4 = 440)."""
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    semis = names[name[0]]
    rest = name[1:]
    if rest.startswith("#"):
        semis += 1
        rest = rest[1:]
    elif rest.startswith("b"):
        semis -= 1
        rest = rest[1:]
    octave = int(rest)
    return 440.0 * 2 ** ((semis + (octave - 4) * 12) / 12)


# ── Building blocks ───────────────────────────────────────────────────────────

def silence(dur):
    return [0.0] * int(dur * RATE)


def env(i, n, attack, release):
    """Attack in seconds, exponential-ish release over the rest."""
    a = int(attack * RATE)
    if i < a:
        return i / max(1, a)
    t = (i - a) / max(1, n - a)
    return (1 - t) ** release


def tone(freq, dur, wave_kind="sine", attack=0.005, release=2.5, vibrato=0.0,
         vib_rate=6.0, bell=0.0, glide_to=None):
    """One note. `bell` adds a decaying 2.76× partial (marimba-like),
    `glide_to` slides the pitch, `vibrato` is in semitones."""
    n = int(dur * RATE)
    out = []
    phase = 0.0
    phase2 = 0.0
    for i in range(n):
        t = i / n
        f = freq if glide_to is None else freq * (glide_to / freq) ** t
        if vibrato:
            f *= 2 ** (vibrato * math.sin(2 * math.pi * vib_rate * i / RATE) / 12)
        phase += 2 * math.pi * f / RATE
        if wave_kind == "triangle":
            s = 2 / math.pi * math.asin(math.sin(phase))
        else:
            s = math.sin(phase)
        if bell:
            phase2 += 2 * math.pi * f * 2.76 / RATE
            s += bell * math.sin(phase2) * (1 - t) ** 6
        out.append(s * env(i, n, attack, release))
    return out


def noise(dur, attack=0.002, release=3.0, smooth=0.5):
    """Filtered noise burst; higher `smooth` = darker."""
    n = int(dur * RATE)
    out, y = [], 0.0
    for i in range(n):
        y = smooth * y + (1 - smooth) * (random.random() * 2 - 1)
        out.append(y * env(i, n, attack, release))
    return out


def mix(*tracks):
    """Mix (offset_seconds, gain, samples) tuples."""
    length = max(int(off * RATE) + len(s) for off, _, s in tracks)
    out = [0.0] * length
    for off, gain, s in tracks:
        o = int(off * RATE)
        for i, v in enumerate(s):
            out[o + i] += v * gain
    return out


def seq(notes, step, dur, gain=1.0, **kw):
    """Arpeggio: list of note names played `step` seconds apart."""
    return mix(*[(i * step, gain, tone(note(n), dur, **kw)) for i, n in enumerate(notes)])


def room(s, amount=0.18):
    """Two soft early reflections — a bit of air, no long tail."""
    out = s + [0.0] * int(0.12 * RATE)
    for delay, g in ((0.043, amount), (0.087, amount * 0.5)):
        d = int(delay * RATE)
        for i, v in enumerate(s):
            out[i + d] += v * g
    return out


def write(name, s, peak=0.8):
    s = room(s)
    m = max(1e-9, max(abs(v) for v in s))
    s = [v / m * peak for v in s]
    # 3 ms fade-out so nothing clicks
    fade = int(0.003 * RATE)
    for i in range(1, fade + 1):
        s[-i] *= i / fade
    with wave.open(os.path.join(OUT, f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in s))


# ── The sounds ────────────────────────────────────────────────────────────────

SOUNDS = {
    # Tiny UI feedback
    "hover":    lambda: tone(1760, 0.045, attack=0.002, release=4),
    "tick":     lambda: mix((0, 1, tone(2637, 0.03, attack=0.001, release=6)),
                            (0, 0.3, noise(0.012, release=6, smooth=0.2))),
    "blip":     lambda: tone(note("E6"), 0.08, release=3, bell=0.2),
    "pop":      lambda: tone(note("A5"), 0.12, glide_to=note("E6"), attack=0.002, release=4),

    # Island opens and closes
    "peek":     lambda: tone(note("E5"), 0.28, glide_to=note("B5"), release=2.2, bell=0.15),
    "open":     lambda: seq(["C5", "E5", "G5"], 0.055, 0.32, bell=0.3),
    "close":    lambda: seq(["G5", "E5", "C5"], 0.05, 0.28, gain=0.9, bell=0.25),

    # Character
    "greet":    lambda: mix((0, 1, tone(note("G5"), 0.25, vibrato=0.15, bell=0.25)),
                            (0.2, 1, tone(note("E5"), 0.4, vibrato=0.2, vib_rate=5, bell=0.25))),
    "slap":     lambda: mix((0, 1, tone(220, 0.18, glide_to=90, attack=0.001, release=3)),
                            (0, 0.5, noise(0.06, release=4, smooth=0.6))),
    "annoyed":  lambda: mix((0, 1, tone(note("D5"), 0.16, "triangle", release=1.5)),
                            (0.17, 1, tone(note("A4"), 0.26, "triangle", release=2, glide_to=note("G4")))),
    "dizzy":    lambda: tone(note("C5"), 0.9, vibrato=3.5, vib_rate=7, release=1.6, bell=0.1),
    "love":     lambda: seq(["E6", "G6", "B6", "E7"], 0.07, 0.35, gain=0.8, bell=0.4),
    "proud":    lambda: mix((0, 1, tone(note("C5"), 0.16, bell=0.3)),
                            (0.13, 1, tone(note("G5"), 0.16, bell=0.3)),
                            (0.26, 1, tone(note("C6"), 0.5, vibrato=0.12, bell=0.3))),
    "wink":     lambda: mix((0, 1, tone(note("B6"), 0.14, release=4, bell=0.5)),
                            (0.05, 0.5, tone(note("E7"), 0.12, release=4))),
    "yawn":     lambda: tone(note("A4"), 0.7, "triangle", glide_to=note("D4"), attack=0.12,
                             release=1.4, vibrato=0.2, vib_rate=4),
    "sleep":    lambda: mix((0, 1, tone(note("E4"), 0.22, attack=0.03, release=2)),
                            (0.2, 0.8, tone(note("C4"), 0.3, attack=0.03, release=2))),
    "gulp":     lambda: mix((0, 1, tone(520, 0.12, glide_to=260, release=3)),
                            (0.14, 0.9, tone(330, 0.3, glide_to=150, release=2.5))),

    # What Claude is doing
    "work":     lambda: mix((0, 1, tone(note("A5"), 0.08, release=4, bell=0.3)),
                            (0.1, 0.8, tone(note("A5"), 0.12, release=4, bell=0.3))),
    "think":    lambda: tone(note("D5"), 0.42, attack=0.04, release=1.8, vibrato=0.25, vib_rate=3),
    "search":   lambda: mix((0, 1, tone(note("C5"), 0.2, glide_to=note("G5"), release=1)),
                            (0.2, 0.8, tone(note("G5"), 0.22, glide_to=note("D5"), release=2.5))),
    "approval": lambda: mix((0, 1, tone(note("A5"), 0.3, bell=0.5)),
                            (0.16, 1, tone(note("E6"), 0.3, bell=0.5)),
                            (0.4, 0.7, tone(note("A5"), 0.3, bell=0.5))),
    "question": lambda: mix((0, 1, tone(note("C5"), 0.16, bell=0.2)),
                            (0.15, 1, tone(note("F5"), 0.4, glide_to=note("A5"), bell=0.2))),
    "approve":  lambda: seq(["E5", "B5"], 0.09, 0.32, bell=0.35),
    "finish":   lambda: seq(["C5", "E5", "G5", "C6"], 0.09, 0.55, bell=0.4),
    "error":    lambda: mix((0, 1, tone(note("E4"), 0.22, "triangle", release=1.8)),
                            (0.2, 1, tone(note("C4"), 0.4, "triangle", release=2))),
    "rate":     lambda: tone(note("G4"), 0.6, "triangle", glide_to=note("D4"), attack=0.03,
                             release=1.5, vibrato=0.3, vib_rate=5),

    # Files and messages
    "send":     lambda: mix((0, 0.6, noise(0.3, attack=0.12, release=2, smooth=0.3)),
                            (0.05, 1, tone(note("C5"), 0.3, glide_to=note("C6"), release=2))),
    "attach":   lambda: mix((0, 0.7, tone(2093, 0.03, release=6)),
                            (0.07, 0.7, tone(2093, 0.03, release=6)),
                            (0.16, 1, tone(note("G5"), 0.4, bell=0.4))),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, make in SOUNDS.items():
        write(name, make())
    print(f"{len(SOUNDS)} sounds written to {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
