#!/usr/bin/env python3
"""Synthesises Lumora's own call and notification tones (no third-party audio).

Writes 16-bit mono PCM WAV files into app/assets/sounds/:

  ringtone.wav  incoming call, ~2.6 s, loops seamlessly (two soft chime arpeggios)
  ringback.wav  outgoing call "it is ringing" tone, 4 s loop (1.2 s tone + pause)
  message.wav   short two-note ping for a new message
  mention.wav   a brighter, slightly louder three-note ping for an @mention
  reminder.wav  reminder alarm, ~2.4 s: three quick double-chimes

mention.wav and reminder.wav are also copied to the Android app as raw
resources (res/raw/lumora_*.wav): the sounds of the "Mentions" and
"Reminders" notification channels.

Plain PCM WAV on purpose: every backend plays it (just_audio on iOS/macOS,
Android MediaPlayer, winmm PlaySound on Windows, paplay/pw-play/aplay on Linux).

Usage: python3 branding/tools/make_sounds.py   (needs numpy)
"""

import os
import shutil
import wave

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "app", "assets", "sounds")


def note(freq, dur, sr, decay, partials=((1, 1.0), (2, 0.28), (3, 0.07), (4.2, 0.03)), attack=0.006):
    """A soft bell/marimba-like note: a few sine partials, fast attack, exp decay.

    Higher partials die out faster, which keeps the tone round instead of shrill.
    """
    t = np.arange(int(dur * sr)) / sr
    out = np.zeros_like(t)
    for mult, amp in partials:
        f = freq * mult
        if f >= sr / 2:
            continue
        out += amp * np.sin(2 * np.pi * f * t) * np.exp(-t / (decay / mult ** 0.6))
    env = np.minimum(1.0, t / attack)
    return out * env


def place(buf, sig, at, sr):
    i = int(at * sr)
    n = min(len(sig), len(buf) - i)
    buf[i:i + n] += sig[:n]


def fade_tail(buf, sr, secs=0.05):
    n = int(secs * sr)
    buf[-n:] *= np.linspace(1, 0, n)
    return buf


def normalise(buf, peak_db):
    peak = np.max(np.abs(buf)) or 1.0
    return buf * (10 ** (peak_db / 20) / peak)


def write(name, buf, sr):
    os.makedirs(OUT, exist_ok=True)
    pcm = np.clip(np.round(buf * 32767), -32768, 32767).astype("<i2")
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())
    print(f"{path}: {os.path.getsize(path) / 1024:.1f} KB, {len(buf) / sr:.2f} s")


def ringtone():
    sr = 22050
    buf = np.zeros(int(2.6 * sr))
    # C major, rising then answered a third higher; ends quiet so the loop is seamless
    c5, e5, g5, c6, e6 = 523.25, 659.25, 783.99, 1046.5, 1318.5
    for i, f in enumerate((c5, e5, g5, c6)):
        place(buf, note(f, 0.9, sr, 0.32), 0.0 + i * 0.13, sr)
    for i, f in enumerate((e5, g5, c6, e6)):
        place(buf, note(f, 1.0, sr, 0.36), 1.05 + i * 0.13, sr)
    buf = np.tanh(1.2 * buf)  # gentle soft-clip where notes overlap
    return fade_tail(normalise(buf, -2.0), sr)


def ringback():
    sr = 16000
    buf = np.zeros(int(4.0 * sr))
    dur = 1.2
    t = np.arange(int(dur * sr)) / sr
    # two soft sines a fifth apart, slow fades: a calm "tuuu", not a harsh telephone beep
    tone = 0.6 * np.sin(2 * np.pi * 440 * t) + 0.4 * np.sin(2 * np.pi * 659.25 * t)
    tone *= 1 + 0.08 * np.sin(2 * np.pi * 5 * t)  # slight warmth (tremolo)
    fade = int(0.09 * sr)
    env = np.ones_like(t)
    env[:fade] = np.sin(np.linspace(0, np.pi / 2, fade)) ** 2
    env[-fade:] = np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
    place(buf, tone * env, 0.0, sr)
    return normalise(buf, -9.0)


def message():
    sr = 22050
    buf = np.zeros(int(0.55 * sr))
    place(buf, note(880.0, 0.5, sr, 0.16), 0.0, sr)  # A5
    place(buf, note(1318.5, 0.45, sr, 0.20), 0.085, sr)  # E6
    buf = np.tanh(1.1 * buf)
    return fade_tail(normalise(buf, -4.0), sr, 0.04)


def mention():
    sr = 22050
    buf = np.zeros(int(0.7 * sr))
    # E6 - G#6 - B6 rising: brighter than the message ping, so an @mention stands out
    for i, f in enumerate((1318.5, 1661.2, 1975.5)):
        place(buf, note(f, 0.5, sr, 0.17), i * 0.075, sr)
    buf = np.tanh(1.2 * buf)
    return fade_tail(normalise(buf, -1.5), sr, 0.04)


def reminder():
    sr = 22050
    buf = np.zeros(int(2.4 * sr))
    # alarm-like but soft: three "ding-dong" pairs (A5 / E6), clearly not a call or a message
    for k in range(3):
        t0 = k * 0.75
        place(buf, note(1318.5, 0.5, sr, 0.14), t0, sr)
        place(buf, note(880.0, 0.6, sr, 0.18), t0 + 0.16, sr)
    buf = np.tanh(1.3 * buf)
    return fade_tail(normalise(buf, -1.5), sr)


ANDROID_RAW = os.path.join(ROOT, "app", "android", "app", "src", "main", "res", "raw")


def main():
    write("ringtone.wav", ringtone(), 22050)
    write("ringback.wav", ringback(), 16000)
    write("message.wav", message(), 22050)
    write("mention.wav", mention(), 22050)
    write("reminder.wav", reminder(), 22050)
    os.makedirs(ANDROID_RAW, exist_ok=True)
    for name in ("mention", "reminder"):
        shutil.copyfile(os.path.join(OUT, f"{name}.wav"), os.path.join(ANDROID_RAW, f"lumora_{name}.wav"))


if __name__ == "__main__":
    main()
