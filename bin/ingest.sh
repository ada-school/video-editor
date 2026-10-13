#!/usr/bin/env bash
# Extract 16kHz mono WAV from a project's source video (what whisper.cpp wants).
#   bin/ingest.sh <project>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need ffmpeg

dir="$(require_project "${1:?usage: ingest.sh <project>}")"
src="$(project_source "$dir")" || die "no source video in $dir/source/"

if [ -f "$dir/audio.wav" ] && [ "$dir/audio.wav" -nt "$src" ]; then
  info "audio.wav already up to date, skipping (delete it to force)"
  exit 0
fi
info "extracting audio from $(basename "$src")"
ffmpeg -hide_banner -loglevel error -stats -y -i "$src" \
  -vn -ac 1 -ar 16000 -c:a pcm_s16le "$dir/audio.wav"
info "wrote $dir/audio.wav"
