@tool
class_name GradeReference
extends Resource
## A reference for one grade category (TextureGrade.references): a region of a screenshot
## (another game, a painting, a photo) showing that material as it should look. Match
## References builds the category's LUT from it: the category's colours turned to the
## reference's hue, saturation and (partly) brightness, the textures' own detail kept.

## Grade category (texture folder, or a texture's `grade_as`).
@export var category: StringName
## The reference picture (res:// or any file).
@export_global_file("*.png", "*.jpg", "*.jpeg", "*.webp") var image_path := ""
## The part showing the material, as a share of the picture (0..1; zero size = all of it).
@export var region := Rect2()
## How far towards the reference (1 = all the way).
@export_range(0.0, 1.0, 0.05) var amount := 0.9
## How much of the reference's brightness to take: screenshots include their lighting, so
## usually only part of it.
@export_range(0.0, 1.0, 0.05) var lightness := 0.4
