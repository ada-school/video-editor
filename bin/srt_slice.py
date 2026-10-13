#!/usr/bin/env python3
"""Slice an SRT to a time range, rebase timestamps to zero, and reflow cues
so they are short enough to read as burned-in captions.

Whisper with default settings emits 30-second cues, which are unusable as
captions. --max-dur splits a long cue proportionally by character count and
--max-chars wraps each cue to at most two lines.

Usage:
  srt_slice.py TRANSCRIPT.srt --start 00:12:39 --end 00:14:12 [-o out.srt]
  srt_slice.py --parse-time 00:01:51.800      # prints seconds, for shell use
"""
import argparse
import math
import re
import sys

TIME_RE = re.compile(
    r"^(?:(?P<h>\d+):)?(?:(?P<m>\d{1,2}):)?(?P<s>\d{1,2})(?:[.,](?P<ms>\d{1,3}))?$"
)
CUE_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[.,](\d{3})"
)


def parse_time(text):
    """Accept SS, MM:SS, HH:MM:SS, with optional .mmm or ,mmm."""
    text = str(text).strip()
    m = TIME_RE.match(text)
    if not m:
        raise ValueError("cannot parse timestamp: %r" % text)
    h = int(m.group("h") or 0)
    mi = int(m.group("m") or 0)
    s = int(m.group("s"))
    # "12:39" parses as m=None,s=39 with h capturing 12 -> normalise
    if m.group("h") and not m.group("m"):
        h, mi = 0, int(m.group("h"))
    ms = m.group("ms") or "0"
    ms = int(ms.ljust(3, "0"))
    return h * 3600 + mi * 60 + s + ms / 1000.0


def fmt_srt(secs):
    if secs < 0:
        secs = 0.0
    total_ms = int(round(secs * 1000))
    ms = total_ms % 1000
    total = total_ms // 1000
    return "%02d:%02d:%02d,%03d" % (total // 3600, total % 3600 // 60, total % 60, ms)


def read_srt(path):
    with open(path, "r", encoding="utf-8-sig") as fh:
        raw = fh.read()
    cues = []
    for block in re.split(r"\n\s*\n", raw.strip()):
        lines = [ln for ln in block.splitlines() if ln.strip()]
        if not lines:
            continue
        idx = 0
        if lines[0].strip().isdigit() and len(lines) > 1:
            idx = 1
        m = CUE_RE.search(lines[idx] if idx < len(lines) else "")
        if not m:
            continue
        g = [int(x) for x in m.groups()]
        start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000.0
        end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000.0
        text = " ".join(ln.strip() for ln in lines[idx + 1:]).strip()
        if text:
            cues.append({"start": start, "end": end, "text": text})
    return cues


def split_long(cue, max_dur, max_text=None):
    """Split a cue that is too long — in seconds or in characters — into chunks on
    word boundaries, allocating time proportionally to each chunk's length."""
    dur = cue["end"] - cue["start"]
    too_long_text = max_text is not None and len(cue["text"]) > max_text
    if dur <= max_dur and not too_long_text:
        return [cue]
    by_dur = int(math.ceil(dur / max_dur)) if dur > max_dur else 1
    by_len = int(math.ceil(len(cue["text"]) / float(max_text))) if too_long_text else 1
    parts = max(2, by_dur, by_len)
    words = cue["text"].split()
    if len(words) < parts:
        return [cue]
    target = len(cue["text"]) / float(parts)
    chunks, buf = [], []
    for w in words:
        buf.append(w)
        cur = " ".join(buf)
        # break a little early on punctuation so cues end on a natural pause
        at_pause = w.endswith((".", ",", "?", "!", ":", ";"))
        if len(cur) >= target * (0.75 if at_pause else 1.0) and len(chunks) < parts - 1:
            chunks.append(cur)
            buf = []
    if buf:
        chunks.append(" ".join(buf))
    total_chars = sum(len(c) for c in chunks) or 1
    out, t = [], cue["start"]
    for i, c in enumerate(chunks):
        share = dur * (len(c) / float(total_chars))
        end = cue["end"] if i == len(chunks) - 1 else t + share
        out.append({"start": t, "end": end, "text": c})
        t = end
    return out


def wrap(text, max_chars, max_lines=2):
    """Balance the text across at most max_lines lines of <= max_chars.

    Greedy filling leaves the final line unwrapped and therefore able to overflow
    the frame, so instead pick the word boundaries that minimise the longest
    resulting line.
    """
    words = text.split()
    if not words or len(text) <= max_chars:
        return text
    if max_lines < 2:
        return text

    best, best_cost = None, None
    # choose the single split point (2 lines) that balances the two halves
    for i in range(1, len(words)):
        a = " ".join(words[:i])
        b = " ".join(words[i:])
        over = max(0, len(a) - max_chars) + max(0, len(b) - max_chars)
        cost = (over * 1000) + abs(len(a) - len(b))
        if best_cost is None or cost < best_cost:
            best, best_cost = (a, b), cost
    return "\n".join(best)


ASS_HEADER = """[Script Info]
ScriptType: v4.00+
PlayResX: %(w)d
PlayResY: %(h)d
WrapStyle: 2
ScaledBorderAndShadow: yes
YCbCr Matrix: None

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Caption,%(font)s,%(size)d,&H00FFFFFF,&H00FFFFFF,&H00101010,&H80000000,-1,0,0,0,100,100,0,0,1,%(outline)d,0,2,70,70,%(marginv)d,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""


def fmt_ass(secs):
    """ASS wants H:MM:SS.cc (centiseconds), not SRT's HH:MM:SS,mmm."""
    if secs < 0:
        secs = 0.0
    cs = int(round(secs * 100))
    return "%d:%02d:%02d.%02d" % (cs // 360000, cs % 360000 // 6000, cs % 6000 // 100, cs % 100)


def write_ass(cues, opts):
    """Emit a standalone ASS file.

    We build the ASS ourselves rather than using ffmpeg's subtitles=force_style
    on an SRT: that path renders into a 384x288 coordinate space, so pixel
    values for FontSize and MarginV silently mean something else (a MarginV
    larger than 288 pushes every caption off-screen). With explicit PlayResX/
    PlayResY the numbers below are real output pixels.
    """
    out = [ASS_HEADER % {
        "w": opts.width, "h": opts.height, "font": opts.font,
        "size": opts.font_size, "outline": opts.outline, "marginv": opts.margin_v,
    }]
    for cue in cues:
        text = cue["text"].replace("\\", "").replace("{", "(").replace("}", ")")
        text = text.replace("\n", "\\N")
        out.append("Dialogue: 0,%s,%s,Caption,,0,0,0,,%s\n"
                   % (fmt_ass(cue["start"]), fmt_ass(cue["end"]), text))
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("srt", nargs="?", help="source .srt file")
    ap.add_argument("--start", default="0")
    ap.add_argument("--end", default=None, help="omit to slice to the end")
    ap.add_argument("--max-chars", type=int, default=42, help="wrap width per caption line")
    ap.add_argument("--max-dur", type=float, default=3.5, help="split cues longer than this many seconds")
    ap.add_argument("--no-rebase", action="store_true", help="keep absolute source timestamps")
    ap.add_argument("-o", "--output", default="-")
    ap.add_argument("--ass", action="store_true", help="emit ASS (styled, for burning in) instead of SRT")
    ap.add_argument("--width", type=int, default=1080, help="ASS PlayResX — must match the output video")
    ap.add_argument("--height", type=int, default=1920, help="ASS PlayResY — must match the output video")
    ap.add_argument("--font", default="Helvetica")
    ap.add_argument("--font-size", type=int, default=64)
    ap.add_argument("--outline", type=int, default=6)
    ap.add_argument("--margin-v", type=int, default=420, help="px above the bottom edge, clear of platform UI")
    ap.add_argument("--parse-time", metavar="TS", help="print TS as seconds and exit")
    args = ap.parse_args()

    if args.parse_time is not None:
        print("%.3f" % parse_time(args.parse_time))
        return 0
    if not args.srt:
        ap.error("srt file required")

    start = parse_time(args.start)
    end = parse_time(args.end) if args.end else float("inf")
    if end <= start:
        raise SystemExit("error: --end must be after --start")

    kept = []
    for cue in read_srt(args.srt):
        if cue["end"] <= start or cue["start"] >= end:
            continue
        for piece in split_long(cue, args.max_dur, args.max_chars * 2):
            if piece["end"] <= start or piece["start"] >= end:
                continue
            piece["start"] = max(piece["start"], start)
            piece["end"] = min(piece["end"], end)
            if piece["end"] - piece["start"] >= 0.12:
                kept.append(piece)

    offset = 0.0 if args.no_rebase else start
    for cue in kept:
        cue["start"] -= offset
        cue["end"] -= offset
        cue["text"] = wrap(cue["text"], args.max_chars)

    if args.ass:
        body = write_ass(kept, args)
        if args.output == "-":
            sys.stdout.write(body)
        else:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(body)
            print("%s (%d cues)" % (args.output, len(kept)), file=sys.stderr)
        return 0

    out = []
    for i, cue in enumerate(kept, 1):
        out.append("%d\n%s --> %s\n%s\n" % (
            i,
            fmt_srt(cue["start"]),
            fmt_srt(cue["end"]),
            cue["text"],
        ))
    body = "\n".join(out)
    if args.output == "-":
        sys.stdout.write(body)
    else:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(body)
        print("%s (%d cues)" % (args.output, len(kept)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
