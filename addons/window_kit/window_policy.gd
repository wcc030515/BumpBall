class_name WindowPolicy
extends Node

signal display_mode_changed(fullscreen: bool)

const ASPECT_UNIT := Vector2i(16, 9)
const DEFAULT_SIZE := Vector2i(1920, 1080)
const MINIMUM_SIZE := Vector2i(640, 360)
const QHD_WINDOW_SIZE := Vector2i(1707, 960)
const HD_WINDOW_SIZE := Vector2i(1280, 720)
const MOVE_SETTLE_SECONDS := 0.25

var _window: Window
var _usable_rect := Rect2i()
var _decorations := Vector2i.ZERO
var _screen_size := Vector2i.ZERO
var _screen_index := -1
var _poll_time := 0.0
var _local_slot := -1
var _home_was_fullscreen := false
var _saved_size := Vector2i.ZERO
var _saved_position := Vector2i.ZERO
var _saved_screen := -1
var _last_position := Vector2i.ZERO
var _position_quiet_time := 0.0
var _requested_fullscreen := -1
var _mode_commit_queued := false
var _mode_commit_busy := false

func _ready() -> void:
	_window = get_window()
	process_mode = Node.PROCESS_MODE_ALWAYS
	if DisplayServer.get_name() == "headless":
		set_process(false)
		return
	# Godot forwards native min/max constraints only for a resizable HWND.
	# Lock both limits instead: Windows can then enforce the fixed client
	# size while crossing DPI boundaries, including inside its move loop.
	if _window.unresizable:
		_window.unresizable = false
	if not _window.maximize_disabled:
		_window.maximize_disabled = true
	_unlock_constraints()
	_apply_window_layout()

static func default_size_for_screen(screen_size: Vector2i) -> Vector2i:
	var longer := maxi(screen_size.x, screen_size.y)
	var shorter := mini(screen_size.x, screen_size.y)
	if longer >= 3840 and shorter >= 2160:
		return DEFAULT_SIZE
	if longer >= 2560 and shorter >= 1440:
		return QHD_WINDOW_SIZE
	return HD_WINDOW_SIZE

# One-pixel rounding keeps the requested 960p height. No continuous drag
# correction or 16x9-pixel size quantization is used for normal windows.
static func fitted_window_size(target: Vector2i, available: Vector2i) -> Vector2i:
	var limit := Vector2i(maxi(1, available.x), maxi(1, available.y))
	var height := mini(target.y, limit.y)
	var width := roundi(float(height) * 16.0 / 9.0)
	if width > limit.x:
		height = maxi(1, floori(float(limit.x) * 9.0 / 16.0))
		width = mini(limit.x, roundi(float(height) * 16.0 / 9.0))
	return Vector2i(maxi(1, width), maxi(1, height))

# Retained for older layout callers; it is never a native drag callback.
static func fit_inside(requested: Vector2i, limit: Vector2i) -> Vector2i:
	var steps := floori(minf(float(requested.x) / 16.0, float(requested.y) / 9.0))
	var maximum := floori(minf(float(limit.x) / 16.0, float(limit.y) / 9.0))
	return ASPECT_UNIT * maxi(1, mini(steps, maximum))

static func constrain_resize(requested: Vector2i, _previous: Vector2i, limit: Vector2i) -> Vector2i:
	return fit_inside(requested, limit)

func is_fullscreen() -> bool:
	return is_instance_valid(_window) and _window.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]

func toggle_fullscreen() -> void:
	var requested := is_fullscreen() if _requested_fullscreen < 0 else _requested_fullscreen == 1
	set_fullscreen(not requested)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		toggle_fullscreen()
		get_viewport().set_input_as_handled()

func set_fullscreen(enabled: bool) -> void:
	if not is_instance_valid(_window) or DisplayServer.get_name() == "headless":
		return
	_requested_fullscreen = 1 if enabled else 0
	if _mode_commit_queued or _mode_commit_busy:
		return
	_mode_commit_queued = true
	# process_events also flushes input. Leave the current input dispatch before
	# changing the HWND, then present at its final size in the same transaction.
	call_deferred("_commit_display_mode")

func _commit_display_mode() -> void:
	_mode_commit_queued = false
	if not is_instance_valid(_window) or not is_inside_tree():
		_requested_fullscreen = -1
		return
	if _mode_commit_busy:
		return
	var enabled := _requested_fullscreen == 1
	if enabled == is_fullscreen():
		_requested_fullscreen = -1
		return
	_mode_commit_busy = true
	if enabled:
		_saved_size = _window.size
		_saved_position = _window.position
		_saved_screen = _window.current_screen
		_unlock_constraints()
		# Nonexclusive fullscreen covers the monitor without decorations or a
		# video-mode change, preserving normal application switching.
		_window.mode = Window.MODE_FULLSCREEN
	else:
		_window.mode = Window.MODE_WINDOWED
		if _window.borderless:
			_window.borderless = false
		_apply_window_layout(false)
		if _local_slot < 0:
			if _saved_screen == _window.current_screen and _saved_size == _window.size:
				_window.position = _clamped_position(_saved_position)
			else:
				_center_window()
	# Window.mode updates the native rectangle before the queued resize reaches
	# the viewport/swapchain. Do not leave an old-size frame on screen until the
	# next normal render (especially when the first 4K frame is expensive).
	DisplayServer.process_events()
	display_mode_changed.emit(is_fullscreen())
	RenderingServer.force_draw(true, 0.0)
	_mode_commit_busy = false
	# Input flushed during the commit may have changed the desired final mode.
	# Merge it without overwriting the one saved windowed position/size.
	if _requested_fullscreen != (1 if is_fullscreen() else 0):
		_mode_commit_queued = true
		call_deferred("_commit_display_mode")
	else:
		_requested_fullscreen = -1

func set_local_layout(slot: int) -> void:
	if not is_instance_valid(_window) or DisplayServer.get_name() == "headless":
		return
	if _local_slot < 0:
		_home_was_fullscreen = is_fullscreen()
	if is_fullscreen():
		set_fullscreen(false)
	_local_slot = clampi(slot, 0, 1)
	_apply_window_layout()

func clear_local_layout() -> void:
	if _local_slot < 0:
		return
	_local_slot = -1
	if not is_inside_tree() or not is_instance_valid(_window):
		return
	if _home_was_fullscreen and not is_fullscreen():
		set_fullscreen(true)
	elif not is_fullscreen():
		_apply_window_layout()
	_home_was_fullscreen = false

func _process(delta: float) -> void:
	if not is_instance_valid(_window):
		return
	if _window.mode == Window.MODE_MAXIMIZED:
		set_fullscreen(true)
		return
	if _window.mode != Window.MODE_WINDOWED:
		return
	# Native title-bar dragging keeps the engine running through WM_TIMER.
	# Input's cached buttons are released on WM_ENTERSIZEMOVE, while the
	# Windows DisplayServer reads GetKeyState directly. Do not fight that
	# native move loop, even when the user holds the mouse still at a seam.
	var pointer_held := (DisplayServer.mouse_get_button_state() & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)) != 0
	var position := _window.position
	if pointer_held or position != _last_position:
		_position_quiet_time = 0.0
		_last_position = position
	else:
		_position_quiet_time += minf(delta, 0.05)
	if _position_quiet_time < MOVE_SETTLE_SECONDS:
		return
	_poll_time += delta
	if _poll_time < 0.1:
		return
	_poll_time = 0.0
	var screen := _window.current_screen
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var resolution := DisplayServer.screen_get_size(screen)
	# Apply a monitor/work-area change once, after release and settling.
	if screen != _screen_index or usable != _usable_rect or resolution != _screen_size or _decoration_size() != _decorations:
		_apply_window_layout(_local_slot >= 0)

func _decoration_size() -> Vector2i:
	var id := _window.get_window_id()
	var difference := DisplayServer.window_get_size_with_decorations(id) - DisplayServer.window_get_size(id)
	return Vector2i(maxi(0, difference.x), maxi(0, difference.y))

func _unlock_constraints() -> void:
	if _window.min_size != Vector2i.ZERO:
		_window.min_size = Vector2i.ZERO
	if _window.max_size != Vector2i.ZERO:
		_window.max_size = Vector2i.ZERO

func _apply_window_layout(center: bool = true) -> void:
	if is_fullscreen():
		return
	_screen_index = _window.current_screen
	_screen_size = DisplayServer.screen_get_size(_screen_index)
	_usable_rect = DisplayServer.screen_get_usable_rect(_screen_index)
	_decorations = _decoration_size()
	var available := _usable_rect.size - _decorations
	var requested := default_size_for_screen(_screen_size)
	if _local_slot >= 0:
		available.x = maxi(1, _usable_rect.size.x / 2 - _decorations.x - 24)
		requested = Vector2i(available.x, available.y)
	var target := fitted_window_size(requested, available)
	# Keep one fixed native client constraint while Windows moves across DPI
	# boundaries. Changing these constraints is deferred until release too.
	if _window.size != target or _window.min_size != target or _window.max_size != target:
		_unlock_constraints()
		if _window.size != target:
			_window.size = target
		_window.min_size = target
		_window.max_size = target
	if _local_slot >= 0:
		var half := _usable_rect.size.x / 2
		var inset := _window.position - DisplayServer.window_get_position_with_decorations(_window.get_window_id())
		_set_position(_usable_rect.position + Vector2i(_local_slot * half + (half - target.x - _decorations.x) / 2, (_usable_rect.size.y - target.y - _decorations.y) / 2) + inset)
	elif center:
		_center_window()
	else:
		_set_position(_clamped_position(_window.position))
	_last_position = _window.position
	_position_quiet_time = 0.0

func _clamped_position(position: Vector2i) -> Vector2i:
	var inset := _window.position - DisplayServer.window_get_position_with_decorations(_window.get_window_id())
	var outer := position - inset
	var end := _usable_rect.end - _window.size - _decorations
	outer.x = clampi(outer.x, _usable_rect.position.x, maxi(_usable_rect.position.x, end.x))
	outer.y = clampi(outer.y, _usable_rect.position.y, maxi(_usable_rect.position.y, end.y))
	return outer + inset

func _center_window() -> void:
	var inset := _window.position - DisplayServer.window_get_position_with_decorations(_window.get_window_id())
	_set_position(_usable_rect.position + (_usable_rect.size - _window.size - _decorations) / 2 + inset)

func _set_position(position: Vector2i) -> void:
	if _window.position != position:
		_window.position = position
