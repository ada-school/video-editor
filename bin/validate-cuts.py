#!/usr/bin/env python3
"""Validate a project's cuts.json before rendering.

Catches the mistakes that are expensive to discover after a 10-minute render:
bad timestamps, duplicate ids/slugs, clips that run past the end of the source,
and durations outside the range each platform accepts.

  bin/validate-cuts.py <project>
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bin"))
from srt_slice import parse_time  # noqa: E402

REQUIRED = ("id", "slug", "title", "start", "end")
SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MIN_SECS, MAX_SECS = 8, 180  # Reels/TikTok/Shorts all accept up to 3 minutes


def check_outro(data, pdir, errors):
    """Validate the "outro" block; return the seconds it adds to every clip."""
    outro = data.get("outro")
    if not outro:
        return 0.0
    if not isinstance(outro, dict) or not outro.get("file"):
        errors.append("outro must be an object with a \"file\" path")
        return 0.0
    rel = outro["file"]
    path = next((p for p in (rel, os.path.join(ROOT, rel), os.path.join(pdir, rel))
                 if os.path.isabs(p) and os.path.isfile(p)), None)
    if not path:
        errors.append("outro file %r not found (relative to the repo root)" % rel)
        return 0.0
    fade = outro.get("duration", 1.0)
    if not isinstance(fade, (int, float)) or not 0.2 <= fade <= 3:
        errors.append("outro.duration must be 0.2–3 seconds, got %r" % fade)
        return 0.0
    if not re.match(r"^[a-z0-9]+$", str(outro.get("transition", "blur"))):
        errors.append("outro.transition must be 'blur' or an ffmpeg xfade name")
    try:
        secs = float(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "csv=p=0", path], stderr=subprocess.DEVNULL).strip())
    except (OSError, subprocess.CalledProcessError, ValueError):
        errors.append("could not read the duration of outro %r" % rel)
        return 0.0
    return max(0.0, secs - fade)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-cuts.py <project>")
    proj = sys.argv[1]
    pdir = os.path.join(ROOT, "projects", proj)
    path = os.path.join(pdir, "cuts.json")
    if not os.path.isfile(path):
        raise SystemExit("error: no cuts.json in projects/%s" % proj)

    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)

    errors, warnings = [], []
    clips = data.get("clips") or []
    if not clips:
        errors.append("cuts.json has no clips")

    source_dur = None
    media = os.path.join(pdir, "media.json")
    if os.path.isfile(media):
        with open(media, encoding="utf-8") as fh:
            source_dur = json.load(fh).get("duration")

    src = data.get("source")
    if src and not os.path.isfile(os.path.join(pdir, src)):
        warnings.append("source %r not found — transcript work is fine, rendering will fail" % src)

    layout = data.get("layout") or {}
    outro_secs = check_outro(data, pdir, errors)
    seen_ids, seen_slugs, spans = {}, {}, []
    for i, c in enumerate(clips):
        where = "clip[%d] (id=%s)" % (i, c.get("id", "?"))
        for k in REQUIRED:
            if not c.get(k):
                errors.append("%s missing required field %r" % (where, k))
        if any(not c.get(k) for k in REQUIRED):
            continue

        cid, slug = c["id"], c["slug"]
        if cid in seen_ids:
            errors.append("%s duplicate id, also used by clip[%d]" % (where, seen_ids[cid]))
        seen_ids[cid] = i
        if slug in seen_slugs:
            errors.append("%s duplicate slug %r, also clip[%d]" % (where, slug, seen_slugs[slug]))
        seen_slugs[slug] = i
        if not SLUG_RE.match(slug):
            errors.append("%s slug %r must be lowercase-kebab-case" % (where, slug))

        try:
            start, end = parse_time(c["start"]), parse_time(c["end"])
        except ValueError as exc:
            errors.append("%s %s" % (where, exc))
            continue
        if end <= start:
            errors.append("%s end (%s) is not after start (%s)" % (where, c["end"], c["start"]))
            continue

        dur = end - start
        if dur < MIN_SECS:
            warnings.append("%s is only %.1fs — too short to land an idea" % (where, dur))
        extra = outro_secs if c.get("outro") is not False else 0.0
        if dur + extra > MAX_SECS:
            errors.append("%s is %.1fs%s, over the %ds platform limit"
                          % (where, dur + extra, " with the outro" if extra else "", MAX_SECS))
        if source_dur and end > source_dur:
            errors.append("%s ends at %.1fs, past the source's %ss" % (where, end, source_dur))
        if c.get("fill") not in (None, "blur", "crop", "stack"):
            errors.append("%s fill must be 'blur', 'crop' or 'stack', got %r" % (where, c["fill"]))
        if c.get("fill") == "stack" and not (layout.get("screen") and layout.get("camera")):
            errors.append("%s uses fill='stack' but cuts.json has no layout.screen/"
                          "layout.camera — run bin/detect-layout.sh %s" % (where, proj))
        spans.append((start, end, cid, dur))

    for a, b in zip(sorted(spans), sorted(spans)[1:]):
        if b[0] < a[1]:
            warnings.append("clips %s and %s overlap — intentional only if you want both" % (a[2], b[2]))

    for w in warnings:
        print("\033[33mwarn:\033[0m %s" % w)
    for e in errors:
        print("\033[31merror:\033[0m %s" % e)

    if not errors:
        total = sum(s[3] for s in spans)
        print("\033[32mOK:\033[0m %d clips, %.1f min total, %d warning(s)%s"
              % (len(spans), total / 60.0, len(warnings),
                 ", outro adds %.1fs per clip" % outro_secs if outro_secs else ""))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
