#!/usr/bin/env bash
# Detect the screen-share and webcam regions in a screen-recording layout
# (Zoom/Meet sidebar style) and print a `layout` block for cuts.json.
#
#   bin/detect-layout.sh <project> [timestamp]
#
# Samples several points in the video so a momentary full-screen slide or a
# camera-off stretch does not produce a bogus region.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need ffmpeg; need jq

proj="${1:?usage: detect-layout.sh <project> [timestamp]}"
dir="$(require_project "$proj")"
src="$(project_source "$dir")" || die "no source video in $dir/source/"

dur="$(jq -r '.duration // 600' "$dir/media.json" 2>/dev/null || echo 600)"
if [ -n "${2:-}" ]; then
  samples="$2"
else
  # spread samples across the middle 80% — intros and outros are unrepresentative
  samples=""
  for frac in 15 30 45 60 75 90; do
    samples="$samples $(python3 -c "print(int($dur*$frac/100))")"
  done
fi

detect() { # detect <crop-window> <limit>
  ffmpeg -hide_banner -ss "$3" -t 1 -i "$src" \
    -vf "crop=$1,cropdetect=limit=$2:round=2:reset=0" -f null - 2>&1 \
    | grep -o 'crop=[0-9]*:[0-9]*:[0-9]*:[0-9]*' | tail -1 | cut -d= -f2
}

info "sampling $src at:$samples"
w="$(jq -r '.width // 1920'  "$dir/media.json")"
h="$(jq -r '.height // 1080' "$dir/media.json")"

# The webcam is the bright region; find it in the right-hand strip.
strip_w=$((w / 4)); strip_x=$((w - strip_w))
declare -a cams=()
for t in $samples; do
  c="$(detect "$strip_w:$h:$strip_x:0" 24 "$t")" || true
  [ -n "$c" ] && cams+=("$c")
done
[ ${#cams[@]} -gt 0 ] || die "could not detect a webcam region"
# most common result wins
cam="$(printf '%s\n' "${cams[@]}" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
IFS=: read -r cw ch cx cy <<<"$cam"
cam_abs="$cw:$ch:$((cx + strip_x)):$cy"

# The shared screen fills the remaining width, letterboxed to 16:9.
screen_w=$strip_x
screen_h=$((screen_w * 9 / 16))
screen_y=$(( (h - screen_h) / 2 ))
screen="$screen_w:$screen_h:0:$screen_y"

info "screen  $screen"
info "camera  $cam_abs  (seen in ${#cams[@]} of $(printf '%s' "$samples" | wc -w | tr -d ' ') samples)"
echo
echo "Add to projects/$proj/cuts.json, and set clips to \"fill\": \"stack\":"
jq -n --arg s "$screen" --arg c "$cam_abs" '{layout:{screen:$s,camera:$c}}'
echo
warn "verify before rendering 8 clips:"
echo "  ffmpeg -ss <t> -i '$src' -vf crop=$screen -frames:v 1 /tmp/screen.png"
echo "  ffmpeg -ss <t> -i '$src' -vf crop=$cam_abs -frames:v 1 /tmp/cam.png"
