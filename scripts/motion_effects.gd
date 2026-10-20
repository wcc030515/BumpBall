extends Node3D
## Movement effects facade. Ground trail/boost dust live in a dedicated helper;
## approved slow-mode sweat and friction marks remain independently pooled here.

const GroundMotionEffects: GDScript = preload("res://scripts/ground_motion_effects.gd")
const SWEAT_CAPACITY: int = 20
const MARK_CAPACITY: int = 64
static var _shared_resources: Dictionary = {}

var ground_effects: Node3D
var _sweat: Array[Dictionary] = []
var _marks: Array[Dictionary] = []
var _ready_once: bool = false
var _paused: bool = false
var _sweat_clock: float = 0.0
var _mark_distance: float = 0.0
var _last_position: Vector3 = Vector3.ZERO
var _has_position: bool = false
var _speed: float = 0.0
var _emission: float = 0.0
var _mode: String = "idle"
var _rng := RandomNumberGenerator.new()
var _scratch_meshes: Array[ArrayMesh] = []

func _ready() -> void:
	setup()

func setup() -> void:
	if _ready_once:
		return
	_ready_once = true
	_rng.seed = 75129
	_ensure_shared_resources()
	ground_effects = GroundMotionEffects.new()
	ground_effects.name = "GroundAndBoostEffects"
	add_child(ground_effects)
	ground_effects.setup()
	ground_effects.set_paused(_paused)
	var blue: StandardMaterial3D = _shared_resources["blue"]
	var shine: StandardMaterial3D = _shared_resources["shine"]
	var lower: SphereMesh = _shared_resources["lower"]
	var tip: CylinderMesh = _shared_resources["tip"]
	var glint: SphereMesh = _shared_resources["glint"]
	for i in SWEAT_CAPACITY:
		var drop := Node3D.new()
		drop.name = "Sweat_%02d" % i
		drop.visible = false
		add_child(drop)
		_add_mesh(drop, lower, blue, Vector3.ZERO)
		_add_mesh(drop, tip, blue, Vector3(0.0, 0.092, 0.0))
		_add_mesh(drop, glint, shine, Vector3(0.038, 0.015, 0.052))
		_sweat.append({"node": drop, "age": -1.0, "life": 0.7, "v": Vector3.ZERO, "size": 1.0})
	var mark_material: StandardMaterial3D = _shared_resources["mark_material"]
	for i in 3:
		_scratch_meshes.append(_shared_resources["scratch_%d" % i])
	for i in MARK_CAPACITY:
		var mark := MeshInstance3D.new()
		mark.name = "Friction_%02d" % i
		mark.mesh = _scratch_meshes[i % 3]
		mark.material_override = mark_material
		mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mark.visible = false
		add_child(mark)
		_marks.append({"node": mark, "age": -1.0, "life": 1.2})

func _ensure_shared_resources() -> void:
	if not _shared_resources.is_empty():
		return
	# Each contestant keeps independent particles and clocks; immutable art is shared.
	var blue := StandardMaterial3D.new()
	blue.albedo_color = Color("46C9F0")
	blue.roughness = 0.24
	blue.metallic = 0.06
	blue.emission_enabled = true
	blue.emission = Color("197BCE")
	blue.emission_energy_multiplier = 0.13
	var shine := StandardMaterial3D.new()
	shine.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shine.albedo_color = Color("E8FCFF")
	var lower := SphereMesh.new()
	lower.radius = 0.073
	lower.height = 0.145
	lower.radial_segments = 10
	lower.rings = 5
	var tip := CylinderMesh.new()
	tip.bottom_radius = 0.066
	tip.top_radius = 0.003
	tip.height = 0.16
	tip.radial_segments = 10
	var glint := SphereMesh.new()
	glint.radius = 0.019
	glint.height = 0.041
	glint.radial_segments = 8
	glint.rings = 4
	var mark_material := StandardMaterial3D.new()
	mark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mark_material.albedo_color = Color(0.13, 0.12, 0.06, 0.55)
	mark_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mark_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_shared_resources = {"blue": blue, "shine": shine, "lower": lower, "tip": tip, "glint": glint, "mark_material": mark_material}
	for i in 3:
		_shared_resources["scratch_%d" % i] = _scratch_shape(i)

func _add_mesh(parent: Node3D, mesh: Mesh, material: Material, offset: Vector3) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = material
	part.position = offset
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(part)
	return part

func _scratch_shape(variant: int) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for stripe in 3:
		var x: float = float(stripe - 1) * 0.075
		var z: float = float((stripe + variant) % 3 - 1) * 0.027
		var length_: float = 0.19 + float((stripe + variant) % 3) * 0.038
		var width: float = 0.018 + float(stripe % 2) * 0.009
		var points: Array[Vector3] = [Vector3(x - width, 0, z - length_ * 0.5), Vector3(x + width, 0, z - length_ * 0.38), Vector3(x + width * 0.6, 0, z + length_ * 0.5), Vector3(x - width * 0.6, 0, z + length_ * 0.35)]
		for vertex_id in [0, 2, 1, 0, 3, 2]:
			tool.set_normal(Vector3.UP)
			tool.add_vertex(points[vertex_id])
	return tool.commit()

func update_motion(world_position: Vector3, velocity: Vector3, facing_yaw: float, head_position: Vector3, mode: String, dt: float, ball_radius: float = 0.7) -> void:
	setup()
	if _paused:
		return
	var delta: float = clampf(dt, 0.0, 0.06)
	_age_effects(delta)
	_mode = mode
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	_speed = flat.length()
	var moving: bool = _speed > 0.12 and mode != "idle"
	var distance_: float = world_position.distance_to(_last_position) if _has_position else 0.0
	if distance_ > 2.5:
		# Teleports never draw connecting smoke or skid lines.
		distance_ = 0.0
		_mark_distance = 0.0
	_last_position = world_position
	_has_position = true
	# Slow mode keeps its existing sweat/friction language; old ground/dust
	# particles may complete their short fade without new ordinary emissions.
	ground_effects.update_motion(world_position, velocity, facing_yaw, head_position,
		"idle" if mode == "slow" else mode, delta, ball_radius)
	_emission = ground_effects.emission_rate()
	if mode == "slow":
		_sweat_clock += delta
		while _sweat_clock >= 0.23:
			_sweat_clock -= 0.23
			_spawn_sweat(head_position, facing_yaw, -1.0)
			_spawn_sweat(head_position, facing_yaw, 1.0)
		if moving:
			_mark_distance += distance_
			if _mark_distance >= 0.31:
				_mark_distance = fmod(_mark_distance, 0.31)
				_spawn_mark(world_position - Vector3.UP * ball_radius, flat.normalized(), ball_radius)
		else:
			_mark_distance = 0.0
	else:
		_sweat_clock = 0.0
		_mark_distance = 0.0

func _free_entry(pool: Array[Dictionary]) -> Dictionary:
	for entry: Dictionary in pool:
		if float(entry["age"]) < 0.0:
			return entry
	# Fixed capacity: recycle the oldest instead of allocating during movement.
	var oldest: Dictionary = pool[0]
	for entry: Dictionary in pool:
		if float(entry["age"]) > float(oldest["age"]):
			oldest = entry
	return oldest

func _spawn_sweat(head_position: Vector3, facing_yaw: float, side_sign: float) -> void:
	var entry: Dictionary = _free_entry(_sweat)
	var drop: Node3D = entry["node"]
	var forward := Vector3(sin(facing_yaw), 0.0, cos(facing_yaw))
	var side := Vector3(forward.z, 0.0, -forward.x) * side_sign
	entry["age"] = 0.0
	entry["life"] = _rng.randf_range(0.66, 0.82)
	entry["size"] = _rng.randf_range(0.97, 1.20)
	entry["v"] = side * _rng.randf_range(0.16, 0.24) - forward * 0.12 + Vector3.UP * 0.35
	# Slightly behind the head, both sides remain outside the head silhouette.
	drop.global_position = head_position - forward * 0.19 + side * 0.48 + Vector3.UP * _rng.randf_range(0.0, 0.10)
	drop.rotation = Vector3(0.0, facing_yaw, -side_sign * 0.26)
	drop.scale = Vector3.ONE * 0.1
	drop.visible = true

func _spawn_mark(contact: Vector3, direction: Vector3, ball_radius: float) -> void:
	var entry: Dictionary = _free_entry(_marks)
	var mark: MeshInstance3D = entry["node"]
	entry["age"] = 0.0
	entry["life"] = _rng.randf_range(1.0, 1.4)
	mark.global_position = contact - direction * (0.1 * maxf(ball_radius, 0.05)) + Vector3.UP * 0.012
	mark.rotation.y = atan2(direction.x, direction.z)
	mark.scale = Vector3(_rng.randf_range(0.9, 1.2), 1.0, _rng.randf_range(0.9, 1.2))
	mark.transparency = 0.0
	mark.visible = true

func _age_effects(dt: float) -> void:
	for entry: Dictionary in _sweat:
		if float(entry["age"]) < 0.0:
			continue
		entry["age"] = float(entry["age"]) + dt
		var node: Node3D = entry["node"]
		var progress: float = float(entry["age"]) / float(entry["life"])
		if progress >= 1.0:
			entry["age"] = -1.0
			node.visible = false
			continue
		var velocity: Vector3 = entry["v"]
		velocity.y -= dt * 1.8
		entry["v"] = velocity
		node.global_position += velocity * dt
		var size: float = float(entry["size"]) * smoothstep(0.0, 0.12, progress) * (1.0 - smoothstep(0.66, 1.0, progress))
		node.scale = Vector3.ONE * maxf(size, 0.001)
	for entry: Dictionary in _marks:
		if float(entry["age"]) < 0.0:
			continue
		entry["age"] = float(entry["age"]) + dt
		var node: MeshInstance3D = entry["node"]
		var progress: float = float(entry["age"]) / float(entry["life"])
		if progress >= 1.0:
			entry["age"] = -1.0
			node.visible = false
		else:
			node.transparency = smoothstep(0.25, 1.0, progress)

func set_paused(value: bool) -> void:
	_paused = value
	if is_instance_valid(ground_effects):
		ground_effects.set_paused(value)

func deactivate() -> void:
	# Call on leaving a match/falling into the sea to clear the world-space trail.
	reset()

func reset() -> void:
	if is_instance_valid(ground_effects):
		ground_effects.reset()
	for pool: Array[Dictionary] in [_sweat, _marks]:
		for entry: Dictionary in pool:
			entry["age"] = -1.0
			var node: Node3D = entry["node"]
			node.visible = false
	_sweat_clock = 0.0
	_mark_distance = 0.0
	_has_position = false
	_speed = 0.0
	_emission = 0.0
	_mode = "idle"

func metrics() -> Dictionary:
	setup()
	var result: Dictionary = ground_effects.metrics()
	result.merge({"sweat": _active_count(_sweat), "marks": _active_count(_marks),
		"emission": _emission, "speed": _speed, "mode": _mode, "paused": _paused}, true)
	return result

func _active_count(pool: Array[Dictionary]) -> int:
	var count: int = 0
	for entry: Dictionary in pool:
		if float(entry["age"]) >= 0.0:
			count += 1
	return count
