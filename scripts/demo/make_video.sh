#!/usr/bin/env bash
# Assemble the 60s dual-end demo from take4 raws + generated cards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RAW="${DEMO_RAW_DIR:-$ROOT/../artifacts/dual-demo-raw/take4}"
WORK="${DEMO_WORK_DIR:-$ROOT/../artifacts/dual-demo-edit}"
A="$WORK/assets"
TMP="$WORK/tmp"
OUT="${DEMO_OUT:-$WORK/demo-v0.2.0-dual-end.mp4}"
mkdir -p "$TMP"

ENC=(-c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 -an)

# ---- S1 title 5s -----------------------------------------------------------
ffmpeg -y -v error -loop 1 -t 5 -i "$A/card_title.png" \
  -vf "scale=1920:1080,fade=t=in:st=0:d=0.5,fade=t=out:st=4.5:d=0.5" \
  "${ENC[@]}" "$TMP/s1.mp4"

# ---- S2 side-by-side, round 1 ---------------------------------------------
ffmpeg -y -v error \
  -loop 1 -i "$A/sbs_bg.png" \
  -ss 106 -to 120 -i "$RAW/ios-raw.mp4" \
  -ss 48 -to 62 -i "$RAW/android-raw.mp4" \
  -loop 1 -i "$A/mask_ios.png" \
  -loop 1 -i "$A/mask_android.png" \
  -loop 1 -i "$A/sub_round1.png" \
  -filter_complex "\
[1:v]trim=duration=14,setpts=PTS-STARTPTS,scale=376:818,setsar=1[ios];\
[2:v]trim=duration=14,setpts=PTS-STARTPTS,crop=460:1280:130:0,scale=294:818,setsar=1[and];\
[0:v][ios]overlay=570:142:shortest=0[b1];\
[b1][and]overlay=1056:142:shortest=0[b2];\
[b2][3:v]overlay=570:142:shortest=0[b3];\
[b3][4:v]overlay=1056:142:shortest=0[b4];\
[b4][5:v]overlay=0:0:shortest=0,format=yuv420p,trim=duration=14[v]" \
  -map "[v]" "${ENC[@]}" "$TMP/s2.mp4"

# ---- S3 side-by-side, second round ----------------------------------------
ffmpeg -y -v error \
  -loop 1 -i "$A/sbs_bg.png" \
  -ss 120 -to 130 -i "$RAW/ios-raw.mp4" \
  -ss 4.9 -to 14.9 -i "$RAW/android-round2.mp4" \
  -loop 1 -i "$A/mask_ios.png" \
  -loop 1 -i "$A/mask_android.png" \
  -loop 1 -i "$A/sub_round2.png" \
  -filter_complex "\
[1:v]trim=duration=10,setpts=PTS-STARTPTS,scale=376:818,setsar=1[ios];\
[2:v]trim=duration=10,setpts=PTS-STARTPTS,crop=460:1280:130:0,scale=294:818,setsar=1[and];\
[0:v][ios]overlay=570:142:shortest=0[b1];\
[b1][and]overlay=1056:142:shortest=0[b2];\
[b2][3:v]overlay=570:142:shortest=0[b3];\
[b3][4:v]overlay=1056:142:shortest=0[b4];\
[b4][5:v]overlay=0:0:shortest=0,format=yuv420p,trim=duration=10[v]" \
  -map "[v]" "${ENC[@]}" "$TMP/s3.mp4"

# ---- S4 Android only: library then citation badge -------------------------
# The screenrecord of a static screen carries very few frames, so this beat is
# built from two real stills with a slow push-in instead of choppy playback.
ffmpeg -y -v error -i "$RAW/android-library.mp4" -ss 16.93 -frames:v 1 "$A/still_library.png"
ffmpeg -y -v error -i "$RAW/android-library.mp4" -ss 0 -frames:v 1 "$A/still_badge.png"
ffmpeg -y -v error \
  -loop 1 -i "$A/android_only_bg.png" \
  -loop 1 -i "$A/still_library.png" \
  -loop 1 -i "$A/still_badge.png" \
  -loop 1 -i "$A/mask_android.png" \
  -loop 1 -i "$A/sub_library.png" \
  -filter_complex "\
[1:v]crop=460:1280:130:0,scale=294:818,setsar=1,zoompan=z='1+0.05*on/150':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=150:s=294x818:fps=30,trim=duration=5,setpts=PTS-STARTPTS[lib];\
[2:v]crop=460:1280:130:0,scale=294:818,setsar=1,zoompan=z='1+0.03*on/130':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=130:s=294x818:fps=30,trim=duration=4.33,setpts=PTS-STARTPTS[badge];\
[lib][badge]concat=n=2:v=1:a=0,format=rgba[phone];\
[0:v][phone]overlay=380:142:shortest=0[b1];\
[b1][3:v]overlay=380:142:shortest=0[b2];\
[b2][4:v]overlay=0:0:shortest=0,format=yuv420p,trim=duration=9.3[v]" \
  -map "[v]" "${ENC[@]}" "$TMP/s4.mp4"

# ---- S5 protocol card 6s ---------------------------------------------------
ffmpeg -y -v error -loop 1 -t 6 -i "$A/card_protocol.png" \
  -loop 1 -t 6 -i "$A/sub_protocol.png" \
  -filter_complex "[0:v][1:v]overlay=0:0:shortest=0,format=yuv420p" \
  "${ENC[@]}" "$TMP/s5.mp4"

# ---- S6 end card 12s -------------------------------------------------------
ffmpeg -y -v error -loop 1 -t 12 -i "$A/card_end.png" \
  -vf "fade=t=in:st=0:d=0.4" \
  "${ENC[@]}" "$TMP/s6.mp4"

# ---- concat ----------------------------------------------------------------
rm -f "$TMP/list.txt"
for i in 1 2 3 4 5 6; do echo "file '$TMP/s$i.mp4'" >> "$TMP/list.txt"; done
ffmpeg -y -v error -f concat -safe 0 -i "$TMP/list.txt" -c copy "$TMP/joined.mp4"

ffmpeg -y -v error -i "$TMP/joined.mp4" \
  -vf "fade=t=out:st=55.6:d=0.7" "${ENC[@]}" "$OUT"

ffprobe -v error -show_entries format=duration,size -show_entries stream=width,height,r_frame_rate \
  -of default=nw=1 "$OUT"
