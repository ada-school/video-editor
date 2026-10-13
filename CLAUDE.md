# Agentic Video Editor — Agent Brief

Turn long-form video (course recordings, talks, interviews) into short vertical clips for
social media. A file lands in `inbox/`, and the agents here transcribe it, find the ideas
worth clipping, and render uploadable shorts.

**Working language:** source video and all clip copy are usually **Spanish** (ADA Builders
course material). Write titles, hooks, and hashtags in Spanish unless asked otherwise.
This file and the code stay in English.

---

## Pipeline

Each stage writes a file the next stage reads, so any stage can be re-run alone.

| # | Stage | Command / skill | Produces |
|---|-------|-----------------|----------|
| 1 | Ingest | `bin/new-project.sh <video>` | `projects/<slug>/`, `media.json` |
| 1b | Layout | `bin/detect-layout.sh <slug>` | `layout` block for `cuts.json` |
| 2 | Transcribe | `bin/transcribe.sh <slug>` | `transcript.srt` / `.txt` / `.json` |
| 3 | Analyze | skill `find-clips` | `analysis.md` |
| 4 | Curate | skill `find-clips` | `cuts.json` ← **approval gate** |
| 5 | Render | `bin/render-all.sh <slug>` | `clips/<id>-<slug>/…` |
| 6 | Publish doc | skill `social-copy` | `publish.md` |

### Approval gate

**Never render without the user approving `cuts.json` first.** Renders cost minutes of CPU
per clip and cut choices are a matter of taste. Stages 1–4 run without asking; then present
the proposed clips as a table (id, title, range, duration, why) and wait. After approval,
render everything without further check-ins.

Stage 6 (`publish.md`) is not optional and not something to wait for the user to ask about:
a render that leaves them with MP4s and no copy is unfinished work. Run `social-copy` after
clips verify.

---

## Directory layout

```
inbox/                    drop source videos here; new-project.sh moves them out
models/ggml-medium.bin    whisper.cpp model (1.4 GB, not in git)
bin/                      the pipeline — plain bash + stdlib Python, no deps
assets/brand/             ada-closing.mp4 — brand outro appended to every clip (not in git)
templates/                cuts.example.json, publish.example.md
projects/<slug>/
  source/<file>.mp4       the original
  media.json              duration / dimensions / fps
  audio.wav               16 kHz mono, whisper's input
  transcript.srt|txt|json full transcript
  analysis.md             themes, key ideas, quotable moments with timestamps
  cuts.json               the clip plan — the one file a human approves
  clips/<id>-<slug>/
    vertical.mp4          1080×1920, burned captions → Instagram/TikTok/Shorts
    master.mp4            source-aspect cut, no captions → YouTube/LinkedIn
    captions.srt          editable transcript for this clip
    captions.ass          styled subtitles actually burned in
    metadata.json         cut entry + render facts
  publish.md              summary + Instagram/LinkedIn copy per clip, ready to paste
```

---

## Commands

```bash
bin/new-project.sh "inbox/Clase 2.mp4"   # create project, probe media
bin/detect-layout.sh clase2              # find screen-share + webcam regions
bin/transcribe.sh clase2 es             # whisper.cpp; ~real-time on M-series
bin/validate-cuts.py clase2             # ALWAYS run before rendering
bin/render-clip.sh clase2 03            # one clip
bin/render-all.sh clase2               # every clip in cuts.json
bin/render-all.sh clase2 --dry-run     # print what would render
bin/publish-facts.py clase2            # facts + captions behind publish.md
```

Overrides: `--fill blur|crop|stack`, `--no-captions`, `--no-outro`, env
`OUTRO_TRANSITION` `OUTRO_FADE` for the brand outro, `CAP_FONT` `CAP_SIZE`
`CAP_CHARS` `CAP_MARGIN` for caption look, and `STACK_CAM_W` `STACK_CAM_Y`
`STACK_SCREEN_Y` `STACK_BG` for stack geometry.

---

## Fill modes

`stack` is the right default for these class recordings. `blur` and `crop` are for footage
that fills its frame.

| Mode | Use for | What it does |
|------|---------|--------------|
| `stack` | Zoom/Meet screen share with webcam sidebar | Crops the two regions and stacks them — webcam on top, slide at full width below, captions under both, on a solid dark ground |
| `blur` | Footage that fills the frame | Whole frame centred over a blurred, darkened copy of itself |
| `crop` | Talking head only | Fills 9:16 by cropping the sides |

### Layout detection

`stack` needs a `layout` block in `cuts.json` giving the two source regions as ffmpeg
`w:h:x:y` crops. `bin/detect-layout.sh` finds them by sampling across the video, and the
validator refuses `fill: "stack"` without it:

```json
"layout": { "screen": "1440:810:0:135", "camera": "476:268:1444:406" }
```

Clase 1's layout: the shared screen is 16:9 letterboxed into the left 1440 px, and the
webcam is a fixed 476×268 box at 1444,406 — stable for the whole hour.

---

## cuts.json

`bin/validate-cuts.py` is the contract. Required per clip: `id` (zero-padded string),
`slug` (lowercase-kebab, becomes the directory name), `title`, `start`, `end`. Optional:
`hook`, `why`, `fill`, `platforms`, `hashtags`.

Timestamps accept `SS`, `MM:SS`, or `HH:MM:SS(.mmm)`. See `templates/cuts.example.json`.

`platforms` drives which copy gets written in stage 6. **Default is `["instagram",
"linkedin"]`** — those are the two accounts being published to, and they get a section for
every clip. `reels` is accepted as an alias for `instagram`. List `tiktok`, `shorts` or
`x` only for clips you actually intend to post there; they add sections, they don't replace
the two defaults.

### Brand outro

Every clip closes on the ADA brand clip, for brand awareness. Keep this top-level block in
every project's `cuts.json`:

```json
"outro": { "file": "assets/brand/ada-closing.mp4", "transition": "blur", "duration": 1.0 }
```

The clip blurs out and dissolves into the brand (`transition` also takes any ffmpeg
`xfade` name). `master.mp4` gets it at 16:9, `vertical.mp4` blur-filled to 9:16. It adds
≈9 s per render and the validator counts that toward the 180 s limit. Opt a clip out with
`"outro": false`. Brand files live in `assets/brand/` — never in `projects/<p>/source/`,
where the renderer's source fallback could pick one up as the clip's source.

### Redaction

Screen shares leak things. Cover regions with `redact` — a list of `w:h:x:y` boxes in
**source** pixels, either per clip or globally under `layout`:

```json
{ "id": "07", "redact": ["1440:88:0:135", "290:445:1150:500"] }
```

Applied during the **master** render, so `vertical.mp4` inherits it and `master.mp4` — the
copy that goes to YouTube/LinkedIn — is covered too.

---

## publish.md

Stage 6 produces a header with a **Resumen de la clase** and timestamped topics, then per
clip: a **Resumen**, a **Ficha** table (file paths with real resolution, duration, source
range, platforms), and pasteable copy — **Instagram** caption + on-screen cover text +
first-comment hashtags, and a **LinkedIn** post pointing at `master.mp4`. It closes with a
suggested publishing calendar. `templates/publish.example.md` shows the shape.

`bin/publish-facts.py <project>` is where the facts come from — source range, duration,
ffprobed resolution/fps/size of both renders, and each clip's full caption text. Copy is
written from that output, so no number or quote in `publish.md` is guessed. A clip carrying
`redact` or `needs_review` shows up with a **Revisar** row; that is a "do not publish yet"
flag, and it must be reported to the user rather than buried in the file.

---

## Delegation

For the thinking-heavy stages, dispatch the subagents in `.claude/agents/`:
`transcript-analyst` (stage 3), `clip-curator` (stage 4), `social-copywriter` (stage 6).
Transcripts run 50k+ characters; keeping that in a subagent's context instead of the main
thread is the point. The `find-clips` skill wires 3→4 together.

---

## Hard-won rules (do not skip)

- **Never put pixel values in ffmpeg's `subtitles=…:force_style`.** ffmpeg renders SRT into
  a 384×288 coordinate space, so `FontSize` is scaled ~6.7× and any `MarginV` over 288
  pushes captions off-screen with no error. Generate ASS with explicit `PlayResX/PlayResY`
  — that is what `srt_slice.py --ass` is for.

- **Transcribe with `-ml 42 -sow`.** Whisper's default 30-second cues are unusable as
  captions. `srt_slice.py --max-dur` repairs existing long cues, but transcribing correctly
  the first time is better.

- **Cut with `-ss` before `-i` and `-t`, not `-to`.** After input seeking, timestamps are
  rebased to zero, so `-to` would mean the wrong thing.

- **Default `fill` is `blur`, not `crop`.** This footage is mostly screen shares; a center
  crop slices code and slides in half. Use `crop` only for talking-head segments you have
  actually looked at.

- **Don't force an output frame rate.** The vertical render inherits the source's rate.
  Clase 1 is 24 fps; forcing 30 duplicated frames unevenly.

- **Check the screen share for private information before rendering.** Clase 1 clips 07 and
  08 shared a full browser window: the URL bar exposed a private Google Slides link, the
  bookmarks bar exposed personal bookmarks, and clip 07 showed the Meet participant panel
  with students' faces. Sample the screen region across every clip and *look* before you
  render. This is a consent issue, not a polish issue.

- **A named filtergraph link can only be consumed once.** `[0:v]` referenced three times is
  fine — ffmpeg auto-splits real input streams. `[clean]` referenced three times is **not**,
  and ffmpeg does not error: it silently reconnects the extra consumers to the raw input,
  so redaction appears to apply and does nothing. Either `split=N` explicitly, or do the
  work in an earlier pass — which is why redaction happens at the master stage.

- **`stack` draws on a solid dark ground, not a blurred slide.** The decks alternate between
  dark and light; blurring a light slide left white captions with too little contrast.

- **Caption width is a real constraint.** At `CAP_SIZE=58` the safe width is ~940 px, which
  is about 30 characters. `srt_slice.py` splits cues on both duration *and* character
  budget, and balances the two lines, because greedy wrapping leaves the last line
  unwrapped and it silently runs off-frame.

- **Captions sit at `MarginV=420`.** Lower than that and the TikTok/Reels UI covers them.

- Clips must be **8–180 s** and start/end on a sentence boundary. A clip that opens
  mid-sentence is dead on arrival.

- **Verify a render by grabbing a frame and looking at it.** A silent ffmpeg exit does not
  mean the captions rendered — that is exactly how the bug above hid:
  ```bash
  ffmpeg -ss 5 -i projects/<slug>/clips/<id>-<slug>/vertical.mp4 \
    -frames:v 1 /tmp/f.png && open /tmp/f.png
  ```

---

## Conventions

- `bin/` is bash + Python 3.9 stdlib only. No pip installs, no node. Keep it that way so
  the pipeline runs on a fresh machine with just homebrew ffmpeg and whisper.cpp.
- Scripts source `bin/lib.sh`, use `die`/`info`/`warn`, and are safe to re-run — they skip
  work whose output is already current.
- Never edit `transcript.srt` to fix a clip; slice it. The transcript is the source of
  truth for every clip's captions.
- Source videos and `models/` are gitignored. `cuts.json`, `analysis.md`, and `publish.md`
  are the artifacts worth committing.
