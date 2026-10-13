#!/usr/bin/env bash
# Shared helpers for the video-edit pipeline. Source, don't execute.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS="$ROOT/projects"
INBOX="$ROOT/inbox"
MODELS="$ROOT/models"
WHISPER_MODEL="${WHISPER_MODEL:-$MODELS/ggml-medium.bin}"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

project_dir() {
  local p="${1:?project name required}"
  printf '%s/%s' "$PROJECTS" "$p"
}

require_project() {
  local d; d="$(project_dir "$1")"
  [ -d "$d" ] || die "no such project: $1 (expected $d)"
  printf '%s' "$d"
}

# Resolve the source video for a project: cuts.json "source", else first file in source/
project_source() {
  local d="$1" src=""
  if [ -f "$d/cuts.json" ]; then
    src="$(jq -r '.source // empty' "$d/cuts.json")"
    [ -n "$src" ] && [ -f "$d/$src" ] && { printf '%s' "$d/$src"; return; }
    [ -n "$src" ] && [ -f "$src" ] && { printf '%s' "$src"; return; }
  fi
  src="$(find "$d/source" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.webm' \) 2>/dev/null | head -1)"
  [ -n "$src" ] || return 1
  printf '%s' "$src"
}

# seconds -> HH:MM:SS.mmm
to_ts() { python3 -c 'import sys;s=float(sys.argv[1]);h=int(s//3600);m=int(s%3600//60);print("%02d:%02d:%06.3f"%(h,m,s%60))' "$1"; }
# HH:MM:SS.mmm | MM:SS | SS -> seconds
to_secs() { python3 "$ROOT/bin/srt_slice.py" --parse-time "$1"; }
