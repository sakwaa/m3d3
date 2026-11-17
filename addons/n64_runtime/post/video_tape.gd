@tool
class_name VideoTape
extends Resource
## A vintage studio-video recording look (N64VideoOut, after the looks / combiners, before
## the HUD and the N64 dither): the chain a 90s TV studio picture went through, not the TV
## it was watched on (no scanlines, curvature, masks). Each stage is what's in the footage:
##  - Lens: a studio zoom lens's shallow focus - far things go soft, smoothly (defocus, not
##    blur or pixels); near detail stays crisp.
##  - Camera: highlight bloom (tube / CCD flare: bright whites glow into what's next to
##    them) and aperture correction (the camera's sharpening: bright halos round dark edges).
##  - Tape: colour carried at a fraction of the brightness's detail (smeared along the line,
##    a little late), a knee rolling off the highlights, the picture's punchy primaries, faint
##    tape noise.
## Amounts are at 480 lines (scaled to the render size).

## The whole look (0 = off).
@export_range(0.0, 1.0, 0.01) var strength := 1.0

@export_group("Lens")
## How soft the distance gets (0 = all sharp).
@export_range(0.0, 1.0, 0.01) var defocus := 0.6
## Sharp up to here...
@export_range(0.0, 200.0, 0.5, "suffix:m") var focus_near := 8.0
## ...fully soft from here.
@export_range(0.0, 500.0, 0.5, "suffix:m") var focus_far := 45.0

@export_group("Camera")
## Highlight glow (0 = none).
@export_range(0.0, 2.0, 0.01) var bloom := 0.35
## Brightness (display 0..1) above which things glow.
@export_range(0.0, 1.0, 0.01) var bloom_threshold := 0.78
## The glow trails along the line (pixels; tape saturating on bright signal).
@export_range(0.0, 24.0, 0.5) var bloom_smear := 6.0
@export var bloom_tint := Color(1.0, 0.97, 0.9)
## Aperture correction: edge halos (0 = none, 1 = broadcast camera).
@export_range(0.0, 2.0, 0.01) var sharpen := 0.6
## How wide the halos are (pixels).
@export_range(0.5, 4.0, 0.1) var sharpen_radius := 1.6

@export_group("Tape")
## Colour detail: chroma smeared over this many pixels along the line (luma stays sharp).
@export_range(0.0, 16.0, 0.5) var chroma_blur := 5.0
## Colour lags the brightness by this many pixels.
@export_range(-4.0, 4.0, 0.1) var chroma_shift := 1.2
## Saturation (1 = as rendered).
@export_range(0.0, 2.0, 0.01) var saturation := 1.18
## Highlights roll off above this (display 0..1; 1 = no knee).
@export_range(0.5, 1.0, 0.01) var knee := 0.82
## Blacks lifted (the tape's pedestal).
@export_range(0.0, 0.2, 0.005) var black_lift := 0.025
## Warmer (+) / cooler (-).
@export_range(-0.2, 0.2, 0.005) var warmth := 0.02
## Brightness noise.
@export_range(0.0, 0.1, 0.001) var luma_noise := 0.012
## Colour noise (tape chroma, worst in saturated reds).
@export_range(0.0, 0.2, 0.001) var chroma_noise := 0.02


## Push constants for n64_video_tape.glsl (after size, frame, projection).
func params(lines: float) -> Array:
	var k := lines / 480.0
	var t := bloom_tint
	return [strength, defocus, focus_near, maxf(focus_far, focus_near + 0.1),
		bloom, bloom_threshold, bloom_smear * k, sharpen,
		sharpen_radius * k, chroma_blur * k, chroma_shift * k, saturation,
		knee, black_lift, warmth, luma_noise,
		chroma_noise, t.r, t.g, t.b]


func uses_depth() -> bool:
	return defocus > 0.0 and strength > 0.0
