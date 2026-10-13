#!/usr/bin/env bash
# Render one clip from a project's cuts.json into:
#   master.mp4    16:9 cut, no captions (archive / YouTube / LinkedIn)
#   vertical.mp4  1080x1920 with burned captions (Reels / TikTok / Shorts)
#   captions.srt  rebased to the clip, reflowed for readability
#   metadata.json the cut entry plus render facts
#
#
# When cuts.json has an "outro" block, both renders close on the brand clip,
# joined by a transition: native 16:9 on master, blur-filled 9:16 on vertical.
#
#   bin/render-clip.sh <project> <clip-id> [--dry-run] [--fill blur|crop|stack] [--no-captions] [--no-outro]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need ffmpeg; need ffprobe; need jq

proj="${1:?usage: render-clip.sh <project> <clip-id> [opts]}"; shift
id="${1:?clip id required (the \"id\" field in cuts.json)}"; shift

DRY=0; FILL=""; CAPTIONS=1; OUTRO=1
# Caption look. Sizes are real output pixels (see srt_slice.py --ass).
CAP_FONT="${CAP_FONT:-Helvetica}"
CAP_SIZE="${CAP_SIZE:-58}"
CAP_CHARS="${CAP_CHARS:-30}"
CAP_MARGIN="${CAP_MARGIN:-420}"
# fill=stack panel geometry, in output pixels
STACK_CAM_W="${STACK_CAM_W:-756}"
STACK_CAM_Y="${STACK_CAM_Y:-190}"
STACK_SCREEN_Y="${STACK_SCREEN_Y:-670}"
STACK_BG="${STACK_BG:-0x0D1117}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY=1 ;;
    --fill)        FILL="${2:?}"; shift ;;
    --no-captions) CAPTIONS=0 ;;
    --no-outro)    OUTRO=0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

dir="$(require_project "$proj")"
cuts="$dir/cuts.json"
[ -f "$cuts" ] || die "no cuts.json in $dir — run the find-clips skill first"

cut="$(jq -c --arg id "$id" '.clips[] | select(.id == $id)' "$cuts")"
[ -n "$cut" ] || die "clip id '$id' not found in $cuts"

slug="$(jq -r '.slug'  <<<"$cut")"
title="$(jq -r '.title' <<<"$cut")"
start_ts="$(jq -r '.start' <<<"$cut")"
end_ts="$(jq -r '.end'   <<<"$cut")"
[ -z "$FILL" ] && FILL="$(jq -r '.fill // "blur"' <<<"$cut")"

src="$(project_source "$dir")" || die "source video missing for project $proj (expected in $dir/source/)"

# Screen-share geometry, in source pixels. bin/detect-layout.sh finds these.
LAYOUT_SCREEN="$(jq -r '.layout.screen // empty' "$cuts")"
LAYOUT_CAMERA="$(jq -r '.layout.camera // empty' "$cuts")"

# Regions to cover before anything else sees the frame: browser URL bars, a
# meeting's participant panel, anything showing someone who did not agree to be
# in a public clip. Given as w:h:x:y in source pixels, same as the layout crops.
redactions="$( { jq -r '.layout.redact // [] | .[]' "$cuts"; jq -r '.redact // [] | .[]' <<<"$cut"; } )"
redact_vf=""
if [ -n "$redactions" ]; then
  chain=""
  n=0
  while IFS= read -r box; do
    [ -n "$box" ] || continue
    IFS=: read -r bw bh bx by <<<"$box"
    [ -n "$bw" ] && [ -n "$bh" ] && [ -n "$bx" ] && [ -n "$by" ] \
      || die "bad redact box '$box' — expected w:h:x:y"
    chain="${chain}drawbox=x=$bx:y=$by:w=$bw:h=$bh:color=0x0D1117@1:t=fill,"
    n=$((n+1))
  done <<<"$redactions"
  redact_vf="${chain%,}"
  info "  redacting $n region(s) in both master and vertical"
fi

start_s="$(to_secs "$start_ts")"
end_s="$(to_secs "$end_ts")"
dur="$(python3 -c "print('%.3f' % ($end_s - $start_s))")"
python3 -c "import sys; sys.exit(0 if $dur > 0.5 else 1)" || die "clip $id has a non-positive duration"

# Closing brand clip. Path is relative to the repo root (or the project dir);
# a clip opts out with "outro": false.
outro_file=""
if [ "$OUTRO" = 1 ] && [ "$(jq -r 'if .outro == false then "off" else "on" end' <<<"$cut")" = on ]; then
  outro_rel="$(jq -r '.outro.file // empty' "$cuts")"
  if [ -n "$outro_rel" ]; then
    case "$outro_rel" in /*) cands=("$outro_rel") ;; *) cands=("$ROOT/$outro_rel" "$dir/$outro_rel") ;; esac
    for cand in "${cands[@]}"; do
      [ -f "$cand" ] && { outro_file="$cand"; break; }
    done
    [ -n "$outro_file" ] || die "outro file not found: $outro_rel"
  fi
fi
OUTRO_TRANSITION="${OUTRO_TRANSITION:-$(jq -r '.outro.transition // "blur"' "$cuts")}"
OUTRO_FADE="${OUTRO_FADE:-$(jq -r '.outro.duration // 1.0' "$cuts")}"

out="$dir/clips/$id-$slug"
info "clip $id — $title"
info "  $start_ts -> $end_ts (${dur}s), fill=$FILL, captions=$CAPTIONS"
[ -n "$outro_file" ] && info "  outro: ${outro_file#$ROOT/} (${OUTRO_TRANSITION}, ${OUTRO_FADE}s)"
info "  -> ${out#$ROOT/}"
[ "$DRY" = 1 ] && { info "dry run, nothing rendered"; exit 0; }
mkdir -p "$out"

# xfade needs both sides at the same rate and timebase, so the outro is
# conformed to the source's own rate — never a forced one.
src_v="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of json "$src")"
SRC_W="$(jq -r '.streams[0].width' <<<"$src_v")"
SRC_H="$(jq -r '.streams[0].height' <<<"$src_v")"
SRC_FPS="$(jq -r '.streams[0].r_frame_rate' <<<"$src_v")"
SRC_HAS_AUDIO="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$src" | head -1)"

secs() { python3 -c "print('%.3f' % ($1))"; }

# Video leading into the outro. For "blur" the clip dissolves into a blurred
# copy of itself half a fade ahead of the brand dissolve; the blurred copy is
# trimmed so both halves stay frame-aligned. Other names pass to xfade as-is.
outro_ramp() {  # <in> <out> <offset>
  local in="$1" o="$2" off="$3" at
  if [ "$OUTRO_TRANSITION" = blur ]; then
    at="$(secs "max(0, $off - $OUTRO_FADE / 2)")"
    printf '[%s]split=2[%s_s][%s_b];[%s_b]gblur=sigma=40,trim=start=%s,setpts=PTS-STARTPTS[%s_bl];[%s_s][%s_bl]xfade=transition=fade:duration=%s:offset=%s[%s]' \
      "$in" "$o" "$o" "$o" "$at" "$o" "$o" "$o" "$OUTRO_FADE" "$at" "$o"
  else
    printf '[%s]null[%s]' "$in" "$o"
  fi
}
outro_join() {  # <clip> <brand> <out> <offset>
  local t="$OUTRO_TRANSITION"; [ "$t" = blur ] && t=fade
  printf '[%s][%s]xfade=transition=%s:duration=%s:offset=%s,format=yuv420p[%s]' "$1" "$2" "$t" "$OUTRO_FADE" "$4" "$3"
}
# Speech fades only over the dissolve; the brand's audio fades in under it.
outro_audio() {  # <clip-audio|""> <out> <offset>
  local ms; ms="$(python3 -c "print(int(round($3 * 1000)))")"
  local norm="aresample=48000,aformat=channel_layouts=stereo"
  local brand="[1:a]$norm,afade=t=in:d=$OUTRO_FADE,adelay=$ms:all=1"
  if [ -n "$1" ]; then
    printf '[%s]%s,afade=t=out:st=%s:d=%s[%s_sp];%s[%s_br];[%s_sp][%s_br]amix=inputs=2:duration=longest:normalize=0[%s]' \
      "$1" "$norm" "$3" "$OUTRO_FADE" "$2" "$brand" "$2" "$2" "$2" "$2"
  else
    printf '%s[%s]' "$brand" "$2"
  fi
}

# 1. 16:9 master. -ss before -i is accurate in modern ffmpeg and avoids
#    decoding the whole file; -t keeps the range independent of timestamp base.
#    With an outro, one pass also writes the clean cut the vertical is built
#    from — the vertical must not inherit a 16:9 outro it would then crop.
enc_master=(-c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart)
body="$out/master.mp4"
if [ -z "$outro_file" ]; then
  info "  rendering master.mp4"
  ffmpeg -hide_banner -loglevel error -stats -y \
    -ss "$start_s" -t "$dur" -i "$src" \
    ${redact_vf:+-vf "$redact_vf"} \
    "${enc_master[@]}" "$out/master.mp4"
else
  info "  rendering master.mp4 + outro"
  body="$out/.body.mp4"
  off="$(secs "$dur - $OUTRO_FADE")"
  g="[0:v]${redact_vf:+$redact_vf,}split=2[body][m0];"
  g+="[m0]fps=$SRC_FPS,setsar=1,format=yuv420p,settb=AVTB[m1];"
  g+="[1:v]fps=$SRC_FPS,scale=$SRC_W:$SRC_H:force_original_aspect_ratio=decrease,pad=$SRC_W:$SRC_H:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p,settb=AVTB[brand];"
  g+="$(outro_ramp m1 m2 "$off");$(outro_join m2 brand mv "$off");"
  body_amap=()
  if [ -n "$SRC_HAS_AUDIO" ]; then
    g+="[0:a]asplit=2[abody][a0];$(outro_audio a0 ma "$off")"
    body_amap=(-map '[abody]')
  else
    g+="$(outro_audio "" ma "$off")"
  fi
  ffmpeg -hide_banner -loglevel error -stats -y \
    -ss "$start_s" -t "$dur" -i "$src" -i "$outro_file" \
    -filter_complex "$g" \
    -map '[body]' ${body_amap[@]+"${body_amap[@]}"} "${enc_master[@]}" "$body" \
    -map '[mv]' -map '[ma]' "${enc_master[@]}" "$out/master.mp4"
fi

# 2. Clip-local captions: an editable .srt plus the styled .ass that gets burned.
sub_filter=""
if [ "$CAPTIONS" = 1 ] && [ -f "$dir/transcript.srt" ]; then
  slice_args=(--start "$start_ts" --end "$end_ts" --max-chars "$CAP_CHARS" --max-dur 3.0)
  python3 "$ROOT/bin/srt_slice.py" "$dir/transcript.srt" "${slice_args[@]}" -o "$out/captions.srt"
  python3 "$ROOT/bin/srt_slice.py" "$dir/transcript.srt" "${slice_args[@]}" --ass \
    --width 1080 --height 1920 --font "$CAP_FONT" --font-size "$CAP_SIZE" --margin-v "$CAP_MARGIN" \
    -o "$out/captions.ass"
  # Rendered from inside $out so the filter path needs no escaping.
  sub_filter=",ass=captions.ass"
elif [ "$CAPTIONS" = 1 ]; then
  warn "  no transcript.srt — rendering vertical without captions"
fi

# 3. Vertical 1080x1920 from the master (already cut, so this is cheap).
#    blur: full frame centred over a blurred zoomed copy — safe for screen
#    recordings, where a hard crop would cut off code and slides.
#    crop:  fill the frame by cropping the sides — for talking-head footage.
case "$FILL" in
  blur) vf="[0:v]scale=1080:-2[fg];[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,gblur=sigma=26,eq=brightness=-0.10[bg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p[v]" ;;
  crop) vf="[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,format=yuv420p[v]" ;;
  stack)
    # Screen recordings with a webcam sidebar: scaling the whole 16:9 frame to
    # 1080 wide leaves the slide text too small to read on a phone. Instead crop
    # the two regions out and stack them — webcam panel on top, slide at full
    # width below, captions underneath.
    [ -n "$LAYOUT_SCREEN" ] && [ -n "$LAYOUT_CAMERA" ] \
      || die "fill=stack needs a \"layout\" block in cuts.json — run: bin/detect-layout.sh $proj"
    vf="[0:v]scale=1080:1920,drawbox=x=0:y=0:w=1080:h=1920:color=$STACK_BG@1:t=fill[bg];\
[0:v]crop=$LAYOUT_SCREEN,scale=1080:-2,drawbox=x=0:y=0:w=iw:h=ih:color=0x2C3E50@1:t=3[screen];\
[0:v]crop=$LAYOUT_CAMERA,scale=$STACK_CAM_W:-2,drawbox=x=0:y=0:w=iw:h=ih:color=0x2C3E50@1:t=3[cam];\
[bg][cam]overlay=(W-w)/2:$STACK_CAM_Y[s1];\
[s1][screen]overlay=(W-w)/2:$STACK_SCREEN_Y,format=yuv420p[v]" ;;
  *)    die "unknown --fill value: $FILL (use blur, crop or stack)" ;;
esac

enc_vertical=(-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart)
if [ -z "$outro_file" ]; then
  info "  rendering vertical.mp4"
  ( cd "$out" && ffmpeg -hide_banner -loglevel error -stats -y -i master.mp4 \
      -filter_complex "${vf};[v]null${sub_filter}[vout]" -map '[vout]' -map 0:a? \
      "${enc_vertical[@]}" vertical.mp4 )
else
  info "  rendering vertical.mp4 + outro"
  body_dur="$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 "$body")"
  off="$(secs "$body_dur - $OUTRO_FADE")"
  # Captions go on after the blur ramp so the last line stays readable until
  # the dissolve takes it.
  g="${vf};[v]fps=$SRC_FPS,settb=AVTB[vb];$(outro_ramp vb vr "$off");[vr]null${sub_filter}[vc];"
  g+="[1:v]fps=$SRC_FPS,setsar=1,split=2[oa][ob];[oa]scale=1080:-2[ofg];"
  g+="[ob]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,gblur=sigma=26,eq=brightness=-0.10[obg];"
  g+="[obg][ofg]overlay=(W-w)/2:(H-h)/2,format=yuv420p,settb=AVTB[brand];"
  g+="$(outro_join vc brand vout "$off");"
  if [ -n "$SRC_HAS_AUDIO" ]; then g+="$(outro_audio 0:a vaout "$off")"; else g+="$(outro_audio "" vaout "$off")"; fi
  ( cd "$out" && ffmpeg -hide_banner -loglevel error -stats -y -i "$(basename "$body")" -i "$outro_file" \
      -filter_complex "$g" -map '[vout]' -map '[vaout]' \
      "${enc_vertical[@]}" vertical.mp4 )
  rm -f "$body"
fi

# 4. Metadata for the upload step.
rendered_dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out/vertical.mp4")"
outro_json='null'
[ -n "$outro_file" ] && outro_json="$(jq -n --arg f "${outro_file#$ROOT/}" --arg t "$OUTRO_TRANSITION" \
  --arg d "$OUTRO_FADE" '{file:$f, transition:$t, fade_seconds:($d|tonumber)}')"
jq -n --argjson cut "$cut" --arg dur "$dur" --arg fill "$FILL" --arg rdur "$rendered_dur" \
      --argjson outro "$outro_json" \
      --arg proj "$proj" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  $cut + {project:$proj, duration_seconds:($dur|tonumber),
          rendered_duration_seconds:($rdur|tonumber), outro:$outro, fill:$fill, rendered_at:$at,
          files:{vertical:"vertical.mp4", master:"master.mp4", captions:"captions.srt"}}' \
  > "$out/metadata.json"

info "  done: $(ls "$out" | tr '\n' ' ')"
