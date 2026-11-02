#!/bin/sh
# The Nanolight walkthrough (src/film.zig), 26 seconds at
# 1080p: frames rendered offscreen (no window shows), the system's Sonoma
# wallpaper behind the panel, and a soft tick for each key pressed and a
# breath of air as the panel opens. macOS (the wallpaper and the film are).
#
#     tools/film.sh [out.mp4] [--light]
set -eu
cd "$(dirname "$0")/.."
out="${1:-zig-out/nanolight/nanolight.mp4}"
flag="${2:-}"
dir=zig-out/nanolight
mkdir -p "$dir" "$(dirname "$out")"
wall="$dir/wallpaper.jpg"
if [ ! -f "$wall" ]; then
    src="/System/Library/Desktop Pictures/Sonoma.heic"
    sips -s format jpeg -s formatOptions 90 -Z 2560 "$src" --out "$dir/wallpaper-square.jpg" >/dev/null
    sips -c 1440 2560 "$dir/wallpaper-square.jpg" --out "$wall" >/dev/null
fi
zig build film -Doptimize=ReleaseFast
bin=zig-out/bin/nanolight-film
silent="$dir/silent.mp4"
# The cover (the video's thumbnail, the README's picture): the real panel
# over src/backdrop.jpg, art made with OpenAI's image model.
"$bin" --wallpaper=src/backdrop.jpg --cover="$dir/cover.png"
sips -s format jpeg -s formatOptions 90 "$dir/cover.png" --out "$dir/cover.jpg" >/dev/null
"$bin" --wallpaper="$wall" $flag | ffmpeg -loglevel error -y -f rawvideo -pix_fmt bgra -s 1920x1080 -r 30 -i - \
    -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p "$silent"

tick="0.22*sin(2*PI*2600*t)*exp(-110*t)+0.16*sin(2*PI*1300*t)*exp(-70*t)"
graph="anullsrc=r=44100:cl=stereo,atrim=0:26.5[m]"
mix="[m]"
n=1
ms() { awk -v s="$1" -v d="$2" 'BEGIN { v = (s + d) * 1000; if (v < 0) v = 0; printf "%d", v }'; }
while read -r kind at; do
    n=$((n + 1))
    case "$kind" in
    click) src="aevalsrc=exprs='$tick':d=0.08:s=44100"; at=$(ms "$at" 0) ;;
    cut) src="anoisesrc=d=0.6:c=pink:a=0.12:s=44100,highpass=f=600,lowpass=f=4500,afade=t=in:d=0.25,afade=t=out:st=0.25:d=0.35"; at=$(ms "$at" -0.2) ;;
    *) continue ;;
    esac
    graph="$graph;$src,aformat=channel_layouts=stereo,adelay=$at|$at[s$n]"
    mix="$mix[s$n]"
done <<CUES
$("$bin" --cues)
CUES
graph="$graph;${mix}amix=inputs=$n:normalize=0,alimiter=limit=0.9[a]"
ffmpeg -loglevel error -y -i "$silent" -i "$dir/cover.jpg" -filter_complex "$graph" \
    -map 0:v -map "[a]" -map 1:v -c:v copy -disposition:v:1 attached_pic -c:a aac -b:a 160k -movflags +faststart "$out"
rm -f "$silent"
echo "$out"
