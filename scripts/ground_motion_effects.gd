extends Node3D
## Approved ground ribbon plus boost-only drifting dust. Per-contestant state;
## immutable art resources are shared by every contestant.

const DUST_SHADER: Shader = preload("res://shaders/dust_puff.gdshader")
const TRAIL_SHADER: Shader = preload("res://shaders/ground_trail.gdshader")
const BASE_SPEED: float = 5.8
const PUFF_CAPACITY: int = 40
const TRAIL_CAPACITY: int = 96
static var _shared_resources: Dictionary = {}

var _puffs: Array[Dictionary] = []
var _trail_pool: Array[Dictionary] = []
var _trail_ids: Array[int] = []
var _trail_cursor: int = 0
var _trail_node: MeshInstance3D
var _trail_mesh: ArrayMesh
var _ready_once: bool = false
var _paused: bool = false
var _clock: float = 0.0
var _dust_clock: float = 0.0
var _speed: float = 0.0
var _emission: float = 0.0
var _mode: String = "idle"
var _has_position: bool = false
var _last_position: Vector3 = Vector3.ZERO
var _last_direction: Vector3 = Vector3.FORWARD
var _ball_scale: float = 1.0
var _trail_length: float = 0.0
var _trail_width: float = 0.0
var _particles_spawned: int = 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	setup()

func setup() -> void:
	if _ready_once:
		return
	_ready_once = true
	_rng.seed = 712035
	_ensure_shared_resources()
	var quad: QuadMesh = _shared_resources["quad"]
	var material: ShaderMaterial = _shared_resources["dust_material"]
	for i: int in PUFF_CAPACITY:
		var puff := MeshInstance3D.new()
		puff.name = "BoostDust_%02d" % i
		puff.mesh = quad
		puff.material_override = material
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		puff.visible = false
		add_child(puff)
		_puffs.append({"node": puff, "age": -1.0, "life": 0.35, "v": Vector3.ZERO, "size": 0.55, "alpha": 0.75, "born": Vector3.ZERO})
	for i: int in TRAIL_CAPACITY:
		_trail_pool.append({"p": Vector3.ZERO, "age": -1.0, "life": 0.46, "width": 0.30, "strength": 0.5})
	_trail_mesh = ArrayMesh.new()
	_trail_node = MeshInstance3D.new()
	_trail_node.name = "GroundSpeedRibbon"
	_trail_node.mesh = _trail_mesh
	_trail_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ground_material: ShaderMaterial = _shared_resources["ground_material"]
	_trail_node.material_override = ground_material
	add_child(_trail_node)

func _ensure_shared_resources() -> void:
	if not _shared_resources.is_empty():
		return
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var dust_material := ShaderMaterial.new()
	dust_material.shader = DUST_SHADER
	var ground_material := ShaderMaterial.new()
	ground_material.shader = TRAIL_SHADER
	_shared_resources = {"quad": quad, "dust_material": dust_material, "ground_material": ground_material}

func update_motion(world_position: Vector3, velocity: Vector3, _facing_yaw: float, _head_position: Vector3, mode: String, dt: float, ball_radius: float = 0.7) -> void:
	setup()
	if _paused:
		return
	var delta: float = clampf(dt, 0.0, 0.06)
	_clock += delta
	_mode = mode
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	_speed = flat.length()
	_ball_scale = maxf(ball_radius / 0.7, 0.1)
	if _has_position and _last_position.distance_to(world_position) > 2.5 * _ball_scale:
		_clear_visible()
	_last_position = world_position
	_has_position = true
	_age_effects(delta)
	var moving: bool = _speed > 0.12 and mode != "idle"
	_emission = 0.0
	if moving:
		_last_direction = flat.normalized()
		var contact: Vector3 = world_position - Vector3.UP * ball_radius
		var boosted: bool = mode == "boost"
		var speed_ratio: float = clampf(_speed / BASE_SPEED, 0.0, 1.8)
		_trail_width = (clampf(0.56 + speed_ratio * 0.07, 0.56, 0.68) + (0.09 if boosted else 0.0)) * _ball_scale
		_record_ground(contact + Vector3.UP * 0.018 * _ball_scale, boosted)
		_trim_ground((2.25 if boosted else 1.75) * _ball_scale)
		if boosted:
			_emission = clampf(8.0 + _speed * 1.55, 11.0, 25.0)
			_dust_clock += delta * _emission
			while _dust_clock >= 1.0:
				_dust_clock -= 1.0
				_spawn_dust(contact, _last_direction)
		else:
			_dust_clock = 0.0
	else:
		_dust_clock = 0.0
	_rebuild_ground()

func _record_ground(point: Vector3, boosted: bool) -> void:
	if not _trail_ids.is_empty():
		var latest: Dictionary = _trail_pool[_trail_ids[0]]
		if point.distance_to(Vector3(latest["p"])) < 0.045 * _ball_scale:
			return
	var slot: int = _trail_cursor
	_trail_cursor = (_trail_cursor + 1) % TRAIL_CAPACITY
	_trail_ids.erase(slot)
	var sample: Dictionary = _trail_pool[slot]
	sample["p"] = point
	sample["age"] = 0.0
	sample["life"] = clampf((2.80 if boosted else 2.25) * _ball_scale / maxf(_speed, 0.5), 0.24, 0.56)
	sample["width"] = _trail_width
	sample["strength"] = 0.66 if boosted else 0.54
	_trail_ids.push_front(slot)

func _trim_ground(reach: float) -> void:
	var total: float = 0.0
	for i: int in range(1, _trail_ids.size()):
		var a: Vector3 = _trail_pool[_trail_ids[i - 1]]["p"]
		var b: Vector3 = _trail_pool[_trail_ids[i]]["p"]
		total += a.distance_to(b)
		if total > reach:
			while _trail_ids.size() > i + 1:
				var removed: int = _trail_ids.pop_back()
				_trail_pool[removed]["age"] = -1.0
			break

func _spawn_dust(contact: Vector3, direction: Vector3) -> void:
	var chosen: Dictionary = _puffs[0]
	for entry: Dictionary in _puffs:
		if float(entry["age"]) < 0.0:
			chosen = entry
			break
		if float(entry["age"]) > float(chosen["age"]):
			chosen = entry
	var puff: MeshInstance3D = chosen["node"]
	var side: Vector3 = direction.cross(Vector3.UP)
	chosen["age"] = 0.0
	chosen["life"] = clampf(2.9 * _ball_scale / maxf(_speed, 0.5), 0.25, 0.50) * _rng.randf_range(0.91, 1.09)
	chosen["size"] = _rng.randf_range(0.47, 0.59) * _ball_scale
	chosen["alpha"] = _rng.randf_range(0.66, 0.84)
	chosen["v"] = -direction * _rng.randf_range(0.10, 0.30) + side * _rng.randf_range(-0.18, 0.18) + Vector3.UP * _rng.randf_range(0.22, 0.38)
	puff.global_position = contact - direction * _rng.randf_range(0.10, 0.24) * _ball_scale + side * _rng.randf_range(-0.15, 0.15) * _ball_scale + Vector3.UP * 0.22 * _ball_scale
	chosen["born"] = puff.global_position
	puff.scale = Vector3.ONE * float(chosen["size"]) * 0.72
	puff.set_instance_shader_parameter("opacity", 0.0)
	puff.set_instance_shader_parameter("variation", _rng.randf() * 17.0)
	puff.set_instance_shader_parameter("progress", 0.0)
	puff.visible = true
	_particles_spawned += 1

func _age_effects(dt: float) -> void:
	for i: int in range(_trail_ids.size() - 1, -1, -1):
		var sample: Dictionary = _trail_pool[_trail_ids[i]]
		sample["age"] = float(sample["age"]) + dt
		if float(sample["age"]) >= float(sample["life"]):
			sample["age"] = -1.0
			_trail_ids.remove_at(i)
	for entry: Dictionary in _puffs:
		if float(entry["age"]) < 0.0:
			continue
		var puff: MeshInstance3D = entry["node"]
		entry["age"] = float(entry["age"]) + dt
		var progress: float = float(entry["age"]) / float(entry["life"])
		if progress >= 1.0:
			entry["age"] = -1.0
			puff.visible = false
			continue
		puff.global_position += Vector3(entry["v"]) * dt * _ball_scale
		puff.scale = Vector3.ONE * float(entry["size"]) * (0.72 + progress * 0.70)
		var fade: float = smoothstep(0.0, 0.13, progress) * (1.0 - smoothstep(0.30, 1.0, progress))
		puff.set_instance_shader_parameter("opacity", float(entry["alpha"]) * fade)
		puff.set_instance_shader_parameter("progress", progress)

func _rebuild_ground() -> void:
	_trail_mesh.clear_surfaces()
	_trail_length = 0.0
	_trail_node.visible = _trail_ids.size() >= 2
	if _trail_ids.size() < 2:
		return
	var distances: Array[float] = [0.0]
	for i: int in range(1, _trail_ids.size()):
		var a: Vector3 = _trail_pool[_trail_ids[i - 1]]["p"]
		var b: Vector3 = _trail_pool[_trail_ids[i]]["p"]
		_trail_length += a.distance_to(b)
		distances.append(_trail_length)
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in range(_trail_ids.size() - 1):
		var samples: Array[Dictionary] = [_trail_pool[_trail_ids[i]], _trail_pool[_trail_ids[i + 1]]]
		var pair_points: Array[Vector3] = []
		var pair_uvs: Array[Vector2] = []
		var pair_colors: Array[Color] = []
		for j: int in 2:
			var sample: Dictionary = samples[j]
			var point: Vector3 = sample["p"]
			var index: int = i + j
			var newer: Vector3 = _trail_pool[_trail_ids[maxi(index - 1, 0)]]["p"]
			var older: Vector3 = _trail_pool[_trail_ids[mini(index + 1, _trail_ids.size() - 1)]]["p"]
			var direction: Vector3 = (newer - older).normalized()
			if direction.length_squared() < 0.01:
				direction = _last_direction
			var side: Vector3 = direction.cross(Vector3.UP).normalized()
			var age_fraction: float = float(sample["age"]) / float(sample["life"])
			# Extra lateral space lets the broad feather fade out before the mesh edge.
			var alpha: float = float(sample["strength"]) * (1.0 - smoothstep(0.82, 1.0, age_fraction))
			var half_width: float = float(sample["width"]) * 0.5 * 1.35
			for sign_: float in [-1.0, 1.0]:
				pair_points.append(point + side * half_width * sign_)
				pair_uvs.append(Vector2(0.0 if sign_ < 0.0 else 1.0, distances[index] / maxf(_trail_length, 0.001)))
				pair_colors.append(Color(1.0, 1.0, 1.0, alpha))
		for vertex_id: int in [0, 2, 1, 1, 2, 3]:
			tool.set_normal(Vector3.UP)
			tool.set_uv(pair_uvs[vertex_id])
			tool.set_color(pair_colors[vertex_id])
			tool.add_vertex(to_local(pair_points[vertex_id]))
	tool.commit(_trail_mesh)

func _clear_visible() -> void:
	for entry: Dictionary in _puffs:
		entry["age"] = -1.0
		var puff: MeshInstance3D = entry["node"]
		puff.visible = false
	for sample: Dictionary in _trail_pool:
		sample["age"] = -1.0
	_trail_ids.clear()
	_trail_mesh.clear_surfaces()
	_trail_node.visible = false
	_trail_length = 0.0
	_dust_clock = 0.0

func reset() -> void:
	setup()
	_clear_visible()
	_has_position = false
	_speed = 0.0
	_emission = 0.0
	_trail_width = 0.0
	_particles_spawned = 0
	_mode = "idle"

func set_paused(value: bool) -> void:
	_paused = value

func emission_rate() -> float:
	return _emission

func metrics() -> Dictionary:
	var positions: Array[Vector3] = []
	var origins: Array[Vector3] = []
	var max_age: float = 0.0
	for entry: Dictionary in _puffs:
		if float(entry["age"]) >= 0.0:
			var puff: MeshInstance3D = entry["node"]
			positions.append(puff.global_position)
			origins.append(entry["born"])
			max_age = maxf(max_age, float(entry["age"]))
	var trail_points: Array[Vector3] = []
	for id_: int in _trail_ids:
		trail_points.append(_trail_pool[id_]["p"])
	return {"active_puffs": positions.size(), "sweat": 0, "marks": 0, "emission": _emission, "mode": _mode, "speed": _speed, "paused": _paused, "effect_time": _clock, "trail_samples": _trail_ids.size(), "trail_length": _trail_length, "trail_width": _trail_width, "trail_positions": trail_points, "max_dust_age": max_age, "particles_spawned": _particles_spawned, "dust_positions": positions, "dust_origins": origins, "puff_capacity": PUFF_CAPACITY, "trail_capacity": TRAIL_CAPACITY}
