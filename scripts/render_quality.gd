extends Node
## Limit the root Window's 3D buffers, independently of its 1600 x 900 UI.
## canvas_items draws 3D at the physical content size (not the UI logical size).
## A 2,073,600-pixel budget means 1920 x 1080 at 16:9. Small windows stay 1:1.

const PIXEL_BUDGET: int = 1920 * 1080
const MIN_ENGINE_SCALE: float = 0.1

var _window: Window

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_window = get_window()
	_window.size_changed.connect(refresh)
	_window.dpi_changed.connect(refresh)
	var manager: Node = get_node_or_null("/root/WindowManager")
	if manager != null and manager.has_signal("display_mode_changed"):
		# WindowManager emits this after native WM_SIZE, before its force_draw.
		manager.connect("display_mode_changed", _on_display_mode_changed)
	_window.msaa_3d = Viewport.MSAA_4X
	_window.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	_window.use_taa = false
	_window.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	refresh()

static func content_pixels(client_pixels: Vector2i, logical_size: Vector2i,
		aspect: int = Window.CONTENT_SCALE_ASPECT_KEEP,
		mode: int = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS) -> Vector2i:
	var result := Vector2i(maxi(1, client_pixels.x), maxi(1, client_pixels.y))
	if mode != Window.CONTENT_SCALE_MODE_CANVAS_ITEMS or aspect != Window.CONTENT_SCALE_ASPECT_KEEP or logical_size.x <= 0 or logical_size.y <= 0:
		return result
	# Match Window's KEEP content rectangle: the letterbox/pillarbox is not 3D.
	var fit: float = minf(float(result.x) / logical_size.x, float(result.y) / logical_size.y)
	return Vector2i(maxi(1, floori(logical_size.x * fit)), maxi(1, floori(logical_size.y * fit)))

static func scale_for_pixels(pixels: Vector2i) -> float:
	var count: float = float(maxi(1, pixels.x)) * float(maxi(1, pixels.y))
	# Godot's native rendering server clamps this property to 0.1..2.0.
	return clampf(sqrt(float(PIXEL_BUDGET) / count), MIN_ENGINE_SCALE, 1.0)

static func estimated_render_pixels(output_pixels: Vector2i, scale: float) -> Vector2i:
	return Vector2i(maxi(1, floori(output_pixels.x * scale)), maxi(1, floori(output_pixels.y * scale)))

func _client_pixels() -> Vector2i:
	if DisplayServer.get_name() != "headless":
		# With allow_hidpi this is the native client in physical pixels; do not
		# multiply it by Windows' DPI scale or use get_visible_rect() (UI units).
		var native_size: Vector2i = DisplayServer.window_get_size(_window.get_window_id())
		if native_size.x > 0 and native_size.y > 0:
			return native_size
	return _window.size

func refresh() -> void:
	if not is_instance_valid(_window):
		return
	var pixels: Vector2i = content_pixels(_client_pixels(), _window.content_scale_size,
		_window.content_scale_aspect, _window.content_scale_mode)
	var scale: float = scale_for_pixels(pixels)
	if not is_equal_approx(_window.scaling_3d_scale, scale):
		_window.scaling_3d_scale = scale

func _on_display_mode_changed(_fullscreen: bool) -> void:
	refresh()

func get_render_state() -> Dictionary:
	var client: Vector2i = _client_pixels()
	var output: Vector2i = content_pixels(client, _window.content_scale_size,
		_window.content_scale_aspect, _window.content_scale_mode)
	var estimate: Vector2i = estimated_render_pixels(output, _window.scaling_3d_scale)
	return {
		"client_pixels": [client.x, client.y],
		"content_pixels": [output.x, output.y],
		"estimated_3d_pixels": [estimate.x, estimate.y],
		"scaling_3d_scale": _window.scaling_3d_scale,
		"pixel_budget": PIXEL_BUDGET,
		"ui_base_size": [_window.content_scale_size.x, _window.content_scale_size.y],
		"ui_logical_size": [_window.get_visible_rect().size.x, _window.get_visible_rect().size.y],
		"msaa_3d": _window.msaa_3d,
		"screen_space_aa": _window.screen_space_aa,
		"taa": _window.use_taa,
		"scaling_3d_mode": _window.scaling_3d_mode
	}
