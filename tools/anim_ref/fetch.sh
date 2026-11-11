#!/bin/zsh
# Downloads a section of a video (best quality and frame rate up to 1080p) and extracts its
# frames at the native rate.
#   fetch.sh NAME URL START END     (times in seconds or mm:ss)
# -> work/NAME/clip.mp4, work/NAME/frames/f_0001.png ... (work/ is scratch, not shipped)
set -e
cd "${0:A:h}"
export PATH=/opt/homebrew/bin:$PATH
name=$1 url=$2 start=$3 end=$4
[ -n "$end" ] || { echo "usage: fetch.sh NAME URL START END"; exit 1; }
out=work/$name
mkdir -p $out/frames
# Prefer the highest frame rate, then resolution (60 fps beats 30 for timing).
yt-dlp -q -S "fps,res:1080" -f "bv*[height<=1080]" --download-sections "*$start-$end" \
	--force-keyframes-at-cuts -o "$out/clip.%(ext)s" "$url"
clip=$(ls $out/clip.* | head -1)
ffmpeg -v error -y -i "$clip" "$out/frames/f_%04d.png"
fps=$(ffprobe -v error -select_streams v -show_entries stream=r_frame_rate -of csv=p=0 "$clip")
echo "$clip: $(ls $out/frames | wc -l | tr -d ' ') frames at $fps fps -> $out/frames"
