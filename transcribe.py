#!/usr/bin/env python3
"""Turn one raw call recording into CALLS_DIR/<id>.md and CALLS_DIR/<id>.m4a.

The app records two tracks per call, split into segments whenever an audio device changes:
  mic-NN.caf     your microphone            -> "Me"
  system-NN.caf  everything the Mac played  -> "Them"
meta.json gives each segment's start offset in seconds from the start of the call.

Each side's speech (found by the Silero VAD) is grouped so the other side never talks inside a group.
The groups are packed back to back with short silences and transcribed in one Whisper pass, and every
word returns to its group by its DTW time. Lines therefore start exactly when that side started talking
and the two sides interleave in the right order. Whisper's built-in VAD mode is not used: it lumps one
side's short replies into a single line and shifts their times.

Usage: transcribe.py RAW_DIR --out CALLS_DIR --models MODELS_DIR
Prints the transcript path on success. On failure RAW_DIR stays in place with transcribe.log, so it can be rerun.
"""
import argparse
import bisect
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import traceback
import wave
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

TRACKS = (("mic", "Me"), ("system", "Them"))
MODEL = "ggml-large-v3-turbo.bin"
VAD_MODEL = "ggml-silero-v5.1.2.bin"
RATE = 16000
SILENT_DB = -60.0  # a track whose peak stays below this captured nothing
MAX_PAUSE = 5.0  # seconds of one side's silence that still keep its speech in one group
MAX_GROUP = 25.0  # seconds; longer monologues become several lines, each with its own timestamp
PAD = 0.15  # seconds of audio kept around each group
SEPARATOR = 1.5  # seconds of silence between groups in the packed audio Whisper reads
VAD_ARGS = ["-vt", "0.35", "-vspd", "150"]  # more sensitive than the default so short "да" and "угу" count
TURN_GAP = 8.0  # seconds; one speaker's lines closer than this become one paragraph
LINE_GAP = 1.5  # seconds between words inside a group that start a new line (left by removed echo)
ECHO_WINDOW = 1.0  # seconds; a mic word this close to the same word from the other side is echo
ECHO_SHARE = 0.15  # remove echo only when this share of mic words is echo (speakers, not headphones)

# Whisper's well-known inventions on near-silent audio; matched against a whole line.
HALLUCINATIONS = [
    re.compile(p, re.I)
    for p in (
        r"продолжение следует\W*",
        r"субтитры (сделал|создавал|подготовил).*",
        r"редактор субтитров.*",
        r".*dimatorzok.*",
        r"спасибо за (просмотр|внимание)\W*",
        r"подписывайтесь на канал\W*",
        r"thanks? (you )?for watching\W*",
        r"\W*",
    )
]
PROMPTS = {
    "en": "Hi, how are you? Good, thanks. Let's get started.",
    "ru": "Привет, как дела? Хорошо, спасибо. Давай начнём.",
    "uk": "Привіт, як справи? Добре, дякую. Давай почнемо.",
    "es": "Hola, ¿qué tal? Bien, gracias. Empecemos.",
}
NOISE_TAGS = re.compile(r"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪")  # [BLANK_AUDIO], (music), *laughs*


@dataclass
class Word:
    time: float
    text: str


@dataclass
class Line:
    speaker: str
    start: float
    end: float
    text: str


def tool(name):
    path = shutil.which(name, path=os.environ.get("PATH", "") + os.pathsep + "/opt/homebrew/bin:/usr/local/bin")
    if not path:
        raise RuntimeError(f"{name} not found; install whisper-cpp and ffmpeg with brew")
    return path


FFMPEG, FFPROBE, WHISPER, VAD = (tool(n) for n in ("ffmpeg", "ffprobe", "whisper-cli", "whisper-vad-speech-segments"))


def run(cmd, log):
    log.write("$ " + " ".join(str(c) for c in cmd) + "\n")
    log.flush()
    subprocess.run([str(c) for c in cmd], check=True, stdout=log, stderr=subprocess.STDOUT)


def duration(path):
    result = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True,
    )
    try:
        return float(result.stdout.strip())
    except ValueError:
        return 0.0


def peak_db(path):
    result = subprocess.run(
        [FFMPEG, "-hide_banner", "-nostats", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    match = re.search(r"max_volume: (-?[\d.]+) dB", result.stderr)
    return float(match.group(1)) if match else float("-inf")


def place(segments, total, label, rate, graph, inputs):
    """Filter-graph steps that lay a track's segments on the call timeline as one mono stream named `label`."""
    parts = []
    for source, offset in segments:
        index = len(inputs) // 2  # inputs holds "-i", path pairs
        inputs += ["-i", source]
        graph.append(f"[{index}:a]aformat=sample_rates={rate}:channel_layouts=mono,"
                     f"adelay={int(round(offset * 1000))}:all=1[{label}{index}]")
        parts.append(f"[{label}{index}]")
    if not parts:
        graph.append(f"anullsrc=r={rate}:cl=mono,atrim=end={total:.3f}[{label}]")
    elif len(parts) == 1:
        graph.append(f"{parts[0]}apad=whole_dur={total:.3f}[{label}]")
    else:
        graph.append(f"{''.join(parts)}amix=inputs={len(parts)}:normalize=0:duration=longest,"
                     f"apad=whole_dur={total:.3f}[{label}]")


def track_wav(segments, total, target, log):
    graph, inputs = [], []
    place(segments, total, "t", RATE, graph, inputs)
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *inputs, "-filter_complex", ";".join(graph),
         "-map", "[t]", "-t", f"{total:.3f}", "-c:a", "pcm_s16le", target], log)


def build_audio(segments, total, target, log):
    """Stereo AAC: left channel = mic, right channel = system."""
    graph, inputs = [], []
    for track, _ in TRACKS:
        place(segments[track], total, track, 48000, graph, inputs)
    graph.append("[mic][system]amerge=inputs=2[out]")
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *inputs, "-filter_complex", ";".join(graph),
         "-map", "[out]", "-t", f"{total:.3f}", "-c:a", "aac", "-b:a", "96k", "-f", "mp4", target], log)


def speech_regions(wav, models):
    result = subprocess.run([VAD, "-np", "-vm", str(models / VAD_MODEL), "-f", str(wav), *VAD_ARGS],
                            capture_output=True, text=True, check=True)
    return [(float(a) / 100, float(b) / 100) for a, b in re.findall(r"start = ([\d.]+), end = ([\d.]+)",
                                                                    result.stdout)]


def group(mine, theirs):
    """One side's speech regions, grouped so that the other side never talks in the middle of a group."""
    groups = []
    for start, end in mine:
        if groups:
            last = groups[-1]
            interrupted = any(min(e, start) - max(s, last[1]) >= 0.1 for s, e in theirs)
            if not interrupted and start - last[1] <= MAX_PAUSE and end - last[0] <= MAX_GROUP:
                last[1] = end
                continue
        groups.append([start, end])
    return groups


def pack(wav, groups, target):
    """Lay one side's speech groups back to back with SEPARATOR of silence between them.

    Whisper then reads only that side's speech in one pass, with context, and the returned pieces
    (packed start, packed end, original start) map every word back to the call timeline.
    """
    with wave.open(str(wav), "rb") as source:
        frames = source.readframes(source.getnframes())
        width, total = source.getsampwidth(), source.getnframes() / RATE
    silence = bytes(int(SEPARATOR * RATE) * width)
    pieces, cursor = [], 0.0
    with wave.open(str(target), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(width)
        out.setframerate(RATE)
        for start, end in groups:
            start, end = max(0.0, start - PAD), min(total, end + PAD)
            first, last = int(start * RATE), int(end * RATE)
            out.writeframes(frames[first * width:last * width])
            seconds = (last - first) / RATE
            pieces.append((cursor, cursor + seconds, start))
            cursor += seconds
            out.writeframes(silence)
            cursor += SEPARATOR
    return pieces


def piece_at(pieces, moment):
    """Index of the piece that contains `moment` (packed time), or the nearest one if it falls in a separator."""
    best, distance = 0, float("inf")
    for i, (start, end, _) in enumerate(pieces):
        gap = 0.0 if start <= moment <= end else min(abs(moment - start), abs(moment - end))
        if gap < distance:
            best, distance = i, gap
        if start > moment:
            break
    return best


def clean(text):
    text = re.sub(r"\s+", " ", NOISE_TAGS.sub(" ", text)).strip()
    return "" if any(p.fullmatch(text) for p in HALLUCINATIONS) else text


def timed_words(segment):
    """A Whisper segment's tokens regrouped into words, each placed at the mean DTW time of its tokens."""
    found = []
    for token in segment.get("tokens", []):
        text = token.get("text", "")
        if not text or text.startswith("[_"):  # [_BEG_], [_TT_150] and other control tokens
            continue
        moment = token["t_dtw"] / 100 if token.get("t_dtw", -1) >= 0 else token["offsets"]["from"] / 1000
        if found and not text.startswith(" "):
            found[-1][0] += text
            found[-1][1].append(moment)
        else:
            found.append([text, [moment]])
    return [(text, sum(times) / len(times)) for text, times in found]


def detect_language(wav, models):
    """Whisper's language guess from the first 30 seconds, which in packed audio are all speech."""
    result = subprocess.run([WHISPER, "-m", str(models / MODEL), "-f", str(wav), "-l", "auto", "-dl"],
                            capture_output=True, text=True)
    match = re.search(r"auto-detected language: (\w+)", result.stderr)
    return match.group(1) if match else "auto"


def transcribe_track(wav, groups, work, prefix, models, log):
    """Every word one side said, placed on the call timeline and bucketed by group."""
    packed = work / f"{prefix}-packed.wav"
    pieces = pack(wav, groups, packed)
    base = work / f"{prefix}-whisper"
    language = detect_language(packed, models)
    # Little carried-over text (-mc 64): one bad window cannot drag the rest of the call into its style or skip
    # speech. A short punctuated prompt in every window keeps capitals and punctuation instead.
    prompt = ["--prompt", PROMPTS[language], "--carry-initial-prompt"] if language in PROMPTS else []
    # DTW aligns every token to the audio (Whisper's own token times drift); it needs flash attention off.
    run([WHISPER, "-m", models / MODEL, "-f", packed, "-l", language, "-ojf", "-of", base, "-np", "-mc", "64",
         *prompt, "-nfa", "-dtw", "large.v3.turbo"], log)
    data = json.loads(base.with_suffix(".json").read_bytes().decode("utf-8", errors="replace"))

    found = [[] for _ in groups]
    for segment in data.get("transcription", []):
        for text, moment in timed_words(segment):
            i = piece_at(pieces, moment)
            packed_start, packed_end, original_start = pieces[i]
            offset = min(max(moment - packed_start, 0.0), packed_end - packed_start)
            found[i].append(Word(original_start + offset, text))
    return found, language


def bare(word):
    return re.sub(r"\W+", "", word.text.lower())


def remove_echo(mine, theirs):
    """Drop mic words that are the other side heard through the speakers: the same word at the same moment.

    Only applied when echo is common, so with headphones a shared "да" at the same second survives.
    Returns how many words were removed.
    """
    heard = sorted((w.time, bare(w)) for group in theirs for w in group)
    times = [t for t, _ in heard]
    echoes = set()
    total = 0
    for group in mine:
        for word in group:
            key = bare(word)
            if not key:
                continue
            total += 1
            lo = bisect.bisect_left(times, word.time - ECHO_WINDOW)
            hi = bisect.bisect_right(times, word.time + ECHO_WINDOW)
            if any(heard[j][1] == key for j in range(lo, hi)):
                echoes.add(id(word))
    if not total or len(echoes) / total < ECHO_SHARE:
        return 0
    for group in mine:
        group[:] = [w for w in group if id(w) not in echoes]
    return len(echoes)


def lines_from(groups, found, speaker):
    """A group becomes one line, or several where removed echo left a gap inside it."""
    lines = []
    for (start, end), words in zip(groups, found):
        runs = []
        for word in words:
            if runs and word.time - runs[-1][-1].time <= LINE_GAP:
                runs[-1].append(word)
            else:
                runs.append([word])
        for run in runs:
            text = clean("".join(w.text for w in run))
            if text:
                lines.append(Line(speaker, max(start, run[0].time - 0.3), min(end, run[-1].time + 0.5), text))
    return lines


def turns(lines):
    merged = []
    for line in sorted(lines, key=lambda l: l.start):
        last = merged[-1] if merged else None
        if last and last.speaker == line.speaker and line.start - last.end <= TURN_GAP:
            last.end = max(last.end, line.end)
            last.text += " " + line.text
        else:
            merged.append(Line(line.speaker, line.start, line.end, line.text))
    return merged


def stamp(seconds):
    seconds = int(seconds)
    h, m, s = seconds // 3600, seconds // 60 % 60, seconds % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def length(seconds):
    minutes = round(seconds / 60)
    if seconds < 60:
        return f"{int(seconds)} s"
    return f"{minutes // 60} h {minutes % 60:02d} min" if minutes >= 60 else f"{minutes} min"


def process(raw, calls, models, log):
    for model in (MODEL, VAD_MODEL):
        if not (models / model).is_file():
            raise RuntimeError(f"{models / model} is missing; run install.sh")
    meta = json.loads((raw / "meta.json").read_text(encoding="utf-8"))
    call_id = meta["id"]
    started = datetime.fromisoformat(meta["started_at"])
    warnings = list(meta.get("warnings", []))
    work = raw / "work"
    work.mkdir(exist_ok=True)

    segments = {track: [] for track, _ in TRACKS}
    total = 0.0
    if meta.get("ended_at"):
        total = (datetime.fromisoformat(meta["ended_at"]) - started).total_seconds()
    for segment in meta.get("segments", []):
        source = raw / segment["file"]
        seconds = duration(source) if source.is_file() else 0.0
        if seconds >= 0.1:
            segments[segment["track"]].append((source, segment["offset"]))
            total = max(total, segment["offset"] + seconds)
    if total <= 0:
        raise RuntimeError("nothing was recorded")

    regions, wavs = {}, {}
    for track, _ in TRACKS:
        regions[track] = []
        if not segments[track]:
            continue
        wavs[track] = work / f"{track}.wav"
        track_wav(segments[track], total, wavs[track], log)
        if peak_db(wavs[track]) < SILENT_DB:
            warnings.append(
                "The Mac's sound output was silent for the whole call. If you heard the other side, allow "
                "Pear in System Settings > Privacy & Security > Screen & System Audio Recording."
                if track == "system" else "The microphone track is silent; check that the mic was not muted.")
            continue
        regions[track] = speech_regions(wavs[track], models)

    groups, found, languages = {}, {}, {}
    for track, speaker in TRACKS:
        groups[track], found[track] = [], []
        if regions[track]:
            groups[track] = group(regions[track], regions["system" if track == "mic" else "mic"])
            found[track], languages[speaker] = transcribe_track(wavs[track], groups[track], work, track, models, log)
    echoed = remove_echo(found["mic"], found["system"])
    if echoed:
        warnings.append(f"{echoed} words on the mic track were the other side heard through the speakers and were "
                        "removed; headphones give a cleaner split.")
    lines = [line for track, speaker in TRACKS for line in lines_from(groups[track], found[track], speaker)]

    calls.mkdir(parents=True, exist_ok=True)
    audio = calls / f"{call_id}.m4a"
    build_audio(segments, total, work / "audio.m4a", log)
    publish(work / "audio.m4a", audio)

    ended = started + timedelta(seconds=total)
    out = [f"# Call {started:%Y-%m-%d %H:%M}", "",
           f"- **When:** {started:%Y-%m-%d}, {started:%H:%M}–{ended:%H:%M} ({length(total)})",
           f"- **Audio:** [{audio.name}]({audio.name}) (left channel: me, right channel: them)"]
    if languages:
        out.append("- **Language:** " + ", ".join(f"{who.lower()}: {lang}" for who, lang in languages.items()))
    out += [f"- **Note:** {w}" for w in warnings]
    out += ["", "---", ""]
    out += [f"**[{stamp(t.start)}] {t.speaker}:** {t.text}\n" for t in turns(lines)] or ["_No speech recognised._", ""]

    transcript = calls / f"{call_id}.md"
    (work / "transcript.md").write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
    publish(work / "transcript.md", transcript)
    return transcript


def publish(source, target):
    """Move a finished file into the calls folder in one step, visible in Finder.

    Files are written in the work folder first: a dot-named temporary file inside the iCloud-synced calls folder
    gets the hidden flag, and the flag survived the rename (three .m4a files were invisible in Finder).
    """
    os.replace(source, target)
    flags = os.stat(target).st_flags
    if flags & stat.UF_HIDDEN:
        os.chflags(target, flags & ~stat.UF_HIDDEN)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("raw_dir", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    args = parser.parse_args()

    with open(args.raw_dir / "transcribe.log", "a", encoding="utf-8") as log:
        log.write(f"\n=== {datetime.now():%Y-%m-%d %H:%M:%S} ===\n")
        try:
            transcript = process(args.raw_dir, args.out, args.models, log)
        except Exception:
            traceback.print_exc(file=log)
            print(f"Transcription failed, see {args.raw_dir / 'transcribe.log'}", file=sys.stderr)
            return 1
    shutil.rmtree(args.raw_dir)
    print(transcript)
    return 0


if __name__ == "__main__":
    sys.exit(main())
