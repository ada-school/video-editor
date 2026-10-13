#!/usr/bin/env python3
"""Collect the facts a copywriter needs to write publish.md.

Every number, path and quote in publish.md comes from here, so the copy can never
invent a duration, a resolution or a claim the clip does not actually make.

  bin/publish-facts.py <project>          # text digest, one block per clip
  bin/publish-facts.py <project> --json   # the same facts as JSON
  bin/publish-facts.py <project> 03       # just one clip
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bin"))
from srt_slice import parse_time, read_srt  # noqa: E402

DEFAULT_PLATFORMS = ["instagram", "linkedin"]


def hhmmss(secs):
    h, m, s = int(secs // 3600), int(secs % 3600 // 60), secs % 60
    return "%02d:%02d:%05.2f" % (h, m, s) if h else "%02d:%05.2f" % (m, s)


def probe(path):
    """width, height, fps, duration, size for a rendered file — or None if absent."""
    if not os.path.isfile(path):
        return None
    out = {"size_mb": round(os.path.getsize(path) / 1048576.0, 1)}
    try:
        raw = subprocess.check_output([
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate",
            "-show_entries", "format=duration", "-of", "json", path,
        ], stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return out
    data = json.loads(raw)
    st = (data.get("streams") or [{}])[0]
    if st.get("width"):
        out["resolution"] = "%dx%d" % (st["width"], st["height"])
    rate = st.get("r_frame_rate") or ""
    if "/" in rate:
        num, den = rate.split("/", 1)
        if float(den or 0):
            out["fps"] = round(float(num) / float(den), 3)
    dur = (data.get("format") or {}).get("duration")
    if dur:
        out["duration_seconds"] = round(float(dur), 2)
    return out


def collect(proj, only=None):
    pdir = os.path.join(ROOT, "projects", proj)
    cuts_path = os.path.join(pdir, "cuts.json")
    if not os.path.isfile(cuts_path):
        raise SystemExit("error: no cuts.json in projects/%s" % proj)
    with open(cuts_path, encoding="utf-8") as fh:
        cuts = json.load(fh)

    source_duration = None
    media = os.path.join(pdir, "media.json")
    if os.path.isfile(media):
        with open(media, encoding="utf-8") as fh:
            source_duration = json.load(fh).get("duration")

    out = {
        "project": proj,
        "title": cuts.get("title") or proj,
        "language": cuts.get("language") or "es",
        "source": cuts.get("source"),
        "source_duration_seconds": source_duration,
        "has_analysis": os.path.isfile(os.path.join(pdir, "analysis.md")),
        "clips": [],
    }

    for c in cuts.get("clips") or []:
        cid = str(c.get("id", ""))
        if only and cid != only:
            continue
        cdir = os.path.join(pdir, "clips", "%s-%s" % (cid, c.get("slug", "")))
        start, end = parse_time(c["start"]), parse_time(c["end"])
        entry = {
            "id": cid,
            "slug": c.get("slug"),
            "title": c.get("title"),
            "hook": c.get("hook"),
            "why": c.get("why"),
            "fill": c.get("fill") or "blur",
            "platforms": c.get("platforms") or DEFAULT_PLATFORMS,
            "hashtags": c.get("hashtags") or [],
            "source_range": "%s–%s" % (hhmmss(start), hhmmss(end)),
            "duration_seconds": round(end - start, 2),
            "duration_label": hhmmss(end - start),
            "rendered": os.path.isdir(cdir),
            "dir": os.path.relpath(cdir, ROOT),
            "files": {},
            "transcript": "",
        }
        if cuts.get("outro") and c.get("outro") is not False:
            entry["outro"] = cuts["outro"].get("file")
        if c.get("redact"):
            entry["redact_boxes"] = len(c["redact"])
        if c.get("needs_review"):
            entry["needs_review"] = c["needs_review"]

        for name, fn in (("vertical", "vertical.mp4"), ("master", "master.mp4")):
            got = probe(os.path.join(cdir, fn))
            if got:
                got["path"] = os.path.join(entry["dir"], fn)
                entry["files"][name] = got

        srt = os.path.join(cdir, "captions.srt")
        if os.path.isfile(srt):
            entry["transcript"] = " ".join(q["text"] for q in read_srt(srt))
        out["clips"].append(entry)

    if only and not out["clips"]:
        raise SystemExit("error: no clip with id %r in projects/%s/cuts.json" % (only, proj))
    return out


def render_text(facts):
    w = sys.stdout.write
    w("# %s (%s)\n" % (facts["title"], facts["project"]))
    if facts["source_duration_seconds"]:
        w("source: %s — %s\n" % (facts["source"], hhmmss(facts["source_duration_seconds"])))
    w("language: %s   analysis.md: %s   clips: %d\n" %
      (facts["language"], "yes" if facts["has_analysis"] else "MISSING", len(facts["clips"])))

    for c in facts["clips"]:
        w("\n" + "-" * 72 + "\n")
        w("## %s — %s\n" % (c["id"], c["title"]))
        w("range %s   duration %s (%.1fs)   fill %s   rendered %s\n" %
          (c["source_range"], c["duration_label"], c["duration_seconds"],
           c["fill"], "yes" if c["rendered"] else "NO"))
        w("platforms: %s\n" % ", ".join(c["platforms"]))
        if c["hashtags"]:
            w("hashtags in cuts.json: %s\n" % " ".join(c["hashtags"]))
        if c.get("hook"):
            w("hook: %s\n" % c["hook"])
        if c.get("why"):
            w("why: %s\n" % c["why"])
        if c.get("outro"):
            w("outro: %s — file durations below include it; the range above does not\n" % c["outro"])
        if c.get("redact_boxes"):
            w("redact: %d box(es)\n" % c["redact_boxes"])
        if c.get("needs_review"):
            w("needs_review: %s\n" % c["needs_review"])
        for name, f in sorted(c["files"].items()):
            w("%s: %s — %s, %sfps, %.1fs, %sMB\n" % (
                name, f["path"], f.get("resolution", "?"), f.get("fps", "?"),
                f.get("duration_seconds", 0), f["size_mb"]))
        w("\ntranscript:\n%s\n" % (c["transcript"] or "(no captions.srt — clip not rendered)"))


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    if not args or len(args) > 2:
        raise SystemExit("usage: publish-facts.py <project> [clip-id] [--json]")
    facts = collect(args[0], args[1] if len(args) > 1 else None)
    if as_json:
        json.dump(facts, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
    else:
        render_text(facts)


if __name__ == "__main__":
    main()
