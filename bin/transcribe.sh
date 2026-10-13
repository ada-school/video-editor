#!/usr/bin/env bash
# Transcribe a project with whisper.cpp. Runs ingest first if audio is missing.
#   bin/transcribe.sh <project> [lang]     (lang defaults to es)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need whisper-cli

proj="${1:?usage: transcribe.sh <project> [lang]}"
lang="${2:-es}"
dir="$(require_project "$proj")"
[ -f "$WHISPER_MODEL" ] || die "whisper model not found: $WHISPER_MODEL"
[ -f "$dir/audio.wav" ] || "$ROOT/bin/ingest.sh" "$proj"

info "transcribing ($lang, $(basename "$WHISPER_MODEL")) — this takes a while"
# -ml 42 -sow produces caption-sized cues split on word boundaries, so the
# transcript is directly usable for burned-in subtitles.
whisper-cli -m "$WHISPER_MODEL" -f "$dir/audio.wav" -l "$lang" \
  -ml 42 -sow -pp -osrt -otxt -ojf -of "$dir/transcript"

[ -f "$dir/transcript.srt" ] || die "whisper produced no SRT"
info "wrote transcript.srt / .txt / .json in $dir"
info "next: ask Claude to analyze it — \"find clips in $proj\""
