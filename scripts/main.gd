extends Node3D
## All rendering, UI, persistence and gameplay run in Godot. No browser runtime.
const ArenaScript = preload("res://scripts/arena.gd")
const WorldScript = preload("res://scripts/island_world.gd")
const UIScript = preload("res://scripts/game_ui.gd")
const StoreScript = preload("res://scripts/wardrobe_store.gd")
const NetworkScript = preload("res://scripts/room_network.gd")
const AudioScript = preload("res://scripts/game_audio.gd")
const CameraSettings = preload("res://scripts/camera_settings.gd")
const MATCH_INTRO_SECONDS: float = 1.6

var arena: Node3D
var island: Node3D
var ui: CanvasLayer
var store: RefCounted
var network: Node
var audio: Node
var mode: String = "solo"
var screen: String = "menu"
var local_id: String = "player"
var paused: bool = false
var spectating: bool = false
var last_snapshot: Dictionary = {}
var _send_age: float = 0.0
var _ui_age: float = 0.0
var _final_sync_seconds: float = 0.0
var _round_start_announced: bool = false
var _result_presentation_token: int = 0
var camera_config: RefCounted
var _camera_save_timer: Timer
var _camera_settings_dirty: bool = false

func _ready() -> void:
	_setup_input()
	store = StoreScript.new()
	store.load_profile()
	camera_config = CameraSettings.new()
	camera_config.load_profile()
	_camera_save_timer = Timer.new()
	_camera_save_timer.one_shot = true
	_camera_save_timer.wait_time = 0.35
	_camera_save_timer.timeout.connect(_save_camera_settings)
	add_child(_camera_save_timer)
	arena = ArenaScript.new()
	arena.name = "Arena"
	add_child(arena)
	island = WorldScript.new()
	island.camera_settings = camera_config.settings.duplicate(true)
	island.name = "IslandWorld"
	add_child(island)
	network = NetworkScript.new()
	network.name = "RoomNetwork"
	add_child(network)
	audio = AudioScript.new()
	add_child(audio)
	ui = UIScript.new()
	ui.name = "GameUI"
	add_child(ui)
	ui.setup(store)
	ui.set_camera_settings(camera_config.settings)
	ui.action.connect(_on_action)
	ui.selection_changed.connect(_selection_changed)
	arena.round_finished.connect(_round_finished)
	arena.impact_event.connect(_impact)
	network.room_changed.connect(func(state: Dictionary) -> void: ui.set_room(state))
	network.match_started.connect(_network_start)
	network.snapshot_received.connect(_network_snapshot)
	network.remote_input.connect(func(id: String, vector: Vector2) -> void: arena.set_input(id, vector.x, vector.y))
	network.remote_effect.connect(func(kind: String, target_id: String) -> void: _apply_effect(kind, target_id, "guest"))
	network.effect_result.connect(_effect_receipt)
	network.disconnected.connect(_disconnected)
	show_menu()

func _setup_input() -> void:
	var definitions: Dictionary = {
		"move_left":[KEY_A,KEY_LEFT],"move_right":[KEY_D,KEY_RIGHT],
		"move_up":[KEY_W,KEY_UP],"move_down":[KEY_S,KEY_DOWN],
		"pause_match":[KEY_ESCAPE],"add_npc":[KEY_N],"remove_npc":[KEY_M],
		"effect_1":[KEY_1],"effect_2":[KEY_2],"effect_3":[KEY_3],"effect_4":[KEY_4],"effect_5":[KEY_5]
	}
	for action_name: String in definitions:
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
		for key: int in definitions[action_name]:
			var event: InputEventKey = InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action_name, event)

func _physics_process(dt: float) -> void:
	if screen == "finished" and network.role == "host" and _final_sync_seconds > 0.0:
		_final_sync_seconds = maxf(0.0, _final_sync_seconds - dt)
		_send_age += dt
		if _send_age >= 0.08:
			_send_age = 0.0
			network.send_snapshot(arena.get_snapshot())
		return
	if screen != "playing" or paused:
		return
	var vector: Vector2 = Vector2.ZERO
	if _round_is_live() and not spectating and not ui.is_editing():
		vector = Input.get_vector("move_left", "move_right", "move_up", "move_down")
		var origin: Vector3 = Vector3.ZERO
		if network.role != "guest" and arena.entities.has(local_id):
			origin = arena.entities[local_id].global_position
		elif island.entities.has(local_id):
			origin = island.entities[local_id].global_position
		vector = island.screen_input_to_world(vector, origin)
	if network.role != "guest":
		arena.set_input(local_id, vector.x, vector.y)
	_send_age += dt
	if _send_age >= 0.04:
		_send_age = 0.0
		if network.role == "guest":
			network.send_input(vector)
		elif network.role == "host":
			network.send_snapshot(arena.get_snapshot())

func _process(dt: float) -> void:
	if screen in ["playing", "finished"]:
		if network.role != "guest":
			last_snapshot = arena.get_snapshot()
		if not last_snapshot.is_empty():
			island.update_entities(last_snapshot, local_id)
			island.wind_visual.update_wind(last_snapshot, 0.0 if paused else dt)
			audio.set_wind(island.wind_visual.active, island.wind_visual.visual_strength, paused)
			_update_spectating()
			_ui_age += dt
			var phase: String = str(last_snapshot.get("status", ""))
			# Numbers and the input gate change on the same rendered frame.
			if _ui_age > 0.08 or phase == "countdown" or str(ui.snapshot.get("status", "")) != phase:
				_ui_age = 0.0
				ui.update_snapshot(last_snapshot, local_id)
			if phase == "playing" and not _round_start_announced:
				_round_start_announced = true
				audio.play_tone("start")

func _round_is_live() -> bool:
	if network.role == "guest":
		return str(last_snapshot.get("status", "")) == "playing"
	return str(arena.status) == "playing"

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_match") and screen == "playing":
		if ui.camera_panel.visible:
			ui.close_modal()
		elif paused:
			_set_paused(false)
		elif ui.is_editing():
			ui.close_modal()
		else:
			_set_paused(not paused)
		get_viewport().set_input_as_handled()
		return
	if screen != "playing" or paused or ui.is_editing() or not _round_is_live():
		return
	if event.is_action_pressed("add_npc") or event.is_action_pressed("remove_npc"):
		if network.role == "guest":
			ui.toast("NPC 调整由房主操作")
		else:
			var result: Dictionary = arena.add_npc() if event.is_action_pressed("add_npc") else arena.remove_npc()
			ui.toast(str(result.get("message", "")))
	for i: int in range(5):
		if event.is_action_pressed("effect_%d" % (i + 1)):
			_request_effect(["grow","shrink","speedUp","speedDown","wind"][i], local_id)

func player_config(id: String, selection: Dictionary = {}) -> Dictionary:
	var selected: Dictionary = store.selection if selection.is_empty() else selection
	return {"id":id,"name":"玩家2" if id == "guest" else "玩家1", "animal":selected.get("animal", "rabbit"), "character":selected.get("character", {}).duplicate(true),"ball":selected.get("ball", {}).duplicate(true),"human":true}

func start_solo() -> void:
	_result_presentation_token += 1
	island.reset_match_camera()
	network.close_room()
	_set_paused(false)
	if is_instance_valid(island): island.wind_visual.clear()
	if is_instance_valid(audio): audio.set_wind(false)
	spectating = false
	_final_sync_seconds = 0.0
	_round_start_announced = false
	mode = "solo"
	local_id = "player"
	screen = "playing"
	arena.start([player_config("player")], 5, 3.0, MATCH_INTRO_SECONDS)
	last_snapshot = arena.get_snapshot()
	island.update_entities(last_snapshot, local_id)
	ui.show_match(mode)
	ui.update_snapshot(last_snapshot, local_id)

func show_menu() -> void:
	_result_presentation_token += 1
	_set_paused(false)
	if is_instance_valid(audio): audio.set_wind(false)
	spectating = false
	_final_sync_seconds = 0.0
	_round_start_announced = false
	arena.clear_round()
	screen = "menu"
	last_snapshot.clear()
	ui.show_menu()
	island.show_preview(store.selection)

func _selection_changed(selection: Dictionary) -> void:
	if screen == "menu":
		island.show_preview(selection)

func _on_action(action_name: String, payload: Dictionary) -> void:
	if action_name not in ["camera_settings", "preview_rotate"]: audio.play_tone("click")
	match action_name:
		"preview_rotate":
			if screen == "menu": island.rotate_preview(float(payload.get("delta", 0.0)))
		"camera_settings":
			if camera_config.update_scope(str(payload.get("scope", "")), payload.get("values", {})):
				_apply_camera_preferences(str(payload.get("scope", "")))
		"camera_reset":
			if camera_config.reset_scope(str(payload.get("scope", ""))):
				_apply_camera_preferences(str(payload.get("scope", "")))
		"camera_preview": _preview_camera(str(payload.get("scope", "victory")))
		"camera_preview_end":
			island.end_camera_preview()
			if screen == "menu":
				ui.menu.show()
				ui.set_preview_drag_enabled(true)
		"start_solo": start_solo()
		"start_pk":
			if not network.start_match():
				ui.toast("请先创建房间，并等待另一位主播加入")
		"create_room":
			var result: Dictionary = network.create_room(player_config("host"), int(payload.get("port", 54130)))
			ui.toast(str(result.get("message", "")))
		"join_room":
			var result: Dictionary = network.join_room(player_config("guest"), str(payload.get("address", "127.0.0.1")), int(payload.get("port", 54130)))
			ui.toast(str(result.get("message", "")))
		"leave_room":
			network.close_room()
			show_menu()
		"effect": _request_effect(str(payload.get("kind", "")), str(payload.get("targetId", local_id)))
		"pause": _set_paused(true)
		"resume": _set_paused(false)
		"restart":
			if mode == "pk":
				if network.role == "host": network.start_match()
				else: ui.toast("请等待房主开始下一局")
			else: start_solo()
		"home":
			network.close_room()
			show_menu()
		"quality": island.set_quality(bool(payload.get("high", true)))
		"quit": get_tree().quit()

func _apply_camera_preferences(scope: String) -> void:
	island.apply_camera_settings(camera_config.settings)
	ui.set_camera_settings(camera_config.settings)
	if screen == "menu": _preview_camera(scope)
	_camera_settings_dirty = true
	_camera_save_timer.start()

func _preview_camera(scope: String) -> void:
	island.preview_camera(scope, local_id)
	if screen == "menu" and not island.camera_preview_scope.is_empty():
		ui.set_preview_drag_enabled(false)
		ui.menu.hide()

func _save_camera_settings() -> void:
	if not _camera_settings_dirty: return
	if camera_config.save_profile():
		_camera_settings_dirty = false
	else:
		ui.toast("镜头设置暂未保存，请检查存档目录")

func _exit_tree() -> void:
	if _camera_settings_dirty and camera_config != null: camera_config.save_profile()

func _set_paused(value: bool) -> void:
	if value and mode == "pk":
		ui.toast("联机比赛持续进行，不能暂停")
		return
	if value and (screen != "playing" or spectating):
		return
	paused = value
	if is_instance_valid(arena): arena.set_paused(value)
	if is_instance_valid(island): island.set_motion_paused(value)
	if is_instance_valid(ui): ui.set_paused(value)

func _request_effect(kind: String, target_id: String) -> void:
	if target_id.is_empty(): target_id = local_id
	if screen != "playing" or paused or spectating or not _round_is_live():
		ui.toast("比赛进行时才可触发互动")
		return
	if network.role == "guest":
		network.request_effect(kind, target_id)
	else:
		_apply_effect(kind, target_id, "host" if network.role == "host" else "player")

func _apply_effect(kind: String, target_id: String, actor: String) -> void:
	var result: Dictionary = arena.apply_effect(target_id, kind)
	result["kind"] = kind
	result["targetId"] = target_id
	if bool(result.get("ok", false)):
		if actor == local_id:
			store.award_points(10)
		if kind != "wind": audio.play_tone("gift")
	ui.toast(str(result.get("message", "")))
	if network.role == "host": network.send_effect_result(result, actor)

func _effect_receipt(result: Dictionary, actor: String) -> void:
	if bool(result.get("ok", false)) and actor == "guest":
		store.award_points(10)
		if str(result.get("kind", "")) != "wind": audio.play_tone("gift")
	ui.toast(str(result.get("message", "")))

func _impact(data: Dictionary) -> void:
	island.impact(data)
	audio.play_tone("impact")

func _round_finished(snapshot: Dictionary) -> void:
	screen = "finished"
	spectating = false
	last_snapshot = snapshot
	_present_round_result(snapshot)
	audio.play_tone("finish")
	if network.role == "host":
		_final_sync_seconds = 1.2
		network.send_snapshot(snapshot)

func _present_round_result(snapshot: Dictionary) -> void:
	_result_presentation_token += 1
	var token: int = _result_presentation_token
	ui.show_finish_focus()
	island.update_entities(snapshot, local_id)
	island.focus_winner(str(snapshot.get("winnerId", "")), 2.0)
	await get_tree().create_timer(2.05).timeout
	if token != _result_presentation_token or screen != "finished": return
	ui.show_result(last_snapshot)

func _network_start(players: Array) -> void:
	_result_presentation_token += 1
	island.reset_match_camera()
	paused = false
	spectating = false
	_final_sync_seconds = 0.0
	_round_start_announced = false
	mode = "pk"
	local_id = network.role
	screen = "playing"
	if network.role == "host":
		arena.start(players, 4, 3.0, MATCH_INTRO_SECONDS)
		last_snapshot = arena.get_snapshot()
		island.update_entities(last_snapshot, local_id)
	else:
		arena.clear_round()
		last_snapshot = {}
	ui.show_match(mode)
	if not last_snapshot.is_empty():
		ui.update_snapshot(last_snapshot, local_id)

func _update_spectating() -> void:
	if screen != "playing" or mode != "solo" or spectating or not _round_is_live():
		return
	for entity: Dictionary in last_snapshot.get("entities", []):
		if str(entity.get("id", "")) != local_id:
			continue
		if bool(entity.get("falling", false)) or not bool(entity.get("alive", true)):
			spectating = true
			_set_paused(false)
			arena.set_input(local_id, 0.0, 0.0)
			ui.show_spectator()
		return

func _network_snapshot(snapshot: Dictionary) -> void:
	if screen == "finished" and snapshot.get("status", "") != "finished":
		return
	last_snapshot = snapshot
	if snapshot.get("status", "") == "finished" and screen != "finished":
		screen = "finished"
		_present_round_result(snapshot)
		audio.play_tone("finish")

func _disconnected(reason: String) -> void:
	show_menu()
	ui.toast(reason)
