extends Node3D
## Native Godot presentation, deliberately separated from rigid-body simulation.

const AnimalVisual: GDScript = preload("res://scripts/animal_visual.gd")
const NameBubble: GDScript = preload("res://scripts/name_bubble.gd")
const WaterMotion = preload("res://scripts/water_motion.gd")
const CameraSettings = preload("res://scripts/camera_settings.gd")
const WindVisual: GDScript = preload("res://scripts/wind_visual.gd")
const OCEAN_SHADER: Shader = preload("res://shaders/ocean.gdshader")
const OCEAN_MATERIAL: ShaderMaterial = preload("res://materials/ocean.tres")
const IslandStage = preload("res://scripts/island_stage.gd")
const ISLAND_RADIUS: float = 8.8
const WATER_Y: float = -1.65
const BASE_RADIUS_FOR_WATER: float = 0.7
const CAMERA_FOV: float = 42.0
const MATCH_CAMERA_DIRECTION := Vector3(12.0, 16.0, 19.0)
const CAMP_CAMERA_DIRECTION := Vector3(15.5, 13.0, 21.0)
const FRAMING_SEA_RADIUS: float = 9.4
const HUD_REFERENCE_SIZE := Vector2(1600.0, 900.0)
var island_stage: Node3D
var camera: Camera3D
var ocean: MeshInstance3D
var world_environment: WorldEnvironment
var sunlight: DirectionalLight3D
var entities: Dictionary = {}
var name_bubbles: Dictionary = {}
var name_overlay: Control
var appearances: Dictionary = {}
var latest_velocities: Dictionary = {}
var high_quality: bool = true
var preview_mode: bool = true
var motion_paused: bool = false
var winner_focus_active: bool = false
var winner_focus_progress: float = 0.0
var _winner_tween: Tween
var winner_focus_id: String = ""
var camera_settings: Dictionary = CameraSettings.DEFAULTS.duplicate(true)
var camera_preview_scope: String = ""
var camera_preview_id: String = ""
var preview_rotation: float = 0.0
var intro_camera_active: bool = false
var intro_camera_progress: float = 0.0
var _intro_duration: float = 0.0
var _intro_authority_remaining: float = -1.0
var _intro_prediction_age: float = 0.0
var _intro_far: Transform3D
var _intro_target: Transform3D
var ocean_time: float = 0.0
var impact_effects: Array[Dictionary] = []
var water_material: ShaderMaterial
var camera_safe_rect: Rect2
var wind_visual: Node3D

func _ready() -> void:
	name = "NativeIslandWorld"
	_build_environment()
	_build_island()
	_build_ocean()
	_build_camera()
	_build_name_overlay()
	wind_visual = WindVisual.new()
	add_child(wind_visual)
	set_quality(high_quality)

func _build_name_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CharacterNameLayer"
	# Built before the game's HUD, so buttons and menus remain above names.
	layer.layer = 0
	add_child(layer)
	name_overlay = Control.new()
	name_overlay.name = "CharacterNames"
	name_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(name_overlay)

func _material(color: Color, roughness: float = 0.88) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material

func _mesh(resource: Mesh, material: Material, at: Vector3, node_name: String) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = resource
	instance.material_override = material
	instance.position = at
	add_child(instance)
	return instance

func _build_environment() -> void:
	world_environment = WorldEnvironment.new()
	world_environment.name = "SunnyMaritimeEnvironment"
	var environment := Environment.new()
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("458cba")
	sky_material.sky_horizon_color = Color("c0e0e7")
	sky_material.ground_bottom_color = Color("527f91")
	sky_material.ground_horizon_color = Color("c0e0e7")
	sky_material.sky_curve = 0.12
	sky_material.sun_angle_max = 6.0
	sky_material.sun_curve = 0.07
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	environment.sky = sky
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.55
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.1
	environment.fog_enabled = true
	environment.fog_light_color = Color("b6d8e2")
	environment.fog_light_energy = 0.6
	environment.fog_density = 0.0018
	environment.fog_height_density = 0.0
	world_environment.environment = environment
	add_child(world_environment)
	sunlight = DirectionalLight3D.new()
	sunlight.name = "AfternoonSun"
	sunlight.rotation_degrees = Vector3(-54.0, -35.0, 0.0)
	sunlight.light_color = Color("fff1d8")
	sunlight.light_energy = 1.8
	sunlight.shadow_enabled = true
	sunlight.directional_shadow_max_distance = 70.0
	sunlight.shadow_bias = 0.035
	sunlight.shadow_normal_bias = 0.6
	sunlight.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	add_child(sunlight)

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "IslandCamera"
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = CAMERA_FOV
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = 0.1
	camera.far = 420.0
	add_child(camera)
	camera.current = true
	get_viewport().size_changed.connect(_on_viewport_resized)
	_set_camera_mode(false)

func _build_island() -> void:
	# The approved Blender asset contains the stage and nonblocking decorations.
	# Physics uses only its flat grass surface, created separately by Arena.
	island_stage = IslandStage.new()
	island_stage.build_visual(self)
	var seabed := CylinderMesh.new()
	seabed.top_radius = 13.4
	seabed.bottom_radius = 27.0
	seabed.height = 10.0
	seabed.radial_segments = 80
	_mesh(seabed, _material(Color("b5bc8d")), Vector3(0, -9.45, 0), "SubmergedSandShelf")

func _build_ocean() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(260, 260)
	plane.subdivide_width = 210
	plane.subdivide_depth = 210
	water_material = OCEAN_MATERIAL.duplicate()
	# Only the coast mask changes; wave motion, reflection and refraction stay.
	water_material.set_shader_parameter("shore_profile_texture", IslandStage.shoreline_texture())
	water_material.set_shader_parameter("shore_profile_enabled", true)
	ocean = _mesh(plane, water_material, Vector3(0, WATER_Y, 0), "GerstnerOcean")
	ocean.extra_cull_margin = 2.0
	ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func set_quality(high: bool) -> void:
	high_quality = high
	if water_material != null:
		water_material.set_shader_parameter("high_quality", high)
	if world_environment != null:
		world_environment.environment.ssao_enabled = high
		world_environment.environment.ssao_radius = 0.6
		world_environment.environment.ssao_intensity = 0.65
		world_environment.environment.glow_enabled = high
		world_environment.environment.glow_intensity = 0.20
		world_environment.environment.ssr_enabled = high
	if sunlight != null:
		sunlight.shadow_enabled = high

func _vector(value: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value
	if value is Dictionary:
		return Vector3(float(value.get("x", 0)), float(value.get("y", 0)), float(value.get("z", 0)))
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback

func update_entities(snapshot: Dictionary, local_id: String = "player") -> void:
	if preview_mode:
		_set_camera_mode(false)
	preview_mode = false
	var rows: Array = snapshot.get("entities", snapshot.get("players", []))
	var remaining: Dictionary = {}
	for item: Variant in rows:
		if not item is Dictionary:
			continue
		var data: Dictionary = item
		var id: String = str(data.get("id", ""))
		if id.is_empty():
			continue
		remaining[id] = true
		var character: Dictionary = data.get("character", {})
		var ball: Dictionary = data.get("ball", {})
		var animal: String = str(data.get("animal", "rabbit"))
		var signature: String = JSON.stringify([animal, character, ball])
		if not entities.has(id):
			var created: Node3D = AnimalVisual.new()
			created.name = "Animal_%s" % id.validate_node_name()
			add_child(created)
			entities[id] = created
			var bubble: Control = NameBubble.new()
			bubble.name = "NameBubble_%s" % id.validate_node_name()
			name_overlay.add_child(bubble)
			name_bubbles[id] = bubble
		var visual: Node3D = entities[id]
		if appearances.get(id, "") != signature:
			visual.configure(animal, character, ball)
			appearances[id] = signature
		visual.scale = Vector3.ONE
		visual.rotation = Vector3.ZERO
		visual.name_label.visible = not (winner_focus_active and id == str(snapshot.get("winnerId", "")))
		var pos := Vector3(float(data.get("x", 0)), float(data.get("y", 0.7)), float(data.get("z", 0)))
		if data.has("position"):
			pos = _vector(data["position"], pos)
		elif data.has("p"):
			pos = _vector(data["p"], pos)
		if not visual.floating: visual.position = pos
		visual.set_visual_scale(float(data.get("scale", 1.0)))
		var human: bool = bool(data.get("human", id in ["player", "host", "guest"]))
		visual.set_player_identity(str(data.get("name", "小动物")), id == local_id, human)
		visual.set_effects(data.get("effects", []))
		visual.set_fall_state(bool(data.get("falling", false)), bool(data.get("alive", true)))
		if bool(data.get("falling", false)) and not bool(data.get("withdrawn", false)) and not visual.floating:
			var entry: Dictionary = data.get("waterEntry", {})
			if not entry.is_empty():
				visual.start_floating(Vector3(float(entry.x), float(entry.y), float(entry.z)))
			elif pos.y <= WATER_Y + BASE_RADIUS_FOR_WATER * float(data.get("scale", 1.0)):
				visual.start_floating(Vector3(pos.x, WATER_Y, pos.z))
		visual.set_match_state(str(snapshot.get("status", "ready")), id == str(snapshot.get("winnerId", "")))
		if str(snapshot.get("status", "")) in ["intro", "countdown"]:
			visual.face_start_center(-Vector3(pos.x, 0, pos.z))
		visual.set_motion_paused(motion_paused)
		visual.visible = not bool(data.get("withdrawn", false)) and (visual.floating or bool(data.get("alive", true)) or (bool(data.get("falling", false)) and pos.y > -5.0))
		var velocity := Vector3(float(data.get("vx", 0)), float(data.get("vy", 0)), float(data.get("vz", 0)))
		if data.has("velocity"):
			velocity = _vector(data["velocity"], velocity)
		latest_velocities[id] = velocity
	for id: Variant in entities.keys():
		if not remaining.has(id):
			entities[id].queue_free()
			entities.erase(id)
			appearances.erase(id)
			latest_velocities.erase(id)
			if name_bubbles.has(id):
				name_bubbles[id].queue_free()
				name_bubbles.erase(id)
	if str(snapshot.get("status", "")) == "intro":
		_sync_match_intro(snapshot)
	elif intro_camera_active:
		intro_camera_active = false
		intro_camera_progress = 1.0
		_place_match_camera()

func show_preview(selection: Dictionary) -> void:
	cancel_match_intro()
	preview_rotation = 0.0
	camera_preview_scope = ""
	cancel_winner_focus()
	for visual: Node3D in entities.values(): visual.reset_floating()
	wind_visual.clear()
	var data: Dictionary = selection.duplicate(true)
	data["id"] = str(data.get("id", "player"))
	data["name"] = str(data.get("name", "我的小动物"))
	data["x"] = 2.5
	data["y"] = 1.175
	data["z"] = 0.2
	data["scale"] = 1.0
	data["alive"] = true
	data["human"] = true
	update_entities({"entities": [data]}, str(data["id"]))
	preview_mode = true
	var visual: Node3D = entities[data["id"]]
	visual.scale = Vector3.ONE * 1.65
	visual.name_label.visible = false
	visual.effect_label.visible = false
	visual.animal_root.rotation.y = 0.4
	_set_camera_mode(true)
	_update_name_bubbles()

func rotate_preview(horizontal_pixels: float) -> void:
	if not preview_mode or not camera_preview_scope.is_empty() or entities.is_empty() or not is_finite(horizontal_pixels):
		return
	# Rotate the animal and its ball together, leaving the island and camera fixed.
	preview_rotation = wrapf(preview_rotation + horizontal_pixels * 0.01, -PI, PI)
	var visual: Node3D = entities.values()[0]
	visual.rotation.y = preview_rotation

func _set_camera_mode(preview: bool) -> void:
	if camera == null:
		return
	if intro_camera_active and not preview:
		_refresh_intro_target()
		_apply_match_intro()
		return
	if camera_preview_scope == "victory":
		_place_focus_camera(camera_preview_id)
		return
	if camera_preview_scope == "match" or not preview:
		_place_match_camera()
		return
	_place_camp_camera()

func _place_camp_camera() -> void:
	if entities.is_empty(): return
	var actor: Node3D = entities.values()[0]
	var target: Vector3 = actor.global_position + Vector3(0, 0.9 * actor.scale.y, 0)
	var view_size: Vector2 = get_viewport().get_visible_rect().size
	var screen_center := Vector2(view_size.x * (477.5 / 1600.0), view_size.y * 0.5)
	camera_safe_rect = Rect2(Vector2(65, 110) * view_size / HUD_REFERENCE_SIZE, Vector2(825, 680) * view_size / HUD_REFERENCE_SIZE)
	var direction: Vector3 = CAMP_CAMERA_DIRECTION.normalized()
	_place_target_camera(target, direction.y * 11.7, Vector2(direction.x, direction.z).length() * 11.7, rad_to_deg(atan2(direction.x, direction.z)), CAMERA_FOV, screen_center)

func _place_match_camera() -> void:
	var params: Dictionary = camera_settings.match
	var view_size: Vector2 = get_viewport().get_visible_rect().size
	if view_size.x < 1 or view_size.y < 1: view_size = HUD_REFERENCE_SIZE
	camera_safe_rect = Rect2(Vector2(250, 95) * view_size / HUD_REFERENCE_SIZE, Vector2(1100, 660) * view_size / HUD_REFERENCE_SIZE)
	var yaw: float = deg_to_rad(float(params.yaw))
	var eye := Vector3(sin(yaw) * float(params.distance), float(params.height), cos(yaw) * float(params.distance))
	camera.fov = float(params.fov)
	camera.h_offset = 0
	camera.v_offset = 0
	camera.position = eye
	camera.look_at(Vector3.ZERO)
	var right: Vector3 = camera.global_basis.x
	var up: Vector3 = camera.global_basis.y
	var direction: Vector3 = eye.normalized()
	var stage_points: Array[Vector3] = []
	for edge: Vector2 in IslandStage.outline_points():
		var stage := Vector3(edge.x, 0.0, edge.y)
		stage_points.append(Vector3(stage.dot(right), stage.dot(up), stage.dot(direction)))
	var focal: float = view_size.y / (2.0 * tan(deg_to_rad(camera.fov) * 0.5))
	var center := Vector2(view_size.x * 0.5, view_size.y * (385.0 / 800.0))
	var offsets: Vector2 = _offsets_for_stage_center(stage_points, eye.length(), focal, view_size, center)
	camera.position = eye + right * offsets.x + up * offsets.y

func _place_target_camera(target: Vector3, height: float, distance: float, yaw_degrees: float, fov: float, screen_center: Vector2) -> void:
	var yaw: float = deg_to_rad(yaw_degrees)
	camera.h_offset = 0
	camera.v_offset = 0
	camera.fov = fov
	var eye := Vector3(sin(yaw) * distance, height, cos(yaw) * distance)
	camera.position = target + eye
	camera.look_at(target)
	var view_size: Vector2 = get_viewport().get_visible_rect().size
	var focal: float = view_size.y / (2.0 * tan(deg_to_rad(fov) * 0.5))
	var error: Vector2 = view_size * 0.5 - screen_center
	camera.position += (camera.global_basis.x * error.x - camera.global_basis.y * error.y) * eye.length() / focal

func _focus_transform(id: String) -> Transform3D:
	if not entities.has(id): return camera.global_transform
	var params: Dictionary = camera_settings.victory
	var target: Vector3 = entities[id].global_position + Vector3(0, 1.2 * entities[id].scale.y, 0)
	var yaw: float = deg_to_rad(float(params.yaw))
	var eye := Vector3(sin(yaw) * float(params.distance), float(params.height), cos(yaw) * float(params.distance))
	return Transform3D(Basis.IDENTITY, target + eye).looking_at(target)

func _place_focus_camera(id: String) -> void:
	camera.h_offset = 0
	camera.v_offset = 0
	camera.global_transform = _focus_transform(id)
	camera.fov = float(camera_settings.victory.fov)
	if winner_focus_active and winner_focus_progress >= 1.0 and id == winner_focus_id and entities.has(id) and not entities[id].floating:
		entities[id].animal_root.rotation.y = deg_to_rad(float(camera_settings.victory.yaw))

func apply_camera_settings(settings: Dictionary) -> void:
	camera_settings = settings.duplicate(true)
	if intro_camera_active:
		_refresh_intro_target()
		_apply_match_intro()
		return
	if winner_focus_active and camera_preview_scope.is_empty():
		if winner_focus_progress >= 1.0: _place_focus_camera(winner_focus_id)
	else:
		_set_camera_mode(preview_mode)

func preview_camera(scope: String, preferred_id: String = "player") -> void:
	if scope not in ["match", "victory"] or entities.is_empty(): return
	if intro_camera_active: return
	if winner_focus_active and winner_focus_progress < 1.0: return
	camera_preview_scope = scope
	camera_preview_id = winner_focus_id if winner_focus_active else preferred_id
	if not entities.has(camera_preview_id): camera_preview_id = str(entities.keys()[0])
	_set_camera_mode(preview_mode)

func end_camera_preview() -> void:
	if camera_preview_scope.is_empty(): return
	camera_preview_scope = ""
	camera_preview_id = ""
	if winner_focus_active:
		if winner_focus_progress >= 1.0: _place_focus_camera(winner_focus_id)
	else:
		_set_camera_mode(preview_mode)

func _offsets_for_stage_center(points: Array[Vector3], distance: float, focal_pixels: float,
	viewport_size: Vector2, target_center: Vector2) -> Vector2:
	var offsets := Vector2.ZERO
	for iteration: int in 8:
		var bounds: Rect2 = _perspective_bounds(points, distance, offsets, focal_pixels, viewport_size)
		var error: Vector2 = bounds.get_center() - target_center
		offsets += Vector2(error.x, -error.y) * distance / focal_pixels
	return offsets

func _perspective_bounds(points: Array[Vector3], distance: float, offsets: Vector2,
	focal_pixels: float, viewport_size: Vector2) -> Rect2:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for point: Vector3 in points:
		var depth: float = maxf(distance - point.z, 0.05)
		var screen := Vector2(viewport_size.x * 0.5 + focal_pixels * (point.x - offsets.x) / depth,
			viewport_size.y * 0.5 - focal_pixels * (point.y - offsets.y) / depth)
		low = low.min(screen)
		high = high.max(screen)
	return Rect2(low, high - low)

func _on_viewport_resized() -> void:
	if intro_camera_active:
		_refresh_intro_target()
		_apply_match_intro()
		return
	if winner_focus_active and camera_preview_scope.is_empty():
		if winner_focus_progress >= 1.0: _place_focus_camera(winner_focus_id)
		return
	_set_camera_mode(preview_mode)

func cancel_winner_focus() -> void:
	if _winner_tween != null and _winner_tween.is_valid(): _winner_tween.kill()
	winner_focus_active = false
	winner_focus_progress = 0.0
	winner_focus_id = ""

func reset_match_camera() -> void:
	cancel_match_intro()
	camera_preview_scope = ""
	camera_preview_id = ""
	cancel_winner_focus()
	for visual: Node3D in entities.values(): visual.reset_floating()
	preview_mode = false
	_set_camera_mode(false)

func focus_winner(id: String, duration: float = 2.0) -> void:
	cancel_match_intro()
	camera_preview_scope = ""
	camera_preview_id = ""
	cancel_winner_focus()
	if not entities.has(id): return
	winner_focus_active = true
	winner_focus_id = id
	var actor: Node3D = entities[id]
	var origin: Transform3D = camera.global_transform
	var origin_fov: float = camera.fov
	var initial_yaw: float = actor.animal_root.rotation.y
	_winner_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_winner_tween.tween_method(func(weight: float) -> void:
		winner_focus_progress = weight
		if not is_instance_valid(actor): return
		var destination: Transform3D = _focus_transform(id)
		camera.global_transform = origin.interpolate_with(destination, weight)
		camera.fov = lerpf(origin_fov, float(camera_settings.victory.fov), weight)
		var facing: Vector3 = destination.origin - actor.global_position
		actor.animal_root.rotation.y = lerp_angle(initial_yaw, atan2(facing.x, facing.z), weight), 0.0, 1.0, duration)

func get_framing_samples() -> Array[Vector3]:
	var points: Array[Vector3] = []
	for edge: Vector2 in IslandStage.outline_points():
		var sea: Vector2 = edge + edge.normalized() * 0.6
		points.append(Vector3(sea.x, WATER_Y, sea.y))
		points.append(Vector3(edge.x, 0.0, edge.y))
	return points

func impact(data: Dictionary) -> void:
	var position_value: Vector3 = _vector(data.get("position", data.get("point", Vector3.ZERO)))
	if data.has("x"):
		position_value = Vector3(float(data["x"]), float(data.get("y", 0.08)), float(data.get("z", 0)))
	var contact_height: float = position_value.y
	position_value.y = 0.065
	var strength: float = clampf(float(data.get("closingSpeed", 2.0)) / 10.0, 0.0, 1.0)
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = 0.26
	ring_mesh.outer_radius = 0.32
	ring_mesh.rings = 48
	ring_mesh.ring_segments = 6
	var material := _material(Color("fff0bd"), 0.3)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var ring: MeshInstance3D = _mesh(ring_mesh, material, position_value, "CollisionShockRing")
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	impact_effects.append({"node": ring, "life": 0.42, "duration": 0.42, "material": material, "expansion": 4.0 + strength * 3.0})
	# A small contact burst makes the instant of impact readable from the
	# overhead camera, while all actual ball displacement remains physical.
	for i: int in 6:
		var angle: float = float(i) / 6.0 * TAU
		var sparkle_mesh := SphereMesh.new()
		sparkle_mesh.radius = 0.035 + strength * 0.02
		sparkle_mesh.height = sparkle_mesh.radius * 2.0
		sparkle_mesh.radial_segments = 6
		sparkle_mesh.rings = 3
		var sparkle_material: StandardMaterial3D = material.duplicate()
		var sparkle: MeshInstance3D = _mesh(sparkle_mesh, sparkle_material,
			Vector3(position_value.x, maxf(contact_height, 0.25), position_value.z), "CollisionContactSpark")
		sparkle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		impact_effects.append({"node": sparkle, "life": 0.22, "duration": 0.22, "material": sparkle_material,
			"velocity": Vector3(cos(angle), 0.35, sin(angle)) * (2.0 + strength * 2.0)})

func set_motion_paused(value: bool) -> void:
	motion_paused = value
	if island_stage != null: island_stage.set_motion_paused(value)
	for visual: Node3D in entities.values():
		visual.set_motion_paused(value)

func _process(dt: float) -> void:
	if intro_camera_active:
		if not motion_paused: _intro_prediction_age += dt
		var predicted: float = maxf(0.0, _intro_authority_remaining - _intro_prediction_age)
		intro_camera_progress = maxf(intro_camera_progress, clampf(1.0 - predicted / maxf(_intro_duration, 0.001), 0.0, 1.0))
		_apply_match_intro()
	if camera_preview_scope == "victory" and entities.has(camera_preview_id): _place_focus_camera(camera_preview_id)
	if not motion_paused: ocean_time += dt
	water_material.set_shader_parameter("water_time", ocean_time)
	for id: Variant in entities:
		var visual: Node3D = entities[id]
		if visual.floating:
			var water: Dictionary = WaterMotion.sample(Vector2(visual.float_anchor.x, visual.float_anchor.z), ocean_time, high_quality)
			visual.set_water_motion(water.height, water.drift, water.tilt)
		var velocity: Vector3 = latest_velocities.get(id, Vector3.ZERO)
		visual.animate_motion(velocity, dt)
	_update_name_bubbles()
	for index: int in range(impact_effects.size() - 1, -1, -1):
		var effect: Dictionary = impact_effects[index]
		var life: float = float(effect["life"]) - dt
		effect["life"] = life
		var ring: MeshInstance3D = effect["node"]
		if life <= 0.0:
			ring.queue_free()
			impact_effects.remove_at(index)
			continue
		var progress: float = 1.0 - life / float(effect.get("duration", 0.42))
		if effect.has("velocity"):
			var velocity: Vector3 = effect["velocity"]
			ring.position += velocity * dt
		else:
			ring.scale = Vector3.ONE * (1.0 + progress * float(effect.get("expansion", 5.0)))
		var material: StandardMaterial3D = effect["material"]
		material.albedo_color.a = 1.0 - progress

func _update_name_bubbles() -> void:
	if name_overlay == null or camera == null:
		return
	var area := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	for id: Variant in name_bubbles:
		var bubble: Control = name_bubbles[id]
		var visual: Node3D = entities.get(id)
		if visual == null or visual.name_label == null:
			bubble.visible = false
			continue
		var anchor: Vector3 = visual.get_name_anchor()
		bubble.visible = not preview_mode and visual.visible and visual.name_label.visible and not camera.is_position_behind(anchor)
		if not bubble.visible:
			continue
		bubble.configure(visual.name_label.text, visual.identity_role)
		var tip: Vector2 = camera.unproject_position(anchor) + Vector2(0, -8)
		# The down-pointing tip stays attached to the character, without world-size text.
		bubble.position = tip - Vector2(bubble.size.x * 0.5, bubble.size.y)
		bubble.visible = area.has_point(tip)

func screen_input_to_world(input: Vector2, at: Vector3) -> Vector2:
	if camera == null or not input.is_finite() or input.length_squared() < 0.000001: return Vector2.ZERO
	var strength: float = minf(input.length(), 1.0)
	if not camera.is_position_behind(at):
		var screen: Vector2 = camera.unproject_position(at)
		var plane := Plane(Vector3.UP, at.y)
		for pixels: float in [24.0, 6.0, 1.0, 0.25]:
			var target: Vector2 = screen + input.normalized() * pixels
			var hit: Variant = plane.intersects_ray(camera.project_ray_origin(target), camera.project_ray_normal(target))
			if hit is Vector3 and Vector3(hit).is_finite():
				var difference: Vector3 = Vector3(hit) - at
				var ground := Vector2(difference.x, difference.z)
				if ground.length_squared() > 0.00000001: return ground.normalized() * strength
	# Only degenerate/off-camera positions use the stable flattened basis.
	var right := Vector2(camera.global_basis.x.x, camera.global_basis.x.z).normalized()
	var forward := Vector2(-camera.global_basis.z.x, -camera.global_basis.z.z).normalized()
	return (right * input.x - forward * input.y).normalized() * strength

func _sync_match_intro(snapshot: Dictionary) -> void:
	var remaining: float = maxf(0.0, float(snapshot.get("introRemaining", 0.0)))
	if not intro_camera_active:
		intro_camera_active = true
		intro_camera_progress = 0.0
		_intro_duration = maxf(0.001, float(snapshot.get("introDuration", 1.6)))
		_intro_authority_remaining = -1.0
		_refresh_intro_target()
	if not is_equal_approx(remaining, _intro_authority_remaining):
		_intro_authority_remaining = remaining
		_intro_prediction_age = 0.0
	intro_camera_progress = maxf(intro_camera_progress, clampf(1.0 - remaining / _intro_duration, 0.0, 1.0))
	_apply_match_intro()

func _refresh_intro_target() -> void:
	_place_match_camera()
	_intro_target = camera.global_transform
	_intro_far = _intro_target
	_intro_far.origin += _intro_target.basis.z * maxf(8.0, _intro_target.origin.length() * 0.65)

func _apply_match_intro() -> void:
	var weight: float = smoothstep(0.0, 1.0, intro_camera_progress)
	camera.global_transform = _intro_far.interpolate_with(_intro_target, weight)
	camera.fov = float(camera_settings.match.fov)

func cancel_match_intro() -> void:
	intro_camera_active = false
	intro_camera_progress = 0.0
	_intro_duration = 0.0
	_intro_authority_remaining = -1.0
	_intro_prediction_age = 0.0
