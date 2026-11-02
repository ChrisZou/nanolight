#!/bin/sh
# The promo (src/promo.zig): 30 seconds, 1920x1080 at 60 fps, to
# docs/promo.mp4 and a silent preview, docs/promo-preview.gif. macOS, with
# ffmpeg, Blender (/Applications/Blender.app, or $BLENDER) and Swift.
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
[ -f "$dir/serp.png" ] || swift tools/promo/serp.swift "liquid glass apple" "$dir/serp.png"

zig build promo -Doptimize=ReleaseFast
bin=zig-out/bin/nanolight-promo
# Grain costs bits: a cap keeps the video under GitHub's file limits.
enc="-c:v libx264 -preset slow -crf 18 -tune film -maxrate 12M -bufsize 24M -pix_fmt yuv420p -r 60"

# The laptop: its display's frames (the desktop, then ⌘Space), then Blender
# round them, pushing in until the display fills the frame.
frames="$dir/screen"
rm -rf "$frames" "$dir/laptop"
mkdir -p "$frames" "$dir/laptop"
"$bin" --shot=screen --wall="$dir/wall-screen.jpg" |
    ffmpeg -loglevel error -y -f rawvideo -pix_fmt bgra -s 1838x1195 -r 60 -i - -start_number 1 "$frames/%04d.png"
count=$(ls "$frames" | wc -l | tr -d ' ')
"$blender" -b --factory-startup --python tools/promo/laptop.py -- "$model" "$PWD/$frames" "$PWD/$dir/laptop" in "$count" >/dev/null
ffmpeg -loglevel error -y -framerate 60 -start_number 1 -i "$dir/laptop/%04d.png" $enc "$dir/laptop.mp4"

# The rest, through the camera.
"$bin" --shot=main --wall="$dir/wall-1080.jpg" --serp="$dir/serp.png" |
    ffmpeg -loglevel error -y -f rawvideo -pix_fmt bgra -s 1920x1080 -r 60 -i - $enc "$dir/main.mp4"

# The laptop dissolves into the panel; the end fades to black.
ffmpeg -loglevel error -y -i "$dir/laptop.mp4" -i "$dir/main.mp4" -filter_complex \
    "[0][1]xfade=transition=fade:duration=0.2:offset=3.2,fade=t=out:st=29.4:d=0.6[v]" \
    -map "[v]" $enc -t 30 "$dir/silent.mp4"

# The sound, all synthesised: a soft pad at 86 BPM (Fmaj7, Am7, Dm7,
# Bbmaj7, a chord a bar) over room tone, a key's tick for each key, a glass
# tick as the panel opens, a soft lift for each loupe, a bell for the name.
bar=2.7907
C="mod(floor(t/$bar),4)"
pick() { echo "if(eq($C,0),$1,if(eq($C,1),$2,if(eq($C,2),$3,$4)))"; }
env="(1-exp(-2.2*mod(t,$bar)))*min(1,($bar-mod(t,$bar))/0.3)"
voices=""
for v in "174.61 220 146.83 116.54" "220 261.63 174.61 174.61" "261.63 329.63 220 220" "329.63 392 261.63 293.66"; do
    set -- $v
    f=$(pick "$1" "$2" "$3" "$4")
    voices="$voices+0.055*(sin(2*PI*$f*t)+0.5*sin(2*PI*$f*1.004*t)+0.12*sin(4*PI*$f*t))"
done
root=$(pick 87.31 110 73.42 58.27)
pad="($voices+0.09*sin(2*PI*$root*t))*$env"
graph="aevalsrc=exprs='$pad|$pad':s=48000:d=30,lowpass=f=1500,aecho=0.8:0.8:110|230|390:0.32|0.22|0.12,afade=t=in:st=0.6:d=1.4,afade=t=out:st=28.6:d=1.4[pad];anoisesrc=d=30:c=pink:a=0.006:s=48000,lowpass=f=500,aformat=channel_layouts=stereo[room]"
mix="[pad][room]"
n=2
k=0
ms() { awk -v s="$1" 'BEGIN { v = s * 1000; if (v < 0) v = 0; printf "%d", v }'; }
while read -r kind at; do
    case "$kind" in
    key) k=$((k + 1)); f=$((2300 + (k % 3) * 190)); src="aevalsrc=exprs='0.16*sin(2*PI*$f*t)*exp(-115*t)+0.11*sin(2*PI*$((f / 2))*t)*exp(-75*t)':d=0.08:s=48000" ;;
    tab) src="aevalsrc=exprs='0.2*sin(2*PI*3300*t)*exp(-80*t)+0.12*sin(2*PI*1650*t)*exp(-50*t)':d=0.12:s=48000" ;;
    enter) src="aevalsrc=exprs='0.2*sin(2*PI*1400*t)*exp(-60*t)+0.14*sin(2*PI*700*t)*exp(-40*t)':d=0.15:s=48000" ;;
    open) src="aevalsrc=exprs='0.14*sin(2*PI*1760*t)*exp(-14*t)+0.09*sin(2*PI*2637*t)*exp(-20*t)+0.05*sin(2*PI*3520*t)*exp(-26*t)':d=0.5:s=48000" ;;
    lift) src="aevalsrc=exprs='0.13*sin(2*PI*(200*t+110*t*t))*(1-exp(-30*t))*exp(-6*t)':d=0.6:s=48000" ;;
    page) src="aevalsrc=exprs='0.07*(sin(2*PI*523.25*t)+sin(2*PI*783.99*t)+0.6*sin(2*PI*1046.5*t))*(1-exp(-20*t))*exp(-3.5*t)':d=1.2:s=48000" ;;
    cross) src="anoisesrc=d=0.5:c=pink:a=0.09:s=48000,highpass=f=700,lowpass=f=5000,afade=t=in:d=0.3,afade=t=out:st=0.3:d=0.2"; at=$(awk -v a="$at" 'BEGIN { print a - 0.3 }') ;;
    end) src="aevalsrc=exprs='0.16*sin(2*PI*87.31*t)*(1-exp(-6*t))*exp(-1.2*t)+0.05*sin(2*PI*174.61*t)*(1-exp(-6*t))*exp(-1.6*t)':d=3:s=48000" ;;
    name) src="aevalsrc=exprs='0.12*sin(2*PI*880*t)*exp(-2.6*t)+0.07*sin(2*PI*1318.5*t)*exp(-3.4*t)+0.04*sin(2*PI*1760*t)*exp(-4.5*t)':d=2.2:s=48000" ;;
    *) continue ;;
    esac
    n=$((n + 1))
    d=$(ms "$at")
    graph="$graph;$src,aformat=channel_layouts=stereo,adelay=$d|$d[s$n]"
    mix="$mix[s$n]"
done <<CUES
$("$bin" --cues)
CUES
graph="$graph;${mix}amix=inputs=$n:normalize=0,alimiter=limit=0.89,loudnorm=I=-16:TP=-1.5:LRA=11[a]"
ffmpeg -loglevel error -y -i "$dir/silent.mp4" -filter_complex "$graph" -map 0:v -map "[a]" \
    -c:v copy -c:a aac -b:a 192k -ar 48000 -movflags +faststart -t 30 "$out"

# The README's preview: the same, smaller and silent.
gif="${out%.mp4}-preview.gif"
ffmpeg -loglevel error -y -i "$dir/silent.mp4" -vf "fps=12,hqdn3d=4:4:6:6,scale=560:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" "$gif"
echo "$out"
