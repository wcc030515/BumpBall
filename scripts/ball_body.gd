extends RigidBody3D
class_name IslandBallBody

const CollisionModel = preload("res://scripts/collision_model.gd")
const IslandStage = preload("res://scripts/island_stage.gd")
const BASE_RADIUS: float = 0.7
const BASE_SPEED: float = 5.8
const DRIVE_RESPONSE: float = 4.0
const DRIVE_ACCELERATION: float = 18.0
const WIND_FORCE_MAGNITUDE: float = 120.0
const WIND_DRAG: float = 6.0

var config: Dictionary = {}
var arena: Node3D
var ball_scale: float = 1.0
var base_size: float = 1.0
var base_speed: float = 1.0
var alive: bool = true
var falling: bool = false
var withdrawn: bool = false
var water_entry: Dictionary = {}
var rank: int = 0
var input_direction: Vector3 = Vector3.ZERO
var control_velocity: Vector3 = Vector3.ZERO
var knockback_velocity: Vector3 = Vector3.ZERO
var wind_velocity: Vector3 = Vector3.ZERO
var wind_direction: Vector3 = Vector3.RIGHT
var pre_step_velocity: Vector3 = Vector3.ZERO
var effect_layers: Array[Dictionary] = []
var collision_count: int = 0
var last_impact: Dictionary = {}
var simulation_paused: bool = false
var _shape: SphereShape3D
var _collision_shape: CollisionShape3D
var _pending_hit: Dictionary = {}
var _recovery: float = 0.0
var _impact_axis: Vector3 = Vector3.ZERO
var _impact_speed: float = 0.0
var _impact_remaining: float = 0.0
var _impact_drive_floor: float = 0.0
var _preserve_drive: bool = false
var _motion_frame: int = -1
var _motion_history: Dictionary = {}

func configure(player: Dictionary, owner_arena: Node3D) -> void:
	config = player.duplicate(true)
	arena = owner_arena
	name = str(config.get("id", "ball"))
	var human: bool = bool(config.get("human", false))
	base_size = 1.0 if human else clampf(float(config.get("baseSize", 1.0)), 0.75, 1.25)
	base_speed = 1.0 if human else clampf(float(config.get("baseSpeed", 1.0)), 0.75, 1.25)
	config["baseSize"] = base_size
	config["baseSpeed"] = base_speed
	if human:
		config.erase("npcProfileId")
	ball_scale = base_size
	mass = 5.0 * ball_scale
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 16
	can_sleep = false
	lock_rotation = true
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	gravity_scale = 1.0
	var material: PhysicsMaterial = PhysicsMaterial.new()
	# No second bounce/friction pass: uniform slide deceleration is applied below.
	material.bounce = 0.0
	material.friction = 0.0
	physics_material_override = material
	_shape = SphereShape3D.new()
	_shape.radius = BASE_RADIUS * ball_scale
	_collision_shape = CollisionShape3D.new()
	_collision_shape.shape = _shape
	add_child(_collision_shape)
	_reset_motion_history(Vector3.ZERO)

func _reset_motion_history(velocity: Vector3) -> void:
	_motion_history.clear()
	_motion_frame = Engine.get_physics_frames()
	pre_step_velocity = Vector3(velocity.x, 0.0, velocity.z)
	# A newly spawned body already has a known incoming state. The
	# previous-frame entry lets a first callback align with an existing neighbour.
	_motion_history[_motion_frame - 1] = {"velocity": pre_step_velocity, "response": Vector3.ZERO, "wind": Vector3.ZERO}
	_motion_history[_motion_frame] = {"velocity": pre_step_velocity, "response": Vector3.ZERO, "wind": Vector3.ZERO}

func _record_motion(velocity: Vector3, response: Vector3, wind: Vector3 = Vector3.ZERO) -> void:
	_motion_frame = Engine.get_physics_frames()
	pre_step_velocity = Vector3(velocity.x, 0.0, velocity.z)
	_motion_history[_motion_frame] = {"velocity": pre_step_velocity, "response": response, "wind": wind}
	for frame: Variant in _motion_history.keys():
		if int(frame) < _motion_frame - 8:
			_motion_history.erase(frame)

func get_motion_frame() -> int:
	return _motion_frame

func _motion_record_at(frame: int) -> Dictionary:
	if _motion_history.has(frame):
		return _motion_history[frame]
	var nearest_frame: int = -9223372036854775807
	for recorded: Variant in _motion_history.keys():
		var recorded_frame: int = int(recorded)
		if recorded_frame <= frame and recorded_frame > nearest_frame:
			nearest_frame = recorded_frame
	if _motion_history.has(nearest_frame):
		return _motion_history[nearest_frame]
	return {"velocity": pre_step_velocity, "response": Vector3.ZERO, "wind": wind_velocity}

func get_motion_at(frame: int) -> Vector3:
	return Vector3(_motion_record_at(frame)["velocity"])

func counts() -> Dictionary:
	var result: Dictionary = {"grow": 0, "shrink": 0, "speedUp": 0, "speedDown": 0, "wind": 0}
	for layer: Dictionary in effect_layers:
		var kind: String = str(layer["kind"])
		result[kind] = int(result[kind]) + 1
	return result

func expire_effects(clock: float) -> void:
	var kept: Array[Dictionary] = []
	for layer: Dictionary in effect_layers:
		if float(layer["expires"]) > clock:
			kept.append(layer)
	if kept.size() != effect_layers.size():
		effect_layers = kept
		update_size()

func update_size() -> void:
	var layers: Dictionary = counts()
	var next_scale: float = clampf(base_size + 0.1 * (int(layers["grow"]) - int(layers["shrink"])), 0.5, 2.0)
	if is_equal_approx(next_scale, ball_scale):
		return
	var old_radius: float = BASE_RADIUS * ball_scale
	var grounded: bool = not falling and position.y > old_radius - 0.15 and IslandStage.contains_point(Vector2(position.x, position.z))
	ball_scale = next_scale
	mass = 5.0 * ball_scale
	_shape.radius = BASE_RADIUS * ball_scale
	if grounded:
		position.y = maxf(position.y + BASE_RADIUS * ball_scale - old_radius, BASE_RADIUS * ball_scale + 0.01)

func speed_factor() -> float:
	var layers: Dictionary = counts()
	return clampf(base_speed + 0.2 * (int(layers["speedUp"]) - int(layers["speedDown"])), 0.2, 2.0)

func receive_collision(kick: Vector3, baseline: Vector3, event: Dictionary, channel: Dictionary = {}) -> void:
	var normal: Vector3 = Vector3(channel.get("normal", kick.normalized()))
	if normal.length_squared() < 0.5:
		normal = Vector3(float(event.get("normalX", 1.0)), 0.0, float(event.get("normalZ", 0.0))).normalized()
	var final_velocity: Vector3 = baseline + kick
	var response: Vector3 = Vector3(channel.get("responseVelocity", normal * final_velocity.dot(normal)))
	var drive: Vector3 = Vector3(channel.get("driveVelocity", final_velocity - response))
	var sampled_frame: int = int(event.get("motionFrame", _motion_frame))
	var sampled_motion: Dictionary = _motion_record_at(sampled_frame)
	var sampled_wind: Vector3 = Vector3(sampled_motion.get("wind", Vector3.ZERO))
	var motor_baseline: Vector3 = baseline - sampled_wind
	# The solver sees real total velocity, including wind. Keep that exact result
	# while leaving wind in its own force channel, rather than counting it twice.
	if bool(channel.get("preserveDrive", false)):
		drive -= sampled_wind
	else:
		var normal_wind: Vector3 = normal * sampled_wind.dot(normal)
		drive -= sampled_wind - normal_wind
		response -= normal_wind
	if _pending_hit.is_empty():
		var carried_response: Vector3 = Vector3.ZERO
		if _impact_remaining > 0.0:
			carried_response = Vector3(sampled_motion["response"])
		_pending_hit = {"kick": Vector3.ZERO, "baseline": baseline,
			"drive": motor_baseline - carried_response, "response": carried_response,
			"carry": carried_response,
			"preserveDrive": _preserve_drive if carried_response.length_squared() > 0.000001 else true}
	# Add each contact's drive adjustment and response; no later callback can
	# overwrite an earlier perpendicular hit. A previous hit's tangential response
	# also stays protected instead of silently becoming ordinary motor velocity.
	var old_normal_response: Vector3 = normal * Vector3(_pending_hit["carry"]).dot(normal)
	_pending_hit["drive"] = Vector3(_pending_hit["drive"]) + drive - motor_baseline + old_normal_response
	_pending_hit["response"] = Vector3(_pending_hit["response"]) + response - old_normal_response
	_pending_hit["kick"] = Vector3(_pending_hit["kick"]) + kick
	_pending_hit["preserveDrive"] = bool(_pending_hit["preserveDrive"]) and bool(channel.get("preserveDrive", false))
	collision_count += 1
	last_impact = event.duplicate(true)

func _advance_wind(active: bool, delta: float) -> Vector3:
	var previous: Vector3 = wind_velocity
	if active:
		# dv/dt = F/m - drag*v, independently of the player's drive motor.
		# Exact drag integration keeps the gust consistent at different frame rates.
		var terminal: Vector3 = wind_direction * WIND_FORCE_MAGNITUDE / (maxf(mass, 0.01) * WIND_DRAG)
		wind_velocity = terminal + (previous - terminal) * exp(-WIND_DRAG * delta)
	else:
		# Stop applying force at three seconds, then dissipate the remaining motion
		# with the same uniform slide deceleration used by every contestant.
		wind_velocity = previous.move_toward(Vector3.ZERO, CollisionModel.SLIDE_DECELERATION * delta)
	return (previous + wind_velocity) * 0.5

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if simulation_paused or not alive:
		_record_motion(state.linear_velocity, Vector3.ZERO)
		return
	for index: int in range(state.get_contact_count()):
		var other: Object = state.get_contact_collider_object(index)
		if other is IslandBallBody and is_instance_valid(arena):
			arena.call("queue_contact", self, other)
	if falling:
		_record_motion(state.linear_velocity, Vector3.ZERO)
		return
	var delta: float = state.step
	if not _pending_hit.is_empty():
		knockback_velocity = Vector3(_pending_hit["response"])
		control_velocity = Vector3(_pending_hit["drive"])
		_impact_axis = knockback_velocity.normalized()
		_impact_speed = knockback_velocity.length()
		_impact_remaining = _impact_speed / CollisionModel.SLIDE_DECELERATION
		_impact_drive_floor = control_velocity.dot(_impact_axis)
		_preserve_drive = bool(_pending_hit["preserveDrive"])
		_pending_hit.clear()
		_recovery = 0.18
	var layers: Dictionary = counts()
	var drive_factor: float = speed_factor()
	var target: Vector3 = input_direction.limit_length(1.0) * BASE_SPEED * drive_factor
	var kick_direction: Vector3 = _impact_axis
	# Protect the actual reaction without discarding ordinary shared travel. In a
	# chase the original drive remains a motor component; only new acceleration
	# AGAINST the response is blocked, so reverse input cannot cancel it next tick.
	# A full/head-on response has no normal drive and keeps the old inward motor
	# separate until its true outward velocity dissipates. Sideways steering stays.
	if _impact_remaining > 0.0:
		if _preserve_drive:
			target += kick_direction * (maxf(target.dot(kick_direction), _impact_drive_floor) - target.dot(kick_direction))
			control_velocity += kick_direction * (maxf(control_velocity.dot(kick_direction), _impact_drive_floor) - control_velocity.dot(kick_direction))
		else:
			target += kick_direction * (_impact_drive_floor - target.dot(kick_direction))
			control_velocity += kick_direction * (_impact_drive_floor - control_velocity.dot(kick_direction))
	if _recovery <= 0.0:
		# This motor controls only ordinary drive. Wind has a separate force channel
		# and cannot be pulled back to the keyboard's target speed by this response.
		var response: float = DRIVE_RESPONSE if input_direction.length_squared() > 0.0001 else 1.0
		var acceleration: Vector3 = ((target - control_velocity) * response).limit_length(DRIVE_ACCELERATION * drive_factor)
		control_velocity += acceleration * delta
	_recovery = maxf(0.0, _recovery - delta)
	var average_wind: Vector3 = _advance_wind(int(layers["wind"]) > 0, delta)
	var next_kick: Vector3 = knockback_velocity.move_toward(Vector3.ZERO, CollisionModel.SLIDE_DECELERATION * delta)
	# Trapezoidal integration keeps measured no-input displacement at D, including
	# the final partial step; no position teleport is used for knockback.
	var average_response: Vector3 = (knockback_velocity + next_kick) * 0.5
	var horizontal: Vector3 = control_velocity + average_response + average_wind
	if _impact_remaining > 0.0:
		# Only the reaction channel receives this slide friction. Its value is true
		# outgoing normal motion in a head-on hit, and incremental motion in a chase.
		var next_speed: float = move_toward(_impact_speed, 0.0, CollisionModel.SLIDE_DECELERATION * delta)
		average_response = _impact_axis * (_impact_speed + next_speed) * 0.5
		horizontal = control_velocity + average_response + average_wind
		_impact_speed = next_speed
		_impact_remaining = maxf(0.0, _impact_remaining - delta)
		knockback_velocity = _impact_axis * _impact_speed
		if absf(_impact_speed) < 0.0001:
			_impact_remaining = 0.0
			knockback_velocity = Vector3.ZERO
	else:
		knockback_velocity = next_kick
	state.linear_velocity = Vector3(horizontal.x, minf(state.linear_velocity.y, 3.5), horizontal.z)
	_record_motion(horizontal, average_response, average_wind)

func get_snapshot() -> Dictionary:
	var result: Dictionary = config.duplicate(true)
	var effect_remaining: Dictionary = {"grow": 0.0, "shrink": 0.0, "speedUp": 0.0, "speedDown": 0.0, "wind": 0.0}
	var clock: float = float(arena.get("clock")) if is_instance_valid(arena) else 0.0
	for layer: Dictionary in effect_layers:
		var kind: String = str(layer["kind"])
		effect_remaining[kind] = maxf(float(effect_remaining[kind]), maxf(0.0, float(layer["expires"]) - clock))
	result.merge({
		"x": position.x, "y": position.y, "z": position.z,
		"vx": linear_velocity.x, "vz": linear_velocity.z,
		"windVx": wind_velocity.x, "windVz": wind_velocity.z,
		"scale": ball_scale, "mass": mass, "radius": BASE_RADIUS * ball_scale,
		"actualSpeedFactor": speed_factor(), "alive": alive,
		"falling": falling, "withdrawn": withdrawn, "rank": rank,
		"waterEntry": water_entry.duplicate(),
		"effects": counts(), "effectRemaining": effect_remaining, "collisionCount": collision_count,
		"lastImpact": last_impact.duplicate(true),
	}, true)
	return result

func mark_water_entry() -> void:
	# Authoritative, one-shot anchor survives later body freezing and is sent in
	# snapshots so both rooms float eliminated animals at the same water spot.
	if falling and not withdrawn and water_entry.is_empty() and position.y <= -1.65 + BASE_RADIUS * ball_scale:
		water_entry = {"x": position.x, "y": -1.65, "z": position.z}
