class_name BallIslandStage
extends Node3D
## The approved V3-refined island, with one geometry contract for art and physics.
## GLB and JSON are already Godot Y-up at scale 1; the playable surface is Y=0.

const ASSET_PATH: String = "res://assets/island-v3-refined/island_stage.glb"
const GEOMETRY_PATH: String = "res://assets/island-v3-refined/stage_geometry.json"
const EDGE_EPSILON: float = 0.00001

static var _geometry: Dictionary = {}
static var _outline: PackedVector2Array = PackedVector2Array()
static var _surface_faces: PackedVector3Array = PackedVector3Array()
static var _shore_profile: ImageTexture

var visual: Node3D
var animations: Array[AnimationPlayer] = []
var motion_paused: bool = false


func build_visual(parent: Node3D) -> Node3D:
	if get_parent() == null:
		parent.add_child(self)
	if is_instance_valid(visual):
		return visual
	name = "ApprovedIslandStageV3Refined"
	var packed := load(ASSET_PATH) as PackedScene
	if packed == null:
		push_error("Approved island asset could not be loaded: " + ASSET_PATH)
		return null
	visual = packed.instantiate() as Node3D
	add_child(visual)
	_collect_wind_animations(visual)
	return visual


func _collect_wind_animations(node: Node) -> void:
	if node is AnimationPlayer:
		var player := node as AnimationPlayer
		player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for clip: StringName in player.get_animation_list():
			if "SeaBreeze" in str(clip):
				player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
				player.play(clip)
				player.advance(0.0)
				animations.append(player)
				break
	for child: Node in node.get_children():
		_collect_wind_animations(child)


func _process(delta: float) -> void:
	if motion_paused:
		return
	for player: AnimationPlayer in animations:
		player.advance(delta)


func set_motion_paused(paused: bool) -> void:
	motion_paused = paused


static func _ensure_geometry() -> void:
	if not _geometry.is_empty():
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GEOMETRY_PATH))
	if not parsed is Dictionary:
		push_error("Approved island geometry data is missing or invalid: " + GEOMETRY_PATH)
		return
	_geometry = parsed
	for point: Array in _geometry.get("outline_xz", []):
		_outline.append(Vector2(float(point[0]), float(point[1])))
	var vertices: Array = _geometry.get("surface_vertices_xyz", [])
	for triangle: Array in _geometry.get("surface_triangles", []):
		for raw_index: Variant in triangle:
			var index: int = int(raw_index)
			var point: Array = vertices[index]
			_surface_faces.append(Vector3(float(point[0]), float(point[1]), float(point[2])))


static func outline_points() -> PackedVector2Array:
	_ensure_geometry()
	return _outline.duplicate()


static func surface_triangles() -> PackedVector3Array:
	_ensure_geometry()
	return _surface_faces.duplicate()


static func collision_shape() -> ConcavePolygonShape3D:
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(surface_triangles())
	shape.backface_collision = true
	return shape


static func contains_point(point: Vector2) -> bool:
	_ensure_geometry()
	if _outline.size() < 3:
		return false
	if Geometry2D.is_point_in_polygon(point, _outline):
		return true
	# Treat the geometric boundary itself as supported ground.
	for i: int in _outline.size():
		var nearest := Geometry2D.get_closest_point_to_segment(point, _outline[i], _outline[(i + 1) % _outline.size()])
		if point.distance_squared_to(nearest) <= EDGE_EPSILON * EDGE_EPSILON:
			return true
	return false


static func boundary_distance(direction: Vector2) -> float:
	_ensure_geometry()
	if direction.length_squared() < EDGE_EPSILON * EDGE_EPSILON:
		return 0.0
	var ray := direction.normalized()
	var distance: float = INF
	for i: int in _outline.size():
		var a: Vector2 = _outline[i]
		var edge: Vector2 = _outline[(i + 1) % _outline.size()] - a
		var denominator: float = ray.cross(edge)
		if absf(denominator) < 0.0000001:
			continue
		var ray_t: float = a.cross(edge) / denominator
		var segment_t: float = a.cross(ray) / denominator
		if ray_t >= 0.0 and segment_t >= -EDGE_EPSILON and segment_t <= 1.0 + EDGE_EPSILON:
			distance = minf(distance, ray_t)
	return distance if is_finite(distance) else 0.0


static func edge_info(point: Vector2) -> Dictionary:
	_ensure_geometry()
	var distance_squared: float = INF
	var nearest_point := Vector2.ZERO
	var inward_normal := Vector2.ZERO
	var segment_index: int = -1
	for i: int in _outline.size():
		var a: Vector2 = _outline[i]
		var b: Vector2 = _outline[(i + 1) % _outline.size()]
		var nearest := Geometry2D.get_closest_point_to_segment(point, a, b)
		var candidate: float = point.distance_squared_to(nearest)
		if candidate < distance_squared:
			distance_squared = candidate
			nearest_point = nearest
			var edge: Vector2 = b - a
			inward_normal = Vector2(-edge.y, edge.x).normalized()
			segment_index = i
	var distance: float = sqrt(distance_squared)
	var inside: bool = contains_point(point)
	return {
		"inside": inside,
		"nearest_point": nearest_point,
		"inward_normal": inward_normal,
		"distance": distance,
		"signed_distance": distance if inside else -distance,
		"segment_index": segment_index,
	}


static func signed_edge_distance(point: Vector2) -> float:
	return float(edge_info(point).signed_distance)


static func maximum_radius() -> float:
	_ensure_geometry()
	return float(_geometry.get("max_outline_radius_m", 0.0))


static func shoreline_texture() -> Texture2D:
	## Red contains the cliff/water intersection radius in metres, not the grass edge.
	## Pixel k is angle TAU*k/512; sample at angle/TAU + 0.5/512, with repeat.
	if _shore_profile != null:
		return _shore_profile
	_ensure_geometry()
	var radii: Array = _geometry.get("shoreline_radii", [])
	if radii.size() != 512:
		push_error("Approved island waterline profile must contain 512 samples.")
		return null
	var image := Image.create(512, 1, false, Image.FORMAT_RF)
	for i: int in 512:
		image.set_pixel(i, 0, Color(float(radii[i]), 0, 0, 1))
	_shore_profile = ImageTexture.create_from_image(image)
	return _shore_profile
