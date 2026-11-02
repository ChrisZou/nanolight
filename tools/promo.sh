#!/bin/sh
# The promo (src/promo.zig): 31 seconds, 1920x1080 at 30 fps, cut to a
# 120 BPM beat with a progress bar along the bottom, to docs/promo.mp4 and
# a silent preview, docs/promo-preview.gif. macOS, with ffmpeg, Blender
# (/Applications/Blender.app, or $BLENDER) and Swift (Xcode's tools).
#
#     tools/promo.sh [out.mp4]
#
# Fetched as it runs, into zig-out/promo, and never kept in the repository:
# Apple's MacBook Air AR model from apple.com (its display shows the
# promo's frames; its baked wallpaper is the desktop), and Google's results
# page for the search shown, captured in an offscreen WebKit view.
set -eu
cd "$(dirname "$0")/.."
out="${1:-docs/promo.mp4}"
dir=zig-out/promo
blender="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
mkdir -p "$dir" "$(dirname "$out")"

# Apple's MacBook Air (13-inch, midnight), and its wallpaper.
model="$dir/macbook-air-13in-midnight.usdz"
if [ ! -f "$model" ]; then
    curl -sfL -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15" -o "$model" \
        "https://www.apple.com/105/media/us/macbook-air/2025/0833fe28-c438-4dc4-8edc-e39ef30df5f9/ar/macbook-air-13in-midnight.usdz"
fi
if [ ! -f "$dir/wall-1080.jpg" ]; then
    "$blender" -b --factory-startup --python tools/promo/wallpaper.py -- "$model" "$dir/apple-wall.png" >/dev/null
    ffmpeg -loglevel error -y -i "$dir/apple-wall.png" -vf "scale=-2:1080,crop=1920:1080" -q:v 2 "$dir/wall-1080.jpg"
    ffmpeg -loglevel error -y -i "$dir/apple-wall.png" -vf "scale=-2:1195,crop=1838:1195" -q:v 2 "$dir/wall-screen.jpg"
fi
# Google's page for the search the promo makes.
[ -f "$dir/serp.png" ] || swift tools/promo/serp.swift "liquid glass apple" "$dir/serp.png"

zig build promo -Doptimize=ReleaseFast
bin=zig-out/bin/nanolight-promo
size=$(du -sk zig-out/package/Nanolight.app 2>/dev/null | awk '{ printf "%.1f MB", $1 / 1024 }')
[ -n "$size" ] || { sh macos/package.sh >/dev/null; size=$(du -sk zig-out/package/Nanolight.app | awk '{ printf "%.1f MB", $1 / 1024 }'); }

enc="-c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -r 30"
# The 2D shots: raw frames to H.264.
for shot in hook panel stats end; do
    "$bin" --shot=$shot --wall="$dir/wall-1080.jpg" --serp="$dir/serp.png" --size="$size" |
        ffmpeg -loglevel error -y -f rawvideo -pix_fmt bgra -s 1920x1080 -r 30 -i - $enc "$dir/$shot.mp4"
done
# The laptop's display, then the laptop round it (Blender).
for shot in in out; do
    frames="$dir/screen-$shot"
    rm -rf "$frames" "$dir/laptop-$shot"
    mkdir -p "$frames" "$dir/laptop-$shot"
    "$bin" --shot=screen-$shot --wall="$dir/wall-screen.jpg" --serp="$dir/serp.png" |
        ffmpeg -loglevel error -y -f rawvideo -pix_fmt bgra -s 1838x1195 -r 30 -i - -start_number 1 "$frames/%04d.png"
    count=$(ls "$frames" | wc -l | tr -d ' ')
    "$blender" -b --factory-startup --python tools/promo/laptop.py -- "$model" "$PWD/$frames" "$PWD/$dir/laptop-$shot" $shot "$count" >/dev/null
    ffmpeg -loglevel error -y -framerate 30 -start_number 1 -i "$dir/laptop-$shot/%04d.png" $enc "$dir/laptop-$shot.mp4"
done

# The cut, in order, and the progress bar over it.
ffmpeg -loglevel error -y -i "$dir/hook.mp4" -i "$dir/laptop-in.mp4" -i "$dir/panel.mp4" -i "$dir/stats.mp4" -i "$dir/laptop-out.mp4" -i "$dir/end.mp4" \
    -f lavfi -i "color=c=0xF2B705:s=1920x10:r=30" -filter_complex \
    "[0][1][2][3][4][5]concat=n=6:v=1:a=0[v];[v][6]overlay=x='-W+W*t/31':y=H-10:shortest=1[p]" \
    -map "[p]" $enc "$dir/silent.mp4"

# The sound: a 120 BPM beat (kick, hat, bass), a whoosh at each cut, a
# thump on each card's beat, a tick for each key; all synthesised here.
kick="0.85*sin(2*PI*(45*mod(t,0.5)+9*(1-exp(-35*mod(t,0.5)))))*exp(-7*mod(t,0.5))"
hat="0.10*(2*random(0)-1)*exp(-45*mod(t+0.25,0.5))"
note="if(lt(mod(t,8),2),55,if(lt(mod(t,8),4),43.65,if(lt(mod(t,8),6),65.41,49)))"
bass="0.22*(sin(2*PI*$note*t)+0.35*sin(4*PI*$note*t))*(0.55+0.45*exp(-5*mod(t,0.5)))"
beat="aevalsrc=exprs='($kick+$hat+$bass)*0.7|($kick+$hat+$bass)*0.7':s=44100:d=31,afade=t=out:st=29.6:d=1.4"
tick="0.22*sin(2*PI*2600*t)*exp(-110*t)+0.16*sin(2*PI*1300*t)*exp(-70*t)"
thump="0.5*sin(2*PI*(60*t+6*(1-exp(-40*t))))*exp(-9*t)"
graph="$beat[m]"
mix="[m]"
n=1
ms() { awk -v s="$1" -v d="$2" 'BEGIN { v = (s + d) * 1000; if (v < 0) v = 0; printf "%d", v }'; }
while read -r kind at; do
    n=$((n + 1))
    case "$kind" in
    click) src="aevalsrc=exprs='$tick':d=0.08:s=44100"; at=$(ms "$at" 0) ;;
    hit) src="aevalsrc=exprs='$thump':d=0.4:s=44100"; at=$(ms "$at" 0) ;;
    cut) src="anoisesrc=d=0.45:c=pink:a=0.16:s=44100,highpass=f=500,lowpass=f=6000,afade=t=in:d=0.3,afade=t=out:st=0.3:d=0.15"; at=$(ms "$at" -0.3) ;;
    *) continue ;;
    esac
    graph="$graph;$src,aformat=channel_layouts=stereo,adelay=$at|$at[s$n]"
    mix="$mix[s$n]"
done <<CUES
$("$bin" --cues)
CUES
graph="$graph;${mix}amix=inputs=$n:normalize=0,alimiter=limit=0.9[a]"
ffmpeg -loglevel error -y -i "$dir/silent.mp4" -filter_complex "$graph" -map 0:v -map "[a]" \
    -c:v copy -c:a aac -b:a 192k -movflags +faststart -t 31 "$out"

# The README's preview: the same, smaller and silent.
gif="${out%.mp4}-preview.gif"
ffmpeg -loglevel error -y -i "$dir/silent.mp4" -vf "fps=12,scale=560:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" "$gif"
echo "$out"
