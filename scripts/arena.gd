extends Node3D
class_name IslandArena

const BallBody = preload("res://scripts/ball_body.gd")
const CollisionModel = preload("res://scripts/collision_model.gd")
const IslandStage = preload("res://scripts/island_stage.gd")
const ISLAND_RADIUS: float = 8.8
const EFFECT_SECONDS: float = 3.0
const SIZE_EFFECT_SECONDS: float = 8.0
const SPAWN_RING_RADIUS: float = 2.6
const SPAWN_MIN_SEPARATION: float = 1.8
const PALETTES: Array = [
	["#f6be69", "#fff0cc", "#e97e53"], ["#b7d9d6", "#fff5df", "#598f9c"],
	["#b7b4e9", "#fff0e6", "#7972b9"], ["#f5b8c5", "#fff0dd", "#bc6c88"],
	["#c9dba1", "#fff5dc", "#648558"], ["#e8c4a4", "#ffefdc", "#9d7055"],
]

signal round_finished(snapshot: Dictionary)
signal impact_event(data: Dictionary)

var status: String = "ready"
var entities: Dictionary = {}
var ai_enabled: bool = true
var winner_id: String = ""
var clock: float = 0.0
var _paused: bool = false
var _next_npc: int = 0
var _platform: StaticBody3D
var _active_contacts: Dictionary = {}
var _pending_contacts: Dictionary = {}
var _ai_state: Dictionary = {}
var _random: RandomNumberGenerator = RandomNumberGenerator.new()
var _wind_random: RandomNumberGenerator = RandomNumberGenerator.new()
var _wind_expires: float = 0.0
var _wind_direction: Vector3 = Vector3.RIGHT
var _countdown_remaining: float = 0.0
var intro_remaining: float = 0.0
var intro_duration: float = 0.0

func _ready() -> void:
	# Wind has its own random stream, independent of the reproducible NPC AI.
	# It is seeded once, never reset when another round starts.
	_wind_random.randomize()
	_create_platform()

func _create_platform() -> void:
	if is_instance_valid(_platform):
		return
	_platform = StaticBody3D.new()
	_platform.name = "IslandCollision"
	var collider: CollisionShape3D = CollisionShape3D.new()
	# Match the actual flat grass triangles, including the local coves. Trees,
	# stones and flowers are visual decorations and create no rigid obstacles.
	collider.shape = IslandStage.collision_shape()
	_platform.add_child(collider)
	var material: PhysicsMaterial = PhysicsMaterial.new()
	material.friction = 0.0
	material.bounce = 0.0
	_platform.physics_material_override = material
	add_child(_platform)

func clear_round() -> void:
	for value: Variant in entities.values():
		var body: IslandBallBody = value
		remove_child(body)
		body.queue_free()
	entities.clear()
	_active_contacts.clear()
	_pending_contacts.clear()
	_ai_state.clear()
	status = "ready"
	clock = 0.0
	winner_id = ""
	_paused = false
	_wind_expires = 0.0
	_countdown_remaining = 0.0
	intro_remaining = 0.0
	intro_duration = 0.0

func start(players: Array, npc_count: int = 5, countdown_seconds: float = 0.0, intro_seconds: float = 0.0) -> void:
	clear_round()
	_create_platform()
	_random.seed = 12345678
	var configs: Array = players.duplicate(true)
	for index: int in range(clampi(npc_count, 0, 10)):
		configs.append(_npc_config(index))
	# An empty roster is not a match and must never create a zero-survivor result.
	if configs.is_empty():
		return
	_next_npc = maxi(0, npc_count)
	var radius: float = _spawn_ring_radius(configs.size())
	for index: int in range(configs.size()):
		var angle: float = float(index) / maxi(1, configs.size()) * TAU - PI / 2.0
		_spawn(configs[index], Vector3(cos(angle) * radius, 0.725, sin(angle) * radius))
	_countdown_remaining = maxf(0.0, countdown_seconds)
	intro_duration = maxf(0.0, intro_seconds)
	intro_remaining = intro_duration
	status = "intro" if intro_remaining > 0.0 else ("countdown" if _countdown_remaining > 0.0 else "playing")
	if status in ["intro", "countdown"]:
		for value: Variant in entities.values():
			var body: IslandBallBody = value
			body.freeze = true
	else:
		_check_finish()

func _spawn_ring_radius(count: int) -> float:
	if count <= 1:
		return 0.0
	# Chord length is 2*r*sin(PI/n): six balls start 2.6m apart,
	# and even twelve retain a 0.4m gap between their 1.4m diameters.
	return maxf(SPAWN_RING_RADIUS, SPAWN_MIN_SEPARATION / (2.0 * sin(PI / float(count))))

func _npc_config(index: int) -> Dictionary:
	var animals: Array[String] = ["rabbit", "bear", "pig", "cat", "dog", "fox", "panda", "raccoon"]
	var names: Array[String] = ["团团", "胖达", "桃桃", "松松", "泡泡", "栗栗", "啵啵", "糯糯", "绵绵", "豆豆"]
	var ball_colors: Array[String] = ["#F1B7B0", "#B9DDE0", "#BEDDBA", "#F5DE98", "#D5C3E5", "#EFC9B1", "#BDCFEB"]
	var ball_color: String = ball_colors[index % ball_colors.size()]
	return {"id": "npc-%d" % index, "name": names[index] if index < names.size() else "新伙伴%d" % (index + 1),
		"animal": animals[index % animals.size()], "human": false,
		"character": {},
		"ball": {"colors": [ball_color,ball_color,ball_color]}}

func _spawn(config: Dictionary, location: Vector3) -> IslandBallBody:
	var body: IslandBallBody = BallBody.new()
	body.configure(config, self)
	body.wind_direction = _wind_direction
	body.position = location
	add_child(body)
	entities[str(config["id"])] = body
	_ai_state[str(config["id"])] = {"target": "", "think": 0.0, "phase": _random.randf() * TAU, "chargeUntil": 0.0, "chargeReady": 0.0, "charge": Vector3.ZERO,
		"windMode": "none", "windReactAt": 0.0, "windStrength": 0.0, "windUntil": 0.0, "windReacted": false}
	if _wind_expires > clock:
		body.effect_layers.append({"kind": "wind", "expires": _wind_expires})
	return body

func set_input(id: String, x: float, z: float) -> void:
	if status != "playing" or not entities.has(id):
		return
	var body: IslandBallBody = entities[id]
	if body.alive and bool(body.config.get("human", false)):
		body.input_direction = Vector3(x, 0.0, z).limit_length(1.0)

func apply_effect(id: String, kind: String) -> Dictionary:
	if status != "playing":
		return {"ok": false, "message": "比赛开始后才可互动"}
	if not entities.has(id):
		return {"ok": false, "message": "目标不存在"}
	var body: IslandBallBody = entities[id]
	if not body.alive or body.falling:
		return {"ok": false, "message": "目标已落海，本次互动未触发"}
	var caps: Dictionary = {"grow": 10, "shrink": 5, "speedUp": 5, "speedDown": 4, "wind": 1}
	if not caps.has(kind):
		return {"ok": false, "message": "未知互动"}
	if kind == "wind":
		if _wind_expires > clock:
			return {"ok": false, "message": "侧风正在持续，请等风停后再试"}
		var angle: float = _wind_random.randf_range(0.0, TAU)
		_wind_direction = Vector3(cos(angle), 0.0, sin(angle))
		_wind_expires = clock + EFFECT_SECONDS
		for value: Variant in entities.values():
			var target: IslandBallBody = value
			if target.alive and not target.falling:
				target.wind_direction = _wind_direction
				target.effect_layers.append({"kind": kind, "expires": _wind_expires})
		_assign_wind_responses()
		return {"ok": true, "message": "全场侧风来袭"}
	if int(body.counts()[kind]) >= int(caps[kind]):
		return {"ok": false, "message": "该效果已达到叠加上限"}
	var duration: float = SIZE_EFFECT_SECONDS if kind == "grow" or kind == "shrink" else EFFECT_SECONDS
	body.effect_layers.append({"kind": kind, "expires": clock + duration})
	body.update_size()
	var labels: Dictionary = {"grow": "大球 +10%", "shrink": "小球 −10%", "speedUp": "速度 +20%", "speedDown": "速度 −20%"}
	return {"ok": true, "message": "%s · %s" % [body.config.get("name", "玩家"), labels[kind]]}

func _assign_wind_responses() -> void:
	var npcs: Array[IslandBallBody] = []
	for body: IslandBallBody in _alive_bodies():
		if not bool(body.config.get("human", false)):
			npcs.append(body)
	var kinds: Array[String] = ["quick", "delayed", "none"]
	var modes: Array[String] = []
	for index: int in range(npcs.size()):
		# A normal five-NPC match always includes all three responses. Smaller
		# rosters still draw randomly; extra slots do not force one fixed pattern.
		modes.append(kinds[index] if npcs.size() >= 3 and index < 3 else kinds[_wind_random.randi_range(0, 2)])
	for index: int in range(modes.size() - 1, 0, -1):
		var other: int = _wind_random.randi_range(0, index)
		var saved: String = modes[index]
		modes[index] = modes[other]
		modes[other] = saved
	for index: int in range(npcs.size()):
		var body: IslandBallBody = npcs[index]
		var state: Dictionary = _ai_state[str(body.config["id"])]
		var mode: String = modes[index]
		state["windMode"] = mode
		state["windReactAt"] = clock + (_wind_random.randf_range(0.35, 1.0) if mode == "delayed" else 0.0)
		state["windStrength"] = 1.0 if mode == "quick" else (_wind_random.randf_range(0.45, 0.85) if mode == "delayed" else 0.0)
		state["windUntil"] = _wind_expires
		state["windReacted"] = false
		if mode == "quick" and ai_enabled:
			_activate_wind_response(body, state)

func _activate_wind_response(body: IslandBallBody, state: Dictionary) -> void:
	# Interrupt a charge only once this particular NPC actually reacts. Those
	# that ignore the gust continue through the ordinary AI, including its charge.
	state["chargeUntil"] = clock
	state["charge"] = Vector3.ZERO
	state["windReacted"] = true
	body.input_direction = -_wind_direction * float(state["windStrength"])

func add_npc() -> Dictionary:
	if status != "playing":
		return {"ok": false, "message": "比赛开始后才可加入NPC"}
	if _alive_bodies().size() >= 12:
		return {"ok": false, "message": "场上最多12名参赛者"}
	var best: Vector3 = Vector3.ZERO
	var best_clearance: float = -1.0
	for index: int in range(20):
		var angle: float = float(index) / 20.0 * TAU
		var candidate: Vector3 = Vector3(cos(angle) * 5.4, 0.725, sin(angle) * 5.4)
		var clearance: float = 1000.0
		for other: IslandBallBody in _alive_bodies():
			clearance = minf(clearance, Vector2(candidate.x - other.position.x, candidate.z - other.position.z).length() - 0.7 * other.ball_scale)
		if clearance > best_clearance:
			best_clearance = clearance
			best = candidate
	var config: Dictionary = _npc_config(_next_npc)
	_next_npc += 1
	_spawn(config, best)
	return {"ok": true, "message": "%s加入了比赛" % config["name"]}

func remove_npc() -> Dictionary:
	if status != "playing":
		return {"ok": false, "message": "比赛开始后才可减少NPC"}
	var ids: Array = entities.keys()
	ids.reverse()
	for id: Variant in ids:
		var body: IslandBallBody = entities[id]
		if not bool(body.config.get("human", false)) and body.alive and not body.falling:
			body.alive = false
			body.withdrawn = true
			body.effect_layers.clear()
			body.freeze = true
			body.collision_layer = 0
			body.collision_mask = 0
			_check_finish()
			return {"ok": true, "message": "%s已离场" % body.config["name"]}
	return {"ok": false, "message": "场上没有可移除的NPC"}

func queue_contact(a: IslandBallBody, b: IslandBallBody) -> void:
	if status != "playing" or not a.alive or not b.alive or a.falling or b.falling:
		return
	var id_a: String = str(a.config["id"])
	var id_b: String = str(b.config["id"])
	var key: String = id_a + "|" + id_b if id_a < id_b else id_b + "|" + id_a
	if _active_contacts.has(key) or _pending_contacts.has(key):
		return
	# Contact callbacks can run before one body's integration and after the
	# other's. Read both incoming motions from the same completed physics step.
	var incoming_frame: int = mini(a.get_motion_frame(), b.get_motion_frame())
	_pending_contacts[key] = {"a": a, "b": b, "va": a.get_motion_at(incoming_frame), "vb": b.get_motion_at(incoming_frame), "incomingFrame": incoming_frame}

func _resolve_contacts() -> void:
	for key: Variant in _active_contacts.keys():
		var pair: Array = _active_contacts[key]
		var a: IslandBallBody = pair[0]
		var b: IslandBallBody = pair[1]
		var separated: bool = a.position.distance_to(b.position) > (a.ball_scale + b.ball_scale) * 0.7 + 0.02
		var native_contact_ended: bool = not a.get_colliding_bodies().has(b) and not b.get_colliding_bodies().has(a)
		if not a.alive or not b.alive or (separated and native_contact_ended):
			_active_contacts.erase(key)
	for key: Variant in _pending_contacts.keys():
		var pair: Dictionary = _pending_contacts[key]
		var a: IslandBallBody = pair["a"]
		var b: IslandBallBody = pair["b"]
		if not a.alive or not b.alive or a.falling or b.falling:
			continue
		var result: Dictionary = CollisionModel.solve(pair["va"], pair["vb"], a.mass, b.mass, b.position - a.position)
		# Contact caches can report the departing pair for another frame. A new
		# impact needs actual approach, not just a cached/resting contact manifold.
		# Even an arbitrarily gentle positive approach receives the minimum kick.
		if float(result["closingSpeed"]) <= 0.0001:
			continue
		_active_contacts[key] = [a, b]
		var event: Dictionary = {"a": a.config["id"], "b": b.config["id"], "x": (a.position.x + b.position.x) * 0.5,
			"y": maxf(a.position.y, b.position.y), "z": (a.position.z + b.position.z) * 0.5,
			"closingSpeed": result["closingSpeed"], "impulse": result["impulse"],
			"distanceA": result["distanceA"], "distanceB": result["distanceB"],
			"appliedDistanceA": result["appliedDistanceA"], "appliedDistanceB": result["appliedDistanceB"],
			"nativeContactBudgetA": result["nativeContactBudgetA"], "nativeContactBudgetB": result["nativeContactBudgetB"],
			"normalBeforeA": result["normalBeforeA"], "normalBeforeB": result["normalBeforeB"],
			"normalAfterA": result["normalAfterA"], "normalAfterB": result["normalAfterB"],
			"outwardA": result["outwardA"], "outwardB": result["outwardB"],
			"normalX": Vector3(result["normal"]).x, "normalZ": Vector3(result["normal"]).z,
			"duration": result["duration"], "at": clock,
			"incomingFrame": pair["incomingFrame"], "motionFrame": pair["incomingFrame"],
			"responseMode": result.get("responseMode", "outgoing"),
			"sharedScale": result.get("sharedScale", 1.0)}
		a.receive_collision(result["kickA"], result["baselineA"], event, result.get("channelA", {}))
		b.receive_collision(result["kickB"], result["baselineB"], event, result.get("channelB", {}))
		impact_event.emit(event)
	_pending_contacts.clear()

func _physics_process(delta: float) -> void:
	if _paused:
		return
	if status == "intro":
		intro_remaining = maxf(0.0, intro_remaining - delta)
		if intro_remaining <= 0.0:
			status = "countdown" if _countdown_remaining > 0.0 else "playing"
			if status == "playing":
				for value: Variant in entities.values():
					var body: IslandBallBody = value
					body.freeze = false
				_check_finish()
		# The complete countdown starts on the next physics step. Neither its
		# three seconds nor the match clock is consumed by the camera approach.
		return
	if status == "countdown":
		_countdown_remaining = maxf(0.0, _countdown_remaining - delta)
		if _countdown_remaining <= 0.0:
			status = "playing"
			for value: Variant in entities.values():
				var body: IslandBallBody = value
				body.freeze = false
			_check_finish()
		# The match clock begins on the next playing step, never during countdown.
		return
	# Eliminated contestants continue their native fall even after the winner is
	# known. This visual cleanup never advances the settled match's elapsed time.
	_settle_fallen_bodies()
	if status != "playing":
		return
	clock += delta
	_resolve_contacts()
	# Dictionary registration order is stable for the roster. Resolve a frame's
	# falling events in that order and finish immediately at one survivor, rather
	# than eliminating the final two in a batch and producing zero survivors.
	for id: Variant in entities.keys():
		var body: IslandBallBody = entities[id]
		if not body.alive:
			continue
		body.expire_effects(clock)
		var radial: float = Vector2(body.position.x, body.position.z).length()
		var left_stage: bool = body.position.y < 0.7 * body.ball_scale - 0.4 and IslandStage.signed_edge_distance(Vector2(body.position.x, body.position.z)) < 0.1
		if body.falling or left_stage or body.position.y < -2.2 or radial > 13.0:
			body.rank = _alive_bodies().size()
			body.alive = false
			body.falling = true
			body.effect_layers.clear()
			body.input_direction = Vector3.ZERO
			# Falling is elimination, not a freeze in mid-air. The RigidBody keeps
			# its velocity and native gravity until it sinks beneath the sea.
			if body.position.y < -2.2 or radial > 13.0:
				_freeze_fallen_body(body)
			_check_finish()
			if status == "finished":
				return
		elif not bool(body.config.get("human", false)):
			body.input_direction = _npc_input(body) if ai_enabled else Vector3.ZERO
	_check_finish()

func _freeze_fallen_body(body: IslandBallBody) -> void:
	body.mark_water_entry()
	body.freeze = true
	body.collision_layer = 0
	body.collision_mask = 0

func _settle_fallen_bodies() -> void:
	for value: Variant in entities.values():
		var body: IslandBallBody = value
		body.mark_water_entry()
		if not body.alive and body.falling and not body.freeze:
			if body.position.y < -2.2 or Vector2(body.position.x, body.position.z).length() > 13.0:
				_freeze_fallen_body(body)

func _npc_input(body: IslandBallBody) -> Vector3:
	var id: String = str(body.config["id"])
	var state: Dictionary = _ai_state[id]
	var p: Vector3 = body.position
	var v: Vector3 = body.linear_velocity
	if _wind_expires > clock and float(state["windUntil"]) > clock and str(state["windMode"]) != "none" and clock >= float(state["windReactAt"]):
		if not bool(state["windReacted"]):
			_activate_wind_response(body, state)
		return -_wind_direction * float(state["windStrength"])
	if float(state["chargeUntil"]) > clock:
		return state["charge"]
	var projected: Vector2 = Vector2(p.x + v.x * 0.45, p.z + v.z * 0.45)
	if IslandStage.signed_edge_distance(projected) < 1.2:
		return (-Vector3(p.x, 0.0, p.z).normalized() - Vector3(v.x, 0.0, v.z) * 0.12).limit_length(1.0)
	if clock > float(state["think"]):
		var target_id: String = ""
		var targets: Array[IslandBallBody] = []
		for other: IslandBallBody in _alive_bodies():
			if other == body or other.falling:
				continue
			targets.append(other)
		targets.sort_custom(func(left: IslandBallBody, right: IslandBallBody) -> bool:
			return Vector2(left.position.x - p.x, left.position.z - p.z).length_squared() < Vector2(right.position.x - p.x, right.position.z - p.z).length_squared())
		var target_index: int = 0 if _random.randf() < 0.78 else 1
		if not targets.is_empty():
			target_id = str(targets[mini(target_index, targets.size() - 1)].config["id"])
		state["target"] = target_id
		state["think"] = clock + 0.6 + _random.randf() * 0.8
	var target: IslandBallBody = entities.get(str(state["target"]))
	if not is_instance_valid(target) or not target.alive:
		return (-Vector3(p.x, 0.0, p.z) * 0.2).limit_length(1.0)
	var difference: Vector3 = Vector3(target.position.x - p.x, 0.0, target.position.z - p.z)
	var distance: float = maxf(0.01, difference.length())
	var outward: Vector3 = Vector3(target.position.x, 0.0, target.position.z).normalized() if Vector2(target.position.x, target.position.z).length() > 1.2 else difference.normalized()
	var aligned: bool = difference.dot(outward) / distance > 0.3
	if distance < 3.2 and aligned and clock > float(state["chargeReady"]):
		var charge: Vector3 = (difference + Vector3(target.linear_velocity.x, 0.0, target.linear_velocity.z) * 0.15 + outward).normalized()
		state["charge"] = charge
		state["chargeUntil"] = clock + 0.75 + _random.randf() * 0.5
		state["chargeReady"] = float(state["chargeUntil"]) + 1.2 + _random.randf()
		return charge
	var aim: Vector3 = target.position - outward * 2.5 - p if not aligned and distance < 4.0 else difference
	aim.y = 0.0
	aim = aim.normalized()
	var orbit: float = sin(clock * 0.8 + float(state["phase"])) * 0.22
	var courage: float = 0.92 + sin(float(state["phase"])) * 0.08
	var centering: float = 0.015 if Vector2(p.x, p.z).length() > 6.0 else 0.0
	return Vector3((aim.x - aim.z * orbit - p.x * centering) * courage, 0.0, (aim.z + aim.x * orbit - p.z * centering) * courage).limit_length(1.0)

func _alive_bodies() -> Array[IslandBallBody]:
	var result: Array[IslandBallBody] = []
	for value: Variant in entities.values():
		var body: IslandBallBody = value
		if body.alive and not body.falling:
			result.append(body)
	return result

func _check_finish() -> void:
	if status != "playing":
		return
	var alive: Array[IslandBallBody] = _alive_bodies()
	if alive.size() == 1:
		status = "finished"
		winner_id = str(alive[0].config["id"])
		alive[0].rank = 1
	if status == "finished":
		for value: Variant in entities.values():
			var body: IslandBallBody = value
			if body.alive or body.withdrawn:
				body.freeze = true
		round_finished.emit(get_snapshot())

func set_paused(value: bool) -> void:
	_paused = value
	for body_value: Variant in entities.values():
		var body: IslandBallBody = body_value
		body.simulation_paused = value
		var submerged: bool = body.falling and (body.position.y < -2.2 or Vector2(body.position.x, body.position.z).length() > 13.0)
		body.freeze = value or status in ["intro", "countdown"] or body.withdrawn or submerged or (body.alive and status == "finished")

func get_snapshot() -> Dictionary:
	var snapshots: Array[Dictionary] = []
	for value: Variant in entities.values():
		var body: IslandBallBody = value
		snapshots.append(body.get_snapshot())
	var wind_remaining: float = maxf(0.0, _wind_expires - clock) if status == "playing" else 0.0
	return {"status": status, "elapsedSeconds": clock, "countdownRemaining": _countdown_remaining,
		"introRemaining": intro_remaining, "introDuration": intro_duration,
		"winnerId": winner_id if not winner_id.is_empty() else null,
		"entities": snapshots, "wind": {"active": wind_remaining > 0.0, "remaining": wind_remaining,
			"duration": EFFECT_SECONDS, "direction": {"x": _wind_direction.x, "y": _wind_direction.y, "z": _wind_direction.z}}}
