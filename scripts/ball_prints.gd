extends RefCounted
## Approved footprint masks, traced from the flat previews of the v3 artboard.
## Artwork is separate from the ball's role colour and can be replaced later.

const ANIMALS: Array[String] = ["rabbit", "bear", "pig", "cat", "dog", "fox", "panda", "raccoon"]
const INKS: Dictionary = {
	"rabbit": "#173E69", "bear": "#A86663", "pig": "#52898F", "cat": "#5F8E69",
	"dog": "#A78337", "fox": "#88709E", "panda": "#514A50", "raccoon": "#676E8C",
}
static var _masks: Dictionary = {}

static func mask_for(animal: String) -> Texture2D:
	var kind: String = animal if animal in ANIMALS else "rabbit"
	if not _masks.has(kind):
		_masks[kind] = load("res://assets/ball-prints/%s.svg" % kind) as Texture2D
	return _masks[kind] as Texture2D

static func ink_for(animal: String, base: Color) -> Color:
	# A player's dark ball keeps dark ink; light NPCs use the approved species
	# ink colours. The surrounding sphere colour remains the role identifier.
	if base.get_luminance() < 0.3:
		return base
	return Color(str(INKS.get(animal, "#173E69")))
