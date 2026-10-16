extends Control
## Small native UI name tag. World owns projection; this node owns its visual size.
## position + Vector2(size.x / 2, size.y) is the downward pointer's exact tip.

const FONT_SIZE: int = 13
const PADDING := Vector2(8, 3)
const TAIL_HEIGHT: float = 4.0
const MIN_WIDTH: float = 30.0
const MAX_WIDTH: float = 100.0
const BACKGROUND_OPACITY: float = 0.70
const ROLE_COLORS: Dictionary = {
	"local": Color("3B82C4"),
	"npc": Color("E8B646"),
	"opponent": Color("D9504C"),
}

static var _font: SystemFont
var label: Label
var role: String = "npc"
var display_text: String = ""
var _background := StyleBoxFlat.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "SimHei"])
	label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.focus_mode = Control.FOCUS_NONE
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(label)
	_background.corner_radius_top_left = 5
	_background.corner_radius_top_right = 5
	_background.corner_radius_bottom_left = 5
	_background.corner_radius_bottom_right = 5
	_background.shadow_color = Color(0.03, 0.10, 0.13, 0.2)
	_background.shadow_size = 2
	_background.shadow_offset = Vector2(0, 1)
	configure("", "npc")


func configure(text: String, identity_role: String) -> void:
	var next_role: String = identity_role if ROLE_COLORS.has(identity_role) else "npc"
	if text == display_text and role == next_role and size.y > 0.0:
		return
	display_text = text
	role = next_role
	label.text = text
	label.add_theme_color_override("font_color", Color("342819") if role == "npc" else Color.WHITE)
	_background.bg_color = ROLE_COLORS[role]
	_background.bg_color.a = BACKGROUND_OPACITY
	var text_width: float = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var body_height: float = ceilf(_font.get_height(FONT_SIZE)) + PADDING.y * 2.0
	size = Vector2(clampf(ceilf(text_width) + PADDING.x * 2.0, MIN_WIDTH, MAX_WIDTH), body_height + TAIL_HEIGHT)
	label.position = PADDING
	label.size = Vector2(size.x - PADDING.x * 2.0, body_height - PADDING.y * 2.0)
	queue_redraw()


func _draw() -> void:
	var body_height: float = size.y - TAIL_HEIGHT
	draw_style_box(_background, Rect2(Vector2.ZERO, Vector2(size.x, body_height)))
	var center: float = size.x * 0.5
	var tail := PackedVector2Array([
		Vector2(center - 4.0, body_height),
		Vector2(center + 4.0, body_height),
		Vector2(center, size.y),
	])
	draw_colored_polygon(tail, _background.bg_color)
