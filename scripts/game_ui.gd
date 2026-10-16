extends CanvasLayer

signal action(name: String, payload: Dictionary)
signal selection_changed(selection: Dictionary)

const INK: Color = Color("244e5a")
const MUTED: Color = Color("6d8c85")
const CREAM: Color = Color("fff9e9")
const MINT: Color = Color("399480")
const CORAL: Color = Color("ee9677")
const WardrobeStore = preload("res://scripts/wardrobe_store.gd")
const BallPrints = preload("res://scripts/ball_prints.gd")
const AnimalVisual = preload("res://scripts/animal_visual.gd")
const ANIMALS: Dictionary = WardrobeStore.ANIMALS
const EFFECTS: Dictionary = {"grow":"球变大", "shrink":"球变小", "speedUp":"加速", "speedDown":"减速", "wind":"侧风"}
# Coordinated with the gameplay camera: island and surrounding sea stay here.
const MATCH_WORLD_SAFE_RECT: Rect2 = Rect2(310, 110, 980, 665)
const CAMERA_CONTROL_RANGES: Dictionary = {
	"match": {"height": Vector2(8, 55), "distance": Vector2(8, 55), "fov": Vector2(25, 75), "yaw": Vector2(-180, 180)},
	"victory": {"height": Vector2(2, 14), "distance": Vector2(3, 20), "fov": Vector2(25, 75), "yaw": Vector2(-180, 180)}
}

class PatternPreview extends Control:
	var style: Dictionary = {}
	var category: String = "ball"
	var animal: String = "rabbit"
	var picture: Texture2D
	var picture_path: String = ""
	var portrait: Texture2D
	var live_character_preview: bool = false
	var _live_viewport: SubViewport
	var _live_world: Node3D
	var _live_camera: Camera3D
	var _live_visual: Node3D
	var _live_animal: String = ""
	var _live_image: String = ""
	var _live_update_pending: bool = false
	static var portraits: Dictionary = {}
	func configure(value: Dictionary, kind: String, animal_kind: String = "rabbit") -> void:
		style = value
		category = kind
		animal = animal_kind
		if category == "character":
			if not portraits.has(animal):
				var portrait_path: String = "res://assets/animals/portraits/%s.png" % animal
				portraits[animal] = load(portrait_path) as Texture2D if ResourceLoader.exists(portrait_path) else null
			portrait = portraits[animal] as Texture2D
		# Saved ball colours stay intact; their thumbnail uses the same species
		# footprint mask as the rolling ball. Uploaded character badges remain.
		var path: String = str(style.get("image", "")) if category == "character" else ""
		if path != picture_path:
			picture = null
			picture_path = path
			if not path.is_empty() and FileAccess.file_exists(path):
				var loaded: Image = Image.new()
				if loaded.load(path) == OK:
					var side: int = mini(loaded.get_width(), loaded.get_height())
					var origin: Vector2i = Vector2i((loaded.get_width() - side) / 2, (loaded.get_height() - side) / 2)
					loaded = loaded.get_region(Rect2i(origin, Vector2i(side, side)))
					loaded.convert(Image.FORMAT_RGBA8)
					loaded.resize(128, 128, Image.INTERPOLATE_LANCZOS)
					for y: int in range(128):
						for x: int in range(128):
							var pixel: Color = loaded.get_pixel(x, y)
							pixel.a *= clampf(64.0 - Vector2(float(x) + 0.5 - 64.0, float(y) + 0.5 - 64.0).length(), 0.0, 1.0)
							loaded.set_pixel(x, y, pixel)
					picture = ImageTexture.create_from_image(loaded)
		if live_character_preview and category == "character" and not _live_update_pending:
			_live_update_pending = true
			call_deferred("_refresh_live_preview")
		queue_redraw()
	func _build_live_viewport() -> void:
		_live_viewport = SubViewport.new()
		_live_viewport.name = "CharacterDraftViewport"
		_live_viewport.size = Vector2i(384, 384)
		_live_viewport.transparent_bg = true
		_live_viewport.own_world_3d = true
		_live_viewport.msaa_3d = Viewport.MSAA_4X
		_live_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(_live_viewport)
		_live_world = Node3D.new()
		_live_viewport.add_child(_live_world)
		var sky: WorldEnvironment = WorldEnvironment.new()
		var environment: Environment = Environment.new()
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color.TRANSPARENT
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = Color("f5fff4")
		environment.ambient_light_energy = 0.5
		environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		sky.environment = environment
		_live_world.add_child(sky)
		var key: DirectionalLight3D = DirectionalLight3D.new()
		key.rotation_degrees = Vector3(-30, -25, 0)
		key.light_color = Color("fff4e2")
		key.light_energy = 0.9
		_live_world.add_child(key)
		var fill: DirectionalLight3D = DirectionalLight3D.new()
		fill.rotation_degrees = Vector3(-15, 145, 0)
		fill.light_color = Color("d9f6ff")
		fill.light_energy = 0.35
		_live_world.add_child(fill)
		_live_camera = Camera3D.new()
		_live_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_live_camera.current = true
		_live_world.add_child(_live_camera)
	func _refresh_live_preview() -> void:
		_live_update_pending = false
		if not is_inside_tree() or category != "character":
			return
		if not is_instance_valid(_live_viewport):
			_build_live_viewport()
		var draft: Dictionary = style.duplicate(true)
		draft["id"] = "remix-character-draft"
		var image_path: String = str(draft.get("image", ""))
		if not is_instance_valid(_live_visual):
			_live_visual = AnimalVisual.new()
			_live_world.add_child(_live_visual)
		if _live_animal != animal or _live_image != image_path:
			_live_visual.configure(animal, draft, {})
			_live_visual.ball_root.hide()
			_live_visual.name_label.hide()
			_live_visual.effect_label.hide()
			_live_visual.local_ring.hide()
			_live_visual.effect_ring.hide()
			_live_visual.set_motion_paused(true)
			for player: AnimationPlayer in _live_visual.animation_players:
				player.seek(0.12, true)
				player.advance(0.0)
			_live_animal = animal
			_live_image = image_path
		else:
			# Colour drags reuse the one model; no GLB reload or new viewport.
			_live_visual.call("_apply_character_style", draft)
		await get_tree().process_frame
		if not is_inside_tree():
			return
		var bounds: AABB = AABB()
		var first_mesh: bool = true
		for mesh: MeshInstance3D in _live_visual.model_root.find_children("*", "MeshInstance3D", true, false):
			if not mesh.is_visible_in_tree() or mesh.mesh == null:
				continue
			var current: AABB = mesh.global_transform * mesh.get_aabb()
			bounds = current if first_mesh else bounds.merge(current)
			first_mesh = false
		var center: Vector3 = bounds.get_center()
		_live_camera.size = maxf(bounds.size.y, bounds.size.x) * 1.13
		_live_camera.position = center + Vector3(0, 0.035, 6)
		_live_camera.look_at(center)
		_live_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		queue_redraw()
		await RenderingServer.frame_post_draw
		if is_instance_valid(_live_viewport):
			_live_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	func _draw() -> void:
		var fallback: Array = ["#173E69", "#173E69", "#173E69"] if category == "ball" else ["#52bda7", "#fff3d7", "#f38b6c"]
		var colors: Array = style.get("colors", fallback)
		var first: String = str(colors[0]) if not colors.is_empty() else str(fallback[0])
		var c1: Color = Color.from_string(first, Color.WHITE)
		var center: Vector2 = size * Vector2(0.5, 0.54)
		var radius: float = minf(size.x * 0.36, size.y * 0.36)
		if category == "ball":
			draw_circle(center + Vector2(0, radius * 0.83), radius * 0.82, Color(INK, 0.09))
			draw_circle(center, radius, c1)
			var medallion_radius: float = radius * 0.8
			draw_circle(center, medallion_radius, Color("faf7ef"))
			var mask: Texture2D = BallPrints.mask_for(animal)
			if mask != null:
				draw_texture_rect(mask, Rect2(center - Vector2.ONE * medallion_radius, Vector2.ONE * medallion_radius * 2.0), false, BallPrints.ink_for(animal, c1))
			draw_arc(center, radius, 0, TAU, 80, Color(INK, 0.12), 2.0, true)
			draw_circle(center + Vector2(-0.44, -0.43) * radius, radius * 0.075, Color(1, 1, 1, 0.24))
		else:
			var portrait_side: float = minf(size.x, size.y) * 0.96
			var portrait_rect: Rect2 = Rect2((size - Vector2.ONE * portrait_side) * 0.5, Vector2.ONE * portrait_side)
			if live_character_preview and is_instance_valid(_live_viewport):
				draw_texture_rect(_live_viewport.get_texture(), portrait_rect, false)
			elif portrait != null:
				draw_texture_rect(portrait, portrait_rect, false)
			if picture != null and not live_character_preview:
				var badge_side: float = portrait_side * 0.18
				draw_texture_rect(picture, Rect2(portrait_rect.position + portrait_rect.size * Vector2(0.5, 0.66) - Vector2.ONE * badge_side * 0.5, Vector2.ONE * badge_side), false)

var store: RefCounted
var root: Control
var menu: Control
var preview_drag_area: Control
var preview_drag_hint: Label
var _preview_drag_enabled: bool = true
var _preview_dragging: bool = false
var hud: Control
var modal: Control
var modal_panel: PanelContainer
var modal_content: VBoxContainer
var file_dialog: FileDialog
var points_label: Label
var brand_label: Label
var timer_label: Label
var countdown_overlay: Control
var countdown_label: Label
var countdown_active: bool = false
var countdown_remaining: float = 0.0
var effect_buttons: Dictionary = {}
var wind_active: bool = false
var wind_remaining: float = 0.0
var _wind_idle_styles: Dictionary = {}
var _wind_active_styles: Dictionary = {}
var spectator_panel: PanelContainer
var spectator_restart: Button
var result_restart: Button
var result_overlay: Control
var result_title: Label
var room_chip: Label
var preview_label: Label
var pause_button: Button
var pause_overlay: Control
var camera_button: Button
var window_mode_button: Button
var camera_panel: PanelContainer
var camera_controls: Dictionary = {"match": {}, "victory": {}}
var _camera_readouts: Dictionary = {"match": {}, "victory": {}}
var _camera_settings: Dictionary = {}
var _camera_tabs: TabContainer
var _camera_preview_actions: HBoxContainer
var solo_button: Button
var room_status: Label
var room_start: Button
var color_buttons: Array[ColorPickerButton] = []
var animal_buttons: Dictionary = {}
var mode: String = "solo"
var screen: String = "menu"
var local_id: String = "player"
var snapshot: Dictionary = {}
var room_state: Dictionary = {}
var paused: bool = false
var remix_category: String = "character"
var draft_colors: Array = ["#f4e5d2", "#5bbdac", "#fc8b70"]
var draft_image: String = ""
var draft_preview: PatternPreview
var modal_kind: String = ""
var toast_label: Label
var toast_time: float = 0.0

func setup(profile: RefCounted) -> void:
	store = profile
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 10
	root = Control.new()
	root.name = "GameUI"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.theme = _make_theme()
	_build_header()
	_build_menu()
	_build_hud()
	_build_spectator()
	_build_modal()
	_build_result_overlay()
	_build_pause_overlay()
	_build_camera_panel()
	_build_file_dialog()
	toast_label = _label("", 15, INK)
	toast_label.name = "Toast"
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	toast_label.position = Vector2(-285, 26)
	toast_label.size = Vector2(570, 42)
	toast_label.clip_text = true
	toast_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	toast_label.add_theme_stylebox_override("normal", _box(Color("fff9e9ed"), 12, 10))
	toast_label.visible = false
	root.add_child(toast_label)
	get_window().focus_exited.connect(_end_preview_drag)
	show_menu()
	_refresh_selection()

func _make_theme() -> Theme:
	var theme: Theme = Theme.new()
	var font: SystemFont = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "SimHei"])
	theme.default_font = font
	theme.default_font_size = 18
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", INK)
	theme.set_color("font_pressed_color", "Button", CREAM)
	theme.set_color("font_disabled_color", "Button", Color("93a69a"))
	theme.set_stylebox("normal", "Button", _box(Color("fff9e9f2"), 14, 15))
	theme.set_stylebox("hover", "Button", _box(Color("e6f1df"), 14, 15))
	theme.set_stylebox("pressed", "Button", _box(MINT, 14, 15))
	theme.set_stylebox("disabled", "Button", _box(Color("e7e9dd"), 14, 15))
	theme.set_stylebox("focus", "Button", _outline_box())
	theme.set_stylebox("normal", "LineEdit", _box(Color("fffef5"), 12, 14))
	theme.set_stylebox("focus", "LineEdit", _box(Color("edf4e7"), 12, 14))
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_color("font_placeholder_color", "LineEdit", MUTED)
	theme.set_stylebox("panel", "PopupMenu", _box(CREAM, 12, 10))
	theme.set_color("font_color", "PopupMenu", INK)
	theme.set_constant("separation", "VBoxContainer", 14)
	theme.set_constant("separation", "HBoxContainer", 12)
	return theme

func _box(color: Color, radius: int = 18, margin: int = 20) -> StyleBoxFlat:
	var box: StyleBoxFlat = StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.content_margin_left = margin
	box.content_margin_right = margin
	box.content_margin_top = margin
	box.content_margin_bottom = margin
	box.border_color = Color("ffffff80")
	box.set_border_width_all(1)
	box.shadow_color = Color(0.07, 0.22, 0.24, 0.08)
	box.shadow_size = 12
	box.shadow_offset = Vector2(0, 5)
	return box

func _outline_box() -> StyleBoxFlat:
	var box: StyleBoxFlat = _box(Color(0, 0, 0, 0), 14, 0)
	box.border_color = CORAL
	box.set_border_width_all(2)
	return box

func _label(text: String, font_size: int = 18, color: Color = INK) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _button(text: String, callback: Callable, node_name: String = "") -> Button:
	var button: Button = Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.custom_minimum_size.y = 48
	if not node_name.is_empty():
		button.name = node_name
	button.pressed.connect(callback)
	return button

func _primary(button: Button, color: Color = MINT) -> void:
	button.add_theme_stylebox_override("normal", _box(color, 15, 17))
	button.add_theme_stylebox_override("hover", _box(color.lightened(0.08), 15, 17))
	button.add_theme_stylebox_override("pressed", _box(color.darkened(0.12), 15, 17))
	button.add_theme_color_override("font_color", CREAM)
	button.add_theme_color_override("font_hover_color", CREAM)
	button.add_theme_font_size_override("font_size", 22)

func _compact_button(button: Button, height: float = 36.0) -> void:
	button.custom_minimum_size.y = height
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_stylebox_override("normal", _box(Color("fff9e9ed"), 10, 8))
	button.add_theme_stylebox_override("hover", _box(Color("e6f1df"), 10, 8))
	button.add_theme_stylebox_override("pressed", _box(MINT, 10, 8))

func _build_header() -> void:
	brand_label = _label("", 17, INK)
	brand_label.position = Vector2(48, 29)
	brand_label.hide()
	root.add_child(brand_label)
	pause_button = _button("暂停", _toggle_pause, "Pause")
	_compact_button(pause_button)
	pause_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	pause_button.position = Vector2(-132, 24)
	pause_button.size = Vector2(108, 42)
	root.add_child(pause_button)
	camera_button = _button("镜头  F2", _toggle_camera_panel, "CameraToggle")
	_compact_button(camera_button, 42)
	camera_button.toggle_mode = true
	camera_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	camera_button.position = Vector2(-268, 24)
	camera_button.size = Vector2(124, 42)
	camera_button.z_index = 30
	root.add_child(camera_button)
	var window_manager: Node = get_node("/root/WindowManager")
	window_mode_button = _button("", Callable(window_manager, "toggle_fullscreen"), "WindowModeToggle")
	_compact_button(window_mode_button, 42)
	window_mode_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	window_mode_button.position = Vector2(-418, 24)
	window_mode_button.size = Vector2(138, 42)
	window_mode_button.z_index = 30
	root.add_child(window_mode_button)
	window_manager.connect("display_mode_changed", _refresh_window_mode)
	_refresh_window_mode(bool(window_manager.is_fullscreen()))
	room_chip = _label("", 12, INK)
	room_chip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	room_chip.position = Vector2(-550, 76)
	room_chip.size = Vector2(526, 26)
	room_chip.clip_text = true
	room_chip.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	room_chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	root.add_child(room_chip)

func _refresh_window_mode(fullscreen: bool) -> void:
	window_mode_button.text = "窗口 F11" if fullscreen else "全屏 F11"

func _build_menu() -> void:
	menu = Control.new()
	menu.name = "Camp"
	menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(menu)
	preview_drag_area = Control.new()
	preview_drag_area.name = "PreviewDragArea"
	preview_drag_area.position = Vector2(32, 165)
	preview_drag_area.size = Vector2(902, 690)
	preview_drag_area.mouse_filter = Control.MOUSE_FILTER_STOP
	preview_drag_area.gui_input.connect(_preview_drag_gui_input)
	menu.add_child(preview_drag_area)
	preview_drag_hint = _label("按住鼠标左右拖动来查看角色", 17, Color("153b3f"))
	preview_drag_hint.name = "PreviewDragHint"
	preview_drag_hint.position = Vector2(280, 799)
	preview_drag_hint.size = Vector2(400, 44)
	preview_drag_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview_drag_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var hint_style: StyleBoxFlat = _box(Color(1.0, 0.992, 0.961, 0.55), 10, 8)
	hint_style.set_border_width_all(0)
	hint_style.shadow_size = 0
	preview_drag_hint.add_theme_stylebox_override("normal", hint_style)
	menu.add_child(preview_drag_hint)
	menu.visibility_changed.connect(_on_menu_visibility_changed)
	# The left half belongs to the live island; all menu controls sit at right.
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "MenuPanel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	panel.offset_left = -650.0
	panel.offset_right = -48.0
	panel.offset_top = -310.0
	panel.offset_bottom = 310.0
	var menu_style: StyleBoxFlat = _box(Color(1.0, 0.976, 0.914, 0.25), 28, 28)
	menu_style.shadow_color = Color(0.07, 0.22, 0.24, 0.025)
	menu_style.shadow_size = 6
	panel.add_theme_stylebox_override("panel", menu_style)
	menu.add_child(panel)
	var column: VBoxContainer = VBoxContainer.new()
	column.name = "MenuColumn"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 22)
	panel.add_child(column)
	var title: Label = _label("海岛碰碰球", 56, Color("fff2ae"))
	title.name = "GameTitle"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.add_theme_color_override("font_outline_color", INK)
	title.add_theme_constant_override("outline_size", 8)
	title.add_theme_color_override("font_shadow_color", Color("244e5a45"))
	title.add_theme_constant_override("shadow_offset_y", 4)
	column.add_child(title)
	var animals: GridContainer = GridContainer.new()
	animals.name = "AnimalChoices"
	animals.columns = 4
	animals.add_theme_constant_override("h_separation", 12)
	animals.add_theme_constant_override("v_separation", 12)
	column.add_child(animals)
	for kind: String in ANIMALS:
		var button: Button = _button(str(ANIMALS[kind]), _pick_animal.bind(kind), "Animal_" + kind)
		button.custom_minimum_size = Vector2(126, 64)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_compact_button(button, 64)
		button.add_theme_font_size_override("font_size", 19)
		button.add_theme_color_override("font_pressed_color", CREAM)
		button.add_theme_color_override("font_hover_pressed_color", CREAM)
		button.toggle_mode = true
		animals.add_child(button)
		animal_buttons[kind] = button
	var instructions: Label = _label("控制方向将其他玩家撞出小岛，\n最后留在岛上的玩家获胜。", 22, Color("153b3f"))
	instructions.name = "MenuInstructions"
	instructions.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	instructions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	instructions.add_theme_constant_override("line_spacing", 5)
	var instruction_style: StyleBoxFlat = _box(Color(1.0, 0.992, 0.961, 0.55), 12, 12)
	instruction_style.set_border_width_all(0)
	instruction_style.shadow_size = 0
	instructions.add_theme_stylebox_override("normal", instruction_style)
	column.add_child(instructions)
	var modes: HBoxContainer = HBoxContainer.new()
	modes.name = "ModeActions"
	modes.add_theme_constant_override("separation", 14)
	column.add_child(modes)
	solo_button = _button("单机模式", func() -> void: action.emit("start_solo", {}), "StartSolo")
	solo_button.custom_minimum_size.y = 68
	solo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_primary(solo_button, Color("f58a43"))
	modes.add_child(solo_button)
	var pk: Button = _button("联机模式", _show_room, "StartPK")
	pk.custom_minimum_size.y = 68
	pk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pk.add_theme_font_size_override("font_size", 22)
	modes.add_child(pk)
	var controls: Label = _label("WASD / 方向键移动", 18, Color("153b3f"))
	controls.name = "MenuControls"
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	controls.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var controls_style: StyleBoxFlat = _box(Color(1.0, 0.992, 0.961, 0.55), 10, 10)
	controls_style.set_border_width_all(0)
	controls_style.shadow_size = 0
	controls.add_theme_stylebox_override("normal", controls_style)
	column.add_child(controls)

func set_preview_drag_enabled(value: bool) -> void:
	_preview_drag_enabled = value
	if not value:
		_end_preview_drag()
	_refresh_preview_drag_state()

func _can_preview_drag() -> bool:
	return _preview_drag_enabled and screen == "menu" and is_instance_valid(menu) and menu.is_visible_in_tree() \
		and (not is_instance_valid(modal) or not modal.visible) \
		and (not is_instance_valid(camera_panel) or not camera_panel.visible) \
		and (not is_instance_valid(file_dialog) or not file_dialog.visible)

func _refresh_preview_drag_state() -> void:
	if not is_instance_valid(preview_drag_area):
		return
	var allowed: bool = _can_preview_drag()
	preview_drag_area.mouse_filter = Control.MOUSE_FILTER_STOP if allowed else Control.MOUSE_FILTER_IGNORE
	preview_drag_hint.visible = allowed
	if not allowed:
		_end_preview_drag()

func _preview_drag_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and _can_preview_drag():
		_preview_dragging = true
		preview_drag_area.accept_event()

func _end_preview_drag() -> void:
	_preview_dragging = false

func _on_menu_visibility_changed() -> void:
	if not menu.is_visible_in_tree():
		_end_preview_drag()

func _build_hud() -> void:
	hud = Control.new()
	hud.name = "MatchHUD"
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud)
	var stats: PanelContainer = PanelContainer.new()
	stats.name = "MatchStats"
	stats.position = Vector2(24, 24)
	stats.custom_minimum_size = Vector2(128, 70)
	stats.add_theme_stylebox_override("panel", _box(Color("fff9e9e6"), 14, 10))
	hud.add_child(stats)
	var timer: VBoxContainer = VBoxContainer.new()
	timer.add_theme_constant_override("separation", 0)
	stats.add_child(timer)
	timer.add_child(_label("持续时间", 11, MUTED))
	timer_label = _label("00:00", 28)
	timer_label.name = "Timer"
	timer.add_child(timer_label)
	var controls: VBoxContainer = VBoxContainer.new()
	controls.name = "EffectButtons"
	controls.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	controls.position = Vector2(-136, -156)
	controls.size = Vector2(112, 312)
	controls.add_theme_constant_override("separation", 8)
	hud.add_child(controls)
	var short_labels: Dictionary = {"grow":"变大", "shrink":"变小", "speedUp":"加速", "speedDown":"减速", "wind":"侧风"}
	for kind: String in EFFECTS:
		var button: Button = _button(str(short_labels[kind]), _trigger_effect.bind(kind), "Effect_" + kind)
		_compact_button(button, 56)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size.x = 112
		button.add_theme_font_size_override("font_size", 17)
		button.tooltip_text = ""
		controls.add_child(button)
		effect_buttons[kind] = button
		if kind == "wind":
			for state: String in ["normal", "hover", "pressed", "disabled"]:
				_wind_idle_styles[state] = button.get_theme_stylebox(state)
				var color: Color = MINT
				if state == "hover": color = MINT.lightened(0.08)
				elif state == "pressed": color = MINT.darkened(0.10)
				elif state == "disabled": color = Color("6e9c8b")
				var active_box: StyleBoxFlat = _box(color, 10, 8)
				active_box.border_color = Color("ffe4a2")
				active_box.set_border_width_all(2)
				_wind_active_styles[state] = active_box
	countdown_overlay = Control.new()
	countdown_overlay.name = "CountdownOverlay"
	countdown_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	countdown_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(countdown_overlay)
	var countdown_container: Panel = Panel.new()
	countdown_container.name = "CountdownContainer"
	countdown_container.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	countdown_container.offset_left = -110.0
	countdown_container.offset_top = -95.0
	countdown_container.offset_right = 110.0
	countdown_container.offset_bottom = 95.0
	countdown_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var countdown_background: StyleBoxFlat = _box(Color("fff9e9b8"), 28, 0)
	countdown_background.border_color = Color(1.0, 1.0, 1.0, 0.65)
	countdown_background.set_border_width_all(1)
	countdown_background.shadow_color = Color(INK, 0.14)
	countdown_background.shadow_size = 14
	countdown_background.shadow_offset = Vector2(0.0, 6.0)
	countdown_container.add_theme_stylebox_override("panel", countdown_background)
	countdown_overlay.add_child(countdown_container)
	countdown_label = _label("3", 112, CREAM)
	countdown_label.name = "CountdownLabel"
	countdown_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	# Offsets are relative to the centred anchors, unlike an absolute position.
	countdown_label.offset_left = -110.0
	countdown_label.offset_top = -95.0
	countdown_label.offset_right = 110.0
	countdown_label.offset_bottom = 95.0
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	countdown_label.add_theme_color_override("font_outline_color", Color(INK, 0.95))
	countdown_label.add_theme_constant_override("outline_size", 14)
	countdown_label.add_theme_color_override("font_shadow_color", Color(INK, 0.25))
	countdown_label.add_theme_constant_override("shadow_offset_x", 4)
	countdown_label.add_theme_constant_override("shadow_offset_y", 6)
	countdown_overlay.add_child(countdown_label)
	countdown_overlay.hide()

func _build_spectator() -> void:
	spectator_panel = PanelContainer.new()
	spectator_panel.name = "SpectatorCard"
	spectator_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	spectator_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	spectator_panel.position = Vector2(-260, -144)
	spectator_panel.size = Vector2(520, 120)
	spectator_panel.add_theme_stylebox_override("panel", _box(Color("fff9e9ed"), 18, 14))
	root.add_child(spectator_panel)
	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	spectator_panel.add_child(content)
	var notice: Label = _label("你已被淘汰 · 正在观战", 20, INK)
	notice.name = "SpectatorNotice"
	notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(notice)
	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	content.add_child(buttons)
	spectator_restart = _button("再来一局", _request_restart, "SpectatorRestart")
	_compact_button(spectator_restart, 42)
	spectator_restart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spectator_restart)
	var quit: Button = _button("返回开始界面", func() -> void: action.emit("home", {}), "SpectatorQuit")
	_compact_button(quit, 42)
	quit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(quit)
	spectator_panel.hide()

func get_match_safe_rect() -> Rect2:
	return MATCH_WORLD_SAFE_RECT

func _build_modal() -> void:
	modal = Control.new()
	modal.name = "Modal"
	modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(modal)
	var shade: ColorRect = ColorRect.new()
	shade.color = Color(0.04, 0.15, 0.18, 0.32)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal.add_child(shade)
	modal_panel = PanelContainer.new()
	modal_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	modal_panel.add_theme_stylebox_override("panel", _box(CREAM, 26, 28))
	modal.add_child(modal_panel)
	modal_content = VBoxContainer.new()
	modal_content.add_theme_constant_override("separation", 17)
	modal_panel.add_child(modal_content)
	modal.hide()

func _build_result_overlay() -> void:
	# Keep the celebration and sea fully visible between the two UI bands.
	result_overlay = Control.new()
	result_overlay.name = "ResultOverlay"
	result_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	result_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(result_overlay)
	var banner: PanelContainer = PanelContainer.new()
	banner.name = "VictoryBanner"
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	banner.offset_left = -360.0
	banner.offset_right = 360.0
	banner.offset_top = 52.0
	banner.offset_bottom = 158.0
	var banner_style: StyleBoxFlat = _box(Color("fff3ccef"), 26, 16)
	banner_style.set_border_width_all(3)
	banner_style.border_color = Color("e7b753")
	banner_style.shadow_color = Color("8060444d")
	banner.add_theme_stylebox_override("panel", banner_style)
	result_overlay.add_child(banner)
	result_title = _label("", 48, INK)
	result_title.name = "ResultTitle"
	result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	result_title.add_theme_color_override("font_outline_color", Color("fffdf2"))
	result_title.add_theme_constant_override("outline_size", 5)
	banner.add_child(result_title)
	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.name = "ResultActions"
	buttons.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	buttons.offset_left = -340.0
	buttons.offset_right = 340.0
	buttons.offset_top = -108.0
	buttons.offset_bottom = -40.0
	buttons.add_theme_constant_override("separation", 18)
	result_overlay.add_child(buttons)
	result_restart = _button("再来一局", _request_restart, "ResultRestart")
	result_restart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_primary(result_restart, CORAL)
	buttons.add_child(result_restart)
	var home: Button = _button("返回开始界面", func() -> void: action.emit("home", {}), "ResultHome")
	home.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(home)
	_clear_result_overlay()

func _clear_result_overlay() -> void:
	result_overlay.hide()
	result_title.text = ""
	result_restart.text = "再来一局"
	result_restart.disabled = false

func _build_pause_overlay() -> void:
	pause_overlay = Control.new()
	pause_overlay.name = "PauseOverlay"
	pause_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(pause_overlay)
	var banner: PanelContainer = PanelContainer.new()
	banner.name = "PauseBanner"
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	banner.offset_left = -220.0
	banner.offset_right = 220.0
	banner.offset_top = 52.0
	banner.offset_bottom = 142.0
	var banner_style: StyleBoxFlat = _box(Color("fff9e9ed"), 24, 14)
	banner_style.set_border_width_all(2)
	banner_style.border_color = Color("c6d7b8")
	banner.add_theme_stylebox_override("panel", banner_style)
	pause_overlay.add_child(banner)
	var title: Label = _label("游戏暂停", 38, INK)
	title.name = "PauseTitle"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.add_child(title)
	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.name = "PauseActions"
	buttons.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	buttons.offset_left = -480.0
	buttons.offset_right = 480.0
	buttons.offset_top = -108.0
	buttons.offset_bottom = -40.0
	buttons.add_theme_constant_override("separation", 18)
	pause_overlay.add_child(buttons)
	var resume: Button = _button("继续游戏", func() -> void: action.emit("resume", {}), "PauseResume")
	resume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_primary(resume, MINT)
	buttons.add_child(resume)
	var restart: Button = _button("重新开始", func() -> void: action.emit("restart", {}), "PauseRestart")
	restart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(restart)
	var home: Button = _button("返回开始界面", func() -> void: action.emit("home", {}), "PauseHome")
	home.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(home)
	pause_overlay.hide()

func _build_camera_panel() -> void:
	camera_panel = PanelContainer.new()
	camera_panel.name = "CameraPanel"
	camera_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	camera_panel.offset_left = -386.0
	camera_panel.offset_right = -24.0
	camera_panel.offset_top = 84.0
	camera_panel.offset_bottom = 660.0
	camera_panel.z_index = 30
	camera_panel.add_theme_stylebox_override("panel", _box(Color("fff9e9f2"), 22, 20))
	root.add_child(camera_panel)
	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override("separation", 16)
	camera_panel.add_child(content)
	var heading: HBoxContainer = HBoxContainer.new()
	content.add_child(heading)
	var title: Label = _label("镜头调节", 23, INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var close: Button = _button("×", _close_camera_panel, "CameraClose")
	_compact_button(close, 36)
	close.custom_minimum_size.x = 40
	close.add_theme_font_size_override("font_size", 22)
	heading.add_child(close)
	_camera_tabs = TabContainer.new()
	_camera_tabs.name = "CameraTabs"
	_camera_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_camera_tabs.add_theme_font_size_override("font_size", 18)
	_camera_tabs.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var selected_tab: StyleBoxFlat = _box(Color("dcebd2"), 10, 12)
	selected_tab.shadow_size = 0
	selected_tab.border_color = Color("91b09b")
	var idle_tab: StyleBoxFlat = _box(Color("fff9e980"), 10, 12)
	idle_tab.shadow_size = 0
	idle_tab.border_color = Color("c6d7b880")
	var hover_tab: StyleBoxFlat = _box(Color("eff5e4"), 10, 12)
	hover_tab.shadow_size = 0
	_camera_tabs.add_theme_stylebox_override("tab_selected", selected_tab)
	_camera_tabs.add_theme_stylebox_override("tab_unselected", idle_tab)
	_camera_tabs.add_theme_stylebox_override("tab_hovered", hover_tab)
	_camera_tabs.add_theme_stylebox_override("tab_focus", StyleBoxEmpty.new())
	for color_key: String in ["font_selected_color", "font_unselected_color", "font_hovered_color"]:
		_camera_tabs.add_theme_color_override(color_key, INK)
	content.add_child(_camera_tabs)
	var captions: Dictionary = {"height": "高度", "distance": "水平距离", "fov": "视角", "yaw": "方位"}
	for scope: String in ["match", "victory"]:
		var page: VBoxContainer = VBoxContainer.new()
		page.name = "Camera_" + scope
		page.add_theme_constant_override("separation", 18)
		_camera_tabs.add_child(page)
		_camera_tabs.set_tab_title(_camera_tabs.get_tab_count() - 1, "比赛" if scope == "match" else "胜利")
		for key: String in ["height", "distance", "fov", "yaw"]:
			var group: VBoxContainer = VBoxContainer.new()
			group.add_theme_constant_override("separation", 4)
			page.add_child(group)
			var row: HBoxContainer = HBoxContainer.new()
			group.add_child(row)
			var caption: Label = _label(str(captions[key]), 17, INK)
			caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(caption)
			var readout: Label = _label("—", 17, INK)
			readout.name = "CameraValue_%s_%s" % [scope, key]
			readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(readout)
			_camera_readouts[scope][key] = readout
			var slider: HSlider = HSlider.new()
			slider.name = "Camera_%s_%s" % [scope, key]
			var limits: Vector2 = CAMERA_CONTROL_RANGES[scope][key]
			slider.min_value = limits.x
			slider.max_value = limits.y
			slider.step = 0.1
			slider.custom_minimum_size = Vector2(0, 28)
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			slider.editable = false
			var track: StyleBoxFlat = StyleBoxFlat.new()
			track.bg_color = Color("eee6cf")
			track.set_corner_radius_all(4)
			track.content_margin_top = 3.0
			track.content_margin_bottom = 3.0
			var fill: StyleBoxFlat = track.duplicate()
			fill.bg_color = MINT
			var highlighted_fill: StyleBoxFlat = fill.duplicate()
			highlighted_fill.bg_color = MINT.lightened(0.13)
			slider.add_theme_stylebox_override("slider", track)
			slider.add_theme_stylebox_override("grabber_area", fill)
			slider.add_theme_stylebox_override("grabber_area_highlight", highlighted_fill)
			slider.value_changed.connect(_camera_value_changed.bind(scope, key))
			group.add_child(slider)
			camera_controls[scope][key] = slider
	_camera_tabs.tab_changed.connect(_camera_tab_changed)
	_camera_preview_actions = HBoxContainer.new()
	_camera_preview_actions.name = "CameraPreviewActions"
	_camera_preview_actions.add_theme_constant_override("separation", 10)
	content.add_child(_camera_preview_actions)
	var preview: Button = _button("预览胜利镜头", func() -> void: action.emit("camera_preview", {"scope": "victory"}), "CameraPreview")
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_compact_button(preview, 44)
	preview.add_theme_font_size_override("font_size", 16)
	_camera_preview_actions.add_child(preview)
	var end_preview: Button = _button("退出预览", func() -> void: action.emit("camera_preview_end", {}), "CameraPreviewEnd")
	end_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_compact_button(end_preview, 44)
	end_preview.add_theme_font_size_override("font_size", 16)
	_camera_preview_actions.add_child(end_preview)
	_camera_preview_actions.hide()
	var reset: Button = _button("恢复默认", _reset_camera_scope, "CameraReset")
	_compact_button(reset, 48)
	reset.add_theme_font_size_override("font_size", 18)
	content.add_child(reset)
	camera_panel.hide()
	if not _camera_settings.is_empty():
		set_camera_settings(_camera_settings)

func set_camera_settings(settings: Dictionary) -> void:
	# Defaults and persistence belong to the world/game, never this UI.
	_camera_settings = settings.duplicate(true)
	for scope: String in ["match", "victory"]:
		var values: Dictionary = _camera_settings.get(scope, {})
		for key: String in camera_controls[scope]:
			var slider: HSlider = camera_controls[scope][key]
			slider.editable = values.has(key)
			if not values.has(key):
				continue
			slider.set_value_no_signal(float(values[key]))
			_camera_readouts[scope][key].text = _format_camera_value(key, slider.value)

func _format_camera_value(key: String, value: float) -> String:
	return "%.1f°" % value if key in ["fov", "yaw"] else "%.1f m" % value

func _camera_value_changed(value: float, scope: String, key: String) -> void:
	if not _camera_settings.has(scope):
		return
	_camera_settings[scope][key] = value
	_camera_readouts[scope][key].text = _format_camera_value(key, value)
	action.emit("camera_settings", {"scope": scope, "values": _camera_settings[scope].duplicate(true)})

func _camera_tab_changed(index: int) -> void:
	_camera_preview_actions.visible = index == 1
	if index != 1:
		action.emit("camera_preview_end", {})

func _reset_camera_scope() -> void:
	action.emit("camera_reset", {"scope": "victory" if _camera_tabs.current_tab == 1 else "match"})

func _toggle_camera_panel() -> void:
	_end_preview_drag()
	if camera_panel.visible:
		_close_camera_panel()
	else:
		camera_panel.show()
		camera_button.button_pressed = true

func _close_camera_panel() -> void:
	var was_visible: bool = camera_panel.visible
	camera_panel.hide()
	camera_button.button_pressed = false
	if was_visible:
		action.emit("camera_preview_end", {})

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		_toggle_camera_panel()
		get_viewport().set_input_as_handled()
		return
	if not _preview_dragging:
		return
	if not _can_preview_drag():
		_end_preview_drag()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_end_preview_drag()
		# Let GUI dispatch receive release too, so its mouse capture is cleared.
	elif event is InputEventMouseMotion:
		if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_end_preview_drag()
			return
		if not is_zero_approx(event.relative.x):
			action.emit("preview_rotate", {"delta": event.relative.x})
		get_viewport().set_input_as_handled()

func _build_file_dialog() -> void:
	file_dialog = FileDialog.new()
	file_dialog.name = "RemixImageDialog"
	file_dialog.title = "选择本地图片 · 居中裁成圆形"
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp,*.bmp,*.tga,*.svg ; 图片文件"])
	file_dialog.use_native_dialog = true
	file_dialog.file_selected.connect(_image_selected)
	root.add_child(file_dialog)

func _open_modal(title: String, width: float, height: float, kind: String) -> void:
	_end_preview_drag()
	modal_kind = kind
	for child: Node in modal_content.get_children():
		modal_content.remove_child(child)
		child.queue_free()
	modal_panel.offset_left = -width / 2.0
	modal_panel.offset_right = width / 2.0
	modal_panel.offset_top = -height / 2.0
	modal_panel.offset_bottom = height / 2.0
	var heading: HBoxContainer = HBoxContainer.new()
	modal_content.add_child(heading)
	var label: Label = _label(title, 29)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(label)
	if kind != "result":
		heading.add_child(_button("×", close_modal, "CloseModal"))
	modal.show()

func close_modal() -> void:
	if camera_panel.visible:
		_close_camera_panel()
		return
	if modal_kind == "result":
		return
	if pause_overlay.visible or modal_kind == "pause":
		# All resume entries use the same main-game pause state transition.
		action.emit("resume", {})
		return
	if modal_kind == "wardrobe":
		# Release the single on-demand character preview with its editor.
		draft_preview = null
		for child: Node in modal_content.get_children():
			modal_content.remove_child(child)
			child.queue_free()
	modal_kind = ""
	modal.hide()

func is_editing() -> bool:
	return modal.visible or file_dialog.visible or pause_overlay.visible or camera_panel.visible

func show_menu() -> void:
	_end_preview_drag()
	_preview_drag_enabled = true
	screen = "menu"
	_close_camera_panel()
	_clear_result_overlay()
	pause_overlay.hide()
	_refresh_countdown()
	paused = false
	menu.show()
	brand_label.hide()
	room_chip.hide()
	hud.hide()
	spectator_panel.hide()
	pause_button.hide()
	toast_label.hide()
	toast_time = 0.0
	modal.hide()
	modal_kind = ""
	_refresh_selection()
	_refresh_wind_indicator()

func show_match(match_mode: String) -> void:
	_end_preview_drag()
	mode = match_mode
	screen = "playing"
	_close_camera_panel()
	_clear_result_overlay()
	pause_overlay.hide()
	# Hold the input/timer UI in the non-interactive opening phase until the
	# next authoritative snapshot supplies intro, countdown or live play.
	snapshot = {"status": "intro", "elapsedSeconds": 0.0}
	_refresh_countdown()
	if mode == "solo":
		local_id = "player"
	elif str(room_state.get("role", "")) in ["host", "guest"]:
		local_id = str(room_state["role"])
	menu.hide()
	brand_label.hide()
	room_chip.hide()
	hud.show()
	spectator_panel.hide()
	toast_label.hide()
	toast_time = 0.0
	modal.hide()
	modal_kind = ""
	timer_label.text = "00:00"
	set_paused(false)

func show_spectator() -> void:
	screen = "spectating"
	_refresh_countdown()
	menu.hide()
	brand_label.hide()
	room_chip.hide()
	modal.hide()
	modal_kind = ""
	toast_label.hide()
	toast_time = 0.0
	hud.show()
	spectator_restart.text = "再来一局"
	spectator_restart.disabled = false
	spectator_panel.show()
	for kind: String in effect_buttons:
		var button: Button = effect_buttons[kind]
		button.disabled = true
	set_paused(false)

func _pick_animal(kind: String) -> void:
	store.select_animal(kind)
	_refresh_selection()
	selection_changed.emit(store.selection.duplicate(true))

func _refresh_selection() -> void:
	if is_instance_valid(points_label):
		points_label.text = "%d  Remix积分" % store.points
	for kind: String in animal_buttons:
		var button: Button = animal_buttons[kind]
		button.button_pressed = str(store.selection.get("animal", "rabbit")) == kind
	if is_instance_valid(preview_label):
		preview_label.text = "%s · %s\n%s" % [ANIMALS.get(str(store.selection.get("animal", "rabbit")), "小兔"), store.selection.character.get("name", "薄荷假日"), store.selection.ball.get("name", "海岛薄荷")]

func _trigger_effect(kind: String) -> void:
	if not _can_interact() or (kind == "wind" and wind_active):
		return
	action.emit("effect", {"kind":kind, "targetId":local_id})

func update_snapshot(value: Dictionary, my_id: String = "player") -> void:
	snapshot = value
	local_id = my_id
	_refresh_selection()
	_refresh_countdown()
	var phase: String = str(snapshot.get("status", ""))
	timer_label.text = "00:00" if phase in ["intro", "countdown"] else _format_elapsed(float(snapshot.get("elapsedSeconds", 0.0)))
	_refresh_interaction_buttons()
	_refresh_wind_indicator()

func _refresh_countdown() -> void:
	countdown_active = screen == "playing" and str(snapshot.get("status", "")) == "countdown"
	countdown_remaining = maxf(0.0, float(snapshot.get("countdownRemaining", 0.0))) if countdown_active else 0.0
	if is_instance_valid(countdown_overlay):
		countdown_overlay.visible = countdown_active
		if countdown_active:
			countdown_label.text = str(clampi(ceili(countdown_remaining), 1, 3))
		else:
			countdown_label.text = ""

func _can_interact() -> bool:
	# Intro, countdown and a guest waiting for authority all stay locked;
	# only an authoritative live-play phase enables audience interactions.
	return screen == "playing" and not paused and str(snapshot.get("status", "")) == "playing"

func _refresh_interaction_buttons() -> void:
	for kind: String in effect_buttons:
		var button: Button = effect_buttons[kind]
		button.disabled = not _can_interact() or (kind == "wind" and wind_active)

func _refresh_wind_indicator() -> void:
	if not effect_buttons.has("wind"):
		return
	var button: Button = effect_buttons["wind"]
	var remaining: float = 0.0
	var active: bool = false
	var wind_value: Variant = snapshot.get("wind", null)
	if wind_value is Dictionary:
		var wind: Dictionary = wind_value
		remaining = clampf(float(wind.get("remaining", 0.0)), 0.0, maxf(0.0, float(wind.get("duration", 3.0))))
		active = bool(wind.get("active", remaining > 0.0)) and remaining > 0.0
	else:
		# Older snapshots expose only effectRemaining. Wind is global, so an
		# eliminated local player must still see a surviving player's gust timer.
		var own_effects: Variant = snapshot.get("effectRemaining", {})
		if own_effects is Dictionary:
			remaining = maxf(remaining, float(own_effects.get("wind", 0.0)))
		var entities: Array = snapshot.get("entities", snapshot.get("players", []))
		for entity: Variant in entities:
			if not entity is Dictionary:
				continue
			var effects: Variant = entity.get("effectRemaining", {})
			if effects is Dictionary:
				remaining = maxf(remaining, float(effects.get("wind", 0.0)))
		remaining = minf(remaining, 3.0)
		active = remaining > 0.0
	if screen not in ["playing", "spectating"]:
		active = false
		remaining = 0.0
	if active != wind_active:
		var styles: Dictionary = _wind_active_styles if active else _wind_idle_styles
		for state: String in ["normal", "hover", "pressed", "disabled"]:
			button.add_theme_stylebox_override(state, styles[state])
		button.add_theme_color_override("font_color", CREAM if active else INK)
		button.add_theme_color_override("font_hover_color", CREAM if active else INK)
		button.add_theme_color_override("font_pressed_color", CREAM)
		button.add_theme_color_override("font_disabled_color", CREAM if active else Color("93a69a"))
	wind_active = active
	wind_remaining = remaining if active else 0.0
	button.text = ("侧风 %.1f秒" % (ceilf(maxf(0.0, wind_remaining - 0.000001) * 10.0) / 10.0)) if active else "侧风"
	button.disabled = active or not _can_interact()

func _format_elapsed(seconds: float) -> String:
	var elapsed: int = maxi(0, int(floor(seconds)))
	# Keep total minutes so games longer than an hour never wrap back to 00:00.
	var minutes: int = int(elapsed / 60.0)
	return "%02d:%02d" % [minutes, elapsed % 60]

func show_finish_focus() -> void:
	# The world focuses the winner first; no panel obscures that camera move.
	screen = "finished"
	_clear_result_overlay()
	pause_overlay.hide()
	_refresh_countdown()
	menu.hide()
	brand_label.hide()
	room_chip.hide()
	hud.hide()
	spectator_panel.hide()
	toast_label.hide()
	toast_time = 0.0
	pause_button.hide()
	modal.hide()
	modal_kind = ""
	_refresh_wind_indicator()

func show_result(value: Dictionary) -> void:
	show_finish_focus()
	snapshot = value
	var winner_id: String = str(value.get("winnerId", value.get("winner_id", "")))
	var winner_name: String = str(value.get("winnerName", value.get("winner_name", "")))
	var winner: Variant = value.get("winner", null)
	if winner is Dictionary:
		winner_id = str(winner.get("id", winner_id))
		winner_name = str(winner.get("name", winner_name))
	if winner_name.is_empty():
		for entity: Dictionary in value.get("entities", value.get("players", [])):
			if str(entity.get("id", "")) == winner_id: winner_name = str(entity.get("name", "玩家"))
	if winner_id == local_id:
		winner_name = "你"
	else:
		winner_name = _competitive_text(winner_name)
	result_title.text = "你获得胜利" if winner_id == local_id else "%s获胜" % (winner_name if not winner_name.is_empty() else "选手")
	result_overlay.show()

func _request_restart() -> void:
	if mode == "pk" and str(room_state.get("role", "")) == "guest":
		var button: Button = spectator_restart if screen == "spectating" else result_restart
		if is_instance_valid(button):
			button.text = "等待房主重开"
			button.disabled = true
	action.emit("restart", {})

func _toggle_pause() -> void:
	if mode == "solo" and screen == "playing":
		action.emit("resume" if paused else "pause", {})

func _show_pause_menu() -> void:
	modal.hide()
	modal_kind = ""
	pause_overlay.show()

func set_paused(value: bool) -> void:
	# Spectators cannot stop the competitors that are still playing.
	paused = value and screen != "spectating"
	pause_button.text = "继续" if paused else "暂停"
	pause_button.visible = screen in ["playing", "spectating"]
	pause_button.disabled = mode != "solo" or screen == "spectating"
	pause_button.tooltip_text = "观战期间比赛持续进行" if screen == "spectating" else ("联机比赛持续进行" if mode != "solo" else "")
	# Keep the corner resume entry above the lightweight presentation bands.
	pause_button.z_index = 20 if paused else 0
	if paused and mode == "solo" and screen == "playing":
		if not pause_overlay.visible:
			_show_pause_menu()
	else:
		pause_overlay.hide()
		if modal_kind == "pause":
			modal.hide()
			modal_kind = ""
	_refresh_interaction_buttons()
	_refresh_wind_indicator()

func toast(text: String) -> void:
	_refresh_selection()
	if screen != "menu":
		toast_label.hide()
		toast_time = 0.0
		return
	toast_label.text = text
	toast_label.show()
	toast_time = 3.5

func _process(delta: float) -> void:
	_refresh_preview_drag_state()
	if _preview_dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end_preview_drag()
	if toast_time > 0.0:
		toast_time -= delta
		if toast_time <= 0.0: toast_label.hide()

func _show_wardrobe() -> void:
	draft_image = ""
	var style: Dictionary = store.selection[remix_category]
	draft_colors = style.get("colors", draft_colors).duplicate()
	_render_wardrobe()

func _render_wardrobe() -> void:
	_open_modal("我的 Remix 衣柜", 1020, 660, "wardrobe")
	var tabs: HBoxContainer = HBoxContainer.new()
	modal_content.add_child(tabs)
	for kind: String in ["character", "ball"]:
		var label: String = "角色造型" if kind == "character" else "大球样式"
		var button: Button = _button(label, _switch_remix.bind(kind), "RemixTab_" + kind)
		button.toggle_mode = true
		button.button_pressed = remix_category == kind
		tabs.add_child(button)
	tabs.add_child(_label("  已拥有的样式可永久使用", 14, MUTED))
	var wardrobe_points: Label = _label("%d  Remix积分" % store.points, 14, INK)
	wardrobe_points.name = "WardrobePoints"
	tabs.add_child(wardrobe_points)
	var content: HBoxContainer = HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 25)
	modal_content.add_child(content)
	var library: VBoxContainer = VBoxContainer.new()
	library.custom_minimum_size = Vector2(540, 0)
	library.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(library)
	library.add_child(_label("我的收藏  ·  点击装备", 17))
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(540, 370)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	library.add_child(scroll)
	var grid: GridContainer = GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(grid)
	var styles: Array = store.characters if remix_category == "character" else store.balls
	for style: Dictionary in styles:
		var card: VBoxContainer = VBoxContainer.new()
		card.custom_minimum_size = Vector2(170, 186)
		card.add_theme_constant_override("separation", 1)
		grid.add_child(card)
		var preview: PatternPreview = PatternPreview.new()
		preview.custom_minimum_size = Vector2(165, 130)
		preview.configure(style, remix_category, str(store.selection.animal))
		card.add_child(preview)
		var selected: bool = str(style.id) == str(store.selection[remix_category].id)
		var button: Button = _button(("✓ " if selected else "") + str(style.name), _equip_style.bind(str(style.id)), "Style_" + str(style.id))
		button.add_theme_font_size_override("font_size", 14)
		button.custom_minimum_size.y = 40
		card.add_child(button)
	var editor: PanelContainer = PanelContainer.new()
	editor.custom_minimum_size = Vector2(330, 0)
	editor.add_theme_stylebox_override("panel", _box(Color("edf1e4"), 19, 18))
	content.add_child(editor)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	editor.add_child(column)
	column.add_child(_label("创作新样式  ·  20 积分", 18))
	var single_color_ball: bool = remix_category == "ball"
	column.add_child(_label("选择一种球体颜色" if single_color_ball else "选三种颜色，或上传本地图片", 14, MUTED))
	draft_preview = PatternPreview.new()
	draft_preview.live_character_preview = not single_color_ball
	draft_preview.custom_minimum_size = Vector2(280, 100)
	column.add_child(draft_preview)
	var color_row: HBoxContainer = HBoxContainer.new()
	color_row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(color_row)
	color_buttons.clear()
	for index: int in range(1 if single_color_ball else 3):
		var picker: ColorPickerButton = ColorPickerButton.new()
		picker.name = "RemixColor_%d" % index
		picker.custom_minimum_size = Vector2(65, 40)
		picker.color = Color.from_string(str(draft_colors[index]), Color.WHITE)
		picker.edit_alpha = false
		picker.color_changed.connect(_color_changed.bind(index))
		color_row.add_child(picker)
		color_buttons.append(picker)
	if not single_color_ball:
		var image_row: HBoxContainer = HBoxContainer.new()
		column.add_child(image_row)
		var upload: Button = _button("上传本地图片" if draft_image.is_empty() else "更换本地图片", func() -> void: file_dialog.popup_centered_ratio(0.75), "RemixUpload")
		upload.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		upload.add_theme_font_size_override("font_size", 16)
		image_row.add_child(upload)
		if not draft_image.is_empty():
			var clear: Button = _button("清除", _clear_draft_image, "RemixClearImage")
			clear.add_theme_font_size_override("font_size", 14)
			image_row.add_child(clear)
	var note: Label = _label("保留球体主色 · 搭配角色足印" if single_color_ball else "图片将居中裁成圆形\n贴在角色前胸和背后", 13, MUTED)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(note)
	var save_button: Button = _button("保存并装备  ·  −20 积分", _save_remix, "RemixSave")
	save_button.disabled = store.points < 20
	_primary(save_button)
	save_button.add_theme_font_size_override("font_size", 18)
	column.add_child(save_button)
	column.add_child(_label("永久保存在本机，PK时同步展示", 12, MUTED))
	_update_draft_preview()

func _switch_remix(kind: String) -> void:
	remix_category = kind
	draft_image = ""
	draft_colors = store.selection[kind].get("colors", draft_colors).duplicate()
	_render_wardrobe()

func _equip_style(id: String) -> void:
	store.select_style(remix_category, id)
	_refresh_selection()
	selection_changed.emit(store.selection.duplicate(true))
	_render_wardrobe()

func _color_changed(color: Color, index: int) -> void:
	var value: String = "#" + color.to_html(false)
	if remix_category == "ball":
		draft_colors = [value, value, value]
		draft_image = ""
	else:
		draft_colors[index] = value
	_update_draft_preview()

func _update_draft_preview() -> void:
	if is_instance_valid(draft_preview):
		draft_preview.configure({"colors":draft_colors, "image":draft_image}, remix_category, str(store.selection.animal))

func _image_selected(path: String) -> void:
	if remix_category != "character":
		return
	var image: Image = Image.new()
	if image.load(path) != OK:
		toast("无法读取该图片，请选择 PNG、JPG 或 WEBP")
		return
	draft_image = path
	_render_wardrobe()

func _clear_draft_image() -> void:
	draft_image = ""
	_render_wardrobe()

func _save_remix() -> void:
	var colors: Array = draft_colors.duplicate()
	var image_path: String = draft_image
	if remix_category == "ball":
		var color: String = str(colors[0]) if not colors.is_empty() else "#173E69"
		colors = [color, color, color]
		image_path = ""
	var result: Dictionary = store.save_remix(remix_category, colors, image_path)
	toast(str(result.get("message", "")))
	if bool(result.get("ok", false)):
		draft_image = ""
		selection_changed.emit(store.selection.duplicate(true))
		_render_wardrobe()

func _show_room() -> void:
	_render_room()

func _render_room() -> void:
	_open_modal("双人 PK · 联机房间", 640, 665, "room")
	var intro: Label = _label("两位玩家与 NPC 同场竞技。\n创建房间，或输入房主的 IP 地址加入。", 17, MUTED)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_content.add_child(intro)
	var row: HBoxContainer = HBoxContainer.new()
	modal_content.add_child(row)
	row.add_child(_label("端口", 17))
	var port: SpinBox = SpinBox.new()
	port.name = "RoomPort"
	port.min_value = 1024
	port.max_value = 65535
	port.value = float(room_state.get("port", 54130))
	port.custom_minimum_size = Vector2(145, 48)
	row.add_child(port)
	var create: Button = _button("创建房间", func() -> void: action.emit("create_room", {"port":int(port.value)}), "CreateRoom")
	create.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(create)
	var join: HBoxContainer = HBoxContainer.new()
	modal_content.add_child(join)
	var address: LineEdit = LineEdit.new()
	address.name = "RoomAddress"
	address.text = str(room_state.get("address", "127.0.0.1"))
	address.placeholder_text = "输入房主的 IP 地址"
	address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	address.custom_minimum_size.y = 48
	join.add_child(address)
	join.add_child(_button("加入房间", func() -> void: action.emit("join_room", {"address":address.text.strip_edges(), "port":int(port.value)}), "JoinRoom"))
	room_status = _label(_room_text(), 17, Color("52826e"))
	room_status.name = "RoomStatus"
	room_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	room_status.custom_minimum_size.y = 70
	modal_content.add_child(room_status)
	room_start = _button("双方已就绪，开始 PK", func() -> void: action.emit("start_pk", {}), "StartRoomMatch")
	_primary(room_start)
	room_start.disabled = not bool(room_state.get("ready", false)) or str(room_state.get("role", "")) != "host"
	modal_content.add_child(room_start)
	modal_content.add_child(_button("离开房间", func() -> void: action.emit("leave_room", {}), "LeaveRoom"))
	modal_content.add_child(_label("远程联机需房主开放对应 UDP 端口。", 13, MUTED))

func _room_text() -> String:
	var status: String = _competitive_text(str(room_state.get("status", "尚未连接")))
	var role: String = str(room_state.get("role", ""))
	var ready: bool = bool(room_state.get("ready", false))
	if role == "host":
		return "房主 · %s:%s\n%s" % [room_state.get("address", "本机"), room_state.get("port", 54130), "另一位玩家已连接，可以开赛" if ready else "等待另一位玩家加入…"]
	if role == "guest":
		return "玩家 · %s\n%s" % [status, "已连接，等待房主开始" if ready else "正在连接房主…"]
	return status

func _competitive_text(text: String) -> String:
	return text.replace("岛主", "房主").replace("岛民", "玩家").replace("主播", "玩家")

func set_room(value: Dictionary) -> void:
	room_state = value.duplicate(true)
	room_chip.text = "" if room_state.is_empty() else _room_text().replace("\n", "  ·  ")
	if modal_kind == "room":
		if is_instance_valid(room_status): room_status.text = _room_text()
		if is_instance_valid(room_start): room_start.disabled = not bool(room_state.get("ready", false)) or str(room_state.get("role", "")) != "host"
