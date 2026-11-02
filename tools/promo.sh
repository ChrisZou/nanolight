#!/bin/sh
# The promo (src/promo.zig): 47 seconds, 1920x1080 at 60 fps, to
# docs/promo.mp4 and a silent preview, docs/promo-preview.gif. macOS, with
# ffmpeg, Blender (/Applications/Blender.app, or $BLENDER) and Swift.
#
#     tools/promo.sh [out.mp4]
#
# Fetched as it runs, into zig-out/promo, and never kept in the repository:
# Apple's MacBook Air AR model from apple.com (its display shows the
# promo's frames; its baked wallpaper is the desktop), Dell's XPS 13 AR
# model from dell.com (its display shows Windows), Google's results page
# for the search shown, captured in an offscreen WebKit view, and Hacker
# News's icon from raycast/extensions. The Windows and Linux recordings
# are made beforehand (docs/promo.md) and put in zig-out/promo.
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
[ -f "$dir/hn-icon.png" ] || curl -sfL -o "$dir/hn-icon.png" \
    https://raw.githubusercontent.com/raycast/extensions/main/extensions/hacker-news/assets/icon.png
for r in rec-win rec-linux; do
    [ -f "$dir/$r.mp4" ] || { echo "tools/promo.sh: $dir/$r.mp4 is missing (docs/promo.md says how it is recorded)" >&2; exit 1; }
done
xps="$dir/dell-xps-13.usdz"
[ -f "$xps" ] || curl -sfL -o "$xps" https://content.hmxmedia.com/dell-dx13260-laptop-AR/usdz/dell-dx13260-laptop-AR.usdz
total=47

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
"$bin" --shot=main --wall="$dir/wall-1080.jpg" --serp="$dir/serp.png" --hn-icon="$dir/hn-icon.png" |
    ffmpeg -loglevel error -y -f rawvideo -pix_fmt bgra -s 1920x1080 -r 60 -i - $enc "$dir/main.mp4"

# The pivot. The MacBook pulls back from its display (the panel open on
# it), the camera pans across to Dell's XPS 13, whose display shows
# Nanolight on Windows, and comes round to it.
rm -rf "$dir/mac-screen" "$dir/mac-out" "$dir/xps-screen" "$dir/xps-in"
mkdir -p "$dir/mac-screen" "$dir/mac-out" "$dir/xps-screen" "$dir/xps-in"
last="$PWD/$frames/$(printf %04d "$count").png"
for i in $(seq 1 90); do ln -sf "$last" "$dir/mac-screen/$(printf %04d "$i").png"; done
"$blender" -b --factory-startup --python tools/promo/laptop.py -- "$model" "$PWD/$dir/mac-screen" "$PWD/$dir/mac-out" out 90 >/dev/null
ffmpeg -loglevel error -y -framerate 60 -start_number 1 -i "$dir/mac-out/%04d.png" $enc "$dir/mac-out.mp4"
# The recording is 4:3; the XPS's display 16:10: its top, where the panel is.
ffmpeg -loglevel error -y -ss 0.5 -t 2.6 -i "$dir/rec-win.mp4" -vf "fps=60,scale=1600:1200:flags=lanczos,crop=1600:1000:0:30" \
    -start_number 1 "$dir/xps-screen/%04d.png"
xcount=$(ls "$dir/xps-screen" | wc -l | tr -d ' ')
"$blender" -b --factory-startup --python tools/promo/laptop.py -- "$xps" "$PWD/$dir/xps-screen" "$PWD/$dir/xps-in" in "$xcount" >/dev/null
ffmpeg -loglevel error -y -framerate 60 -start_number 1 -i "$dir/xps-in/%04d.png" $enc -t 2.6 "$dir/xps-in.mp4"

# The recordings, close on the panel, a little faster than they were
# typed, each with its label (the panel's own labels' look).
swift tools/promo/caption.swift "Now on Windows" "Ctrl Space" "$dir/cap-win.png"
swift tools/promo/caption.swift "And Linux" "Ctrl Space" "$dir/cap-linux.png"
# recording, from, seconds, speed, crop's top, label, length, out
close() {
    ffmpeg -loglevel error -y -ss "$2" -t "$3" -i "$dir/$1.mp4" -loop 1 -i "$6" -filter_complex \
        "[0]setpts=(PTS-STARTPTS)/$4,fps=60,crop=960:540:32:$5,scale=1920:1080:flags=lanczos,unsharp=5:5:0.5,format=yuv420p[v];[1]format=rgba,fade=t=in:st=0.25:d=0.3:alpha=1[c];[v][c]overlay=shortest=1" \
        $enc -t "$7" "$8"
}
close rec-win 11 7.5 1.5 0 "$dir/cap-win.png" 5.0 "$dir/win.mp4"
close rec-linux 22.5 10.5 1.288 40 "$dir/cap-linux.png" 8.15 "$dir/linux.mp4"
n="fps=60,settb=AVTB,format=yuv420p"
ffmpeg -loglevel error -y -i "$dir/mac-out.mp4" -i "$dir/xps-in.mp4" -i "$dir/win.mp4" -i "$dir/linux.mp4" -filter_complex \
    "[0]$n[a];[1]$n[b];[2]$n[c];[3]$n[d];[a][b]xfade=transition=smoothleft:duration=0.4:offset=1.1[ab];[ab][c]xfade=transition=fade:duration=0.25:offset=3.45[abc];[abc][d]xfade=transition=fade:duration=0.25:offset=8.2[v]" \
    -map "[v]" $enc -t 16.1 "$dir/pc.mp4"

# The Mac: the laptop dissolves into the panel; at 26.3 s the pivot and
# the PCs; at 42.4 s the end (the main shot's), which fades to black.
ffmpeg -loglevel error -y -i "$dir/laptop.mp4" -i "$dir/main.mp4" -i "$dir/pc.mp4" -filter_complex \
    "[0]$n[l];[1]$n,split[m1][m2];[2]$n[p];[l][m1]xfade=transition=fade:duration=0.2:offset=3.2,trim=0:26.5,setpts=PTS-STARTPTS[mac];[m2]trim=start=38.9,setpts=PTS-STARTPTS[end];[mac][p]xfade=transition=fade:duration=0.2:offset=26.3[mp];[mp][end]xfade=transition=fade:duration=0.3:offset=42.1,fade=t=out:st=46.4:d=0.6[v]" \
    -map "[v]" $enc -t $total "$dir/silent.mp4"

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
graph="aevalsrc=exprs='$pad|$pad':s=48000:d=$total,lowpass=f=1500,aecho=0.8:0.8:110|230|390:0.32|0.22|0.12,afade=t=in:st=0.6:d=1.4,afade=t=out:st=$((total - 2)).6:d=1.4[pad];anoisesrc=d=$total:c=pink:a=0.006:s=48000,lowpass=f=500,aformat=channel_layouts=stereo[room]"
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
cross 27.6
open 29.8
open 34.55
CUES
graph="$graph;${mix}amix=inputs=$n:normalize=0,alimiter=limit=0.89,loudnorm=I=-16:TP=-1.5:LRA=11[a]"
ffmpeg -loglevel error -y -i "$dir/silent.mp4" -filter_complex "$graph" -map 0:v -map "[a]" \
    -c:v copy -c:a aac -b:a 192k -ar 48000 -movflags +faststart -t $total "$out"

# The README's preview: the same, smaller and silent.
gif="${out%.mp4}-preview.gif"
ffmpeg -loglevel error -y -i "$dir/silent.mp4" -vf "fps=10,hqdn3d=4:4:6:6,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" "$gif"
echo "$out"
