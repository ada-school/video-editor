#!/usr/bin/env bash
# Create a project from a video in inbox/ (or any path) and probe its metadata.
#   bin/new-project.sh "inbox/Clase 2.mp4" [project-slug]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need ffprobe; need jq

VIDEO="${1:?usage: new-project.sh <video-path> [project-slug]}"
[ -f "$VIDEO" ] || die "no such file: $VIDEO"

base="$(basename "$VIDEO")"
# sed -E because BSD sed (macOS) has no \+ in basic regex and would silently
# leave spaces in the slug, which then break every downstream path.
slug="${2:-$(printf '%s' "${base%.*}" | tr '[:upper:]' '[:lower:]' | sed -E -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//')}"
dir="$PROJECTS/$slug"
[ -e "$dir/source" ] && warn "project $slug already exists, reusing"
mkdir -p "$dir/source" "$dir/clips" "$dir/review"

# Move rather than copy: these files are large and the inbox is a staging area.
if [ ! -f "$dir/source/$base" ]; then
  mv "$VIDEO" "$dir/source/$base"
  info "moved source into $dir/source/$base"
fi
src="$dir/source/$base"

ffprobe -v error -show_format -show_streams -of json "$src" > "$dir/probe.json"
jq -n --arg slug "$slug" --arg src "source/$base" --slurpfile p "$dir/probe.json" '
  {
    project: $slug,
    source: $src,
    duration: ($p[0].format.duration | tonumber | floor),
    width:  ($p[0].streams | map(select(.codec_type=="video")) | .[0].width),
    height: ($p[0].streams | map(select(.codec_type=="video")) | .[0].height),
    fps:    ($p[0].streams | map(select(.codec_type=="video")) | .[0].r_frame_rate)
  }' > "$dir/media.json"

cat "$dir/media.json"
info "project ready: projects/$slug — next: bin/transcribe.sh $slug"
