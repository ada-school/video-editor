#!/usr/bin/env bash
# Render every clip in a project's cuts.json, sequentially.
#   bin/render-all.sh <project> [--dry-run] [any render-clip.sh option, e.g. --no-outro]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need jq

proj="${1:?usage: render-all.sh <project> [--dry-run]}"; shift
dir="$(require_project "$proj")"
[ -f "$dir/cuts.json" ] || die "no cuts.json in $dir"

ids=$(jq -r '.clips[].id' "$dir/cuts.json")
n=$(printf '%s\n' "$ids" | grep -c . || true)
info "rendering $n clip(s) from $proj"
i=0
for id in $ids; do
  i=$((i+1))
  info "[$i/$n]"
  "$ROOT/bin/render-clip.sh" "$proj" "$id" "$@"
done
info "all clips written to $dir/clips/"
info "next: verify a frame per clip, then write $dir/publish.md (skill: social-copy)"
