extends Node3D
## Approved Blender skin/face clips on a separately rolling Godot ball.
## The visual origin remains the physical ball centre.

const BASE_RADIUS: float = 0.7
const SOURCE_BALL_RADIUS: float = 0.82
const MODEL_SCALE: float = BASE_RADIUS / SOURCE_BALL_RADIUS
const BASE_SPEED: float = 5.8
const MOVE_CADENCE: float = 1.5
const ANIMALS: Array[String] = ["rabbit", "bear", "pig", "cat", "dog", "fox", "panda", "raccoon"]
const BALL_SHADER: Shader = preload("res://shaders/beach_ball.gdshader")
const BallPrints = preload("res://scripts/ball_prints.gd")
const LOCAL_BALL_COLOR := Color("173E69")
const OPPONENT_BALL_COLOR := Color("8F2936")
var ball_root: Node3D
var animal_root: Node3D
var animal_kind: String = "rabbit"
var model_root: Node3D
var animation_players: Array[AnimationPlayer] = []
var ride_skeletons: Array[Skeleton3D] = []
var ride_weight: float = 0.0
var active_motion_clip: String = ""
var match_phase: String = "ready"
var is_winner: bool = false
var is_falling: bool = false
var motion_paused: bool = false
var has_speed_boost: bool = false
var name_label: Label3D
var effect_label: Label3D
var local_ring: MeshInstance3D
var visual_scale: float = 1.0
var animation_time: float = 0.0
var is_local_player: bool = false
var identity_role: String = "npc"
var ball_material: ShaderMaterial
var configured_ball_color: Color = Color("173E69")
static var _species_head_heights: Dictionary = {}
var name_head_height: float = 1.4
var _name_head_skeleton: Skeleton3D
var _name_head_bone: int = -1
var _name_head_rest_y: float = 0.0
var effect_ring: MeshInstance3D
var floating: bool = false
var float_anchor: Vector3 = Vector3.ZERO
var life_ring_root: Node3D
var float_elapsed: float = 0.0
var float_start_body: Vector3 = Vector3.ZERO
var float_start_ball: Vector3 = Vector3.ZERO
var float_water_height: float = -1.65
var float_water_drift: Vector2 = Vector2.ZERO
var float_water_tilt: Vector2 = Vector2.ZERO
var float_turn_progress: float = 0.0
var float_start_yaw: float = 0.0
var float_target_yaw: float = 0.0
const FLOAT_BODY_OFFSET: float = -0.38
const FLOAT_SETTLE_SECONDS: float = 0.55
const BALL_SINK_SECONDS: float = 1.75
const FLOAT_TURN_SECONDS: float = 0.9

func _material(color: Color, roughness: float = 0.75) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = 0.025
	return material

func _color(palette: Array, index: int, fallback: String) -> Color:
	if palette.size() > index and Color.html_is_valid(str(palette[index])):
		return Color(str(palette[index]))
	return Color(fallback)

func _mesh(parent: Node3D, resource: Mesh, material: Material, at: Vector3, size: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = resource
	instance.material_override = material
	instance.position = at
	instance.scale = size
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return instance

func _sphere(parent: Node3D, material: Material, at: Vector3, size: Vector3, detail: int = 16) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = detail
	mesh.rings = 10 if detail >= 16 else 7
	return _mesh(parent, mesh, material, at, size)

func _torus(parent: Node3D, material: Material, inner: float, outer: float, at: Vector3) -> MeshInstance3D:
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner
	mesh.outer_radius = outer
	mesh.rings = 32
	mesh.ring_segments = 8
	return _mesh(parent, mesh, material, at)

func configure(animal: String, character: Dictionary, ball: Dictionary) -> void:
	reset_floating()
	for child: Node in get_children():
		child.free()
	animation_time = 0.0
	ball_root = Node3D.new()
	ball_root.name = "RollingBeachBall"
	add_child(ball_root)
	animal_root = Node3D.new()
	animal_root.name = "UprightAnimal"
	add_child(animal_root)
	animal_kind = animal if animal in ANIMALS else "rabbit"
	animation_players.clear()
	ride_skeletons.clear()
	ride_weight = 0.0
	active_motion_clip = ""
	match_phase = "ready"
	is_winner = false
	is_falling = false
	has_speed_boost = false
	_load_character(character)
	_measure_name_anchor()
	_build_ball(ball)
	name_label = _label(44, 0.009)
	name_label.outline_size = 9
	# Keep the label's text/visible/anchor contract for world and QA callers.
	# The visible name is now a screen-space native Control bubble.
	name_label.modulate = Color(1, 1, 1, 0)
	# A transparent fill does not hide Label3D's independent outline material.
	# Keep only metadata/anchor semantics, on no visible 3D rendering layer.
	name_label.layers = 0
	add_child(name_label)
	effect_label = _label(32, 0.009)
	effect_label.modulate = Color("ffe4a2")
	add_child(effect_label)
	# Retain a compatibility node, with no mesh or material to draw in any state.
	local_ring = MeshInstance3D.new()
	local_ring.name = "RetiredLocalPlayerRing"
	add_child(local_ring)
	local_ring.visible = false
	var glow := _material(Color("94e7df"), 0.3)
	glow.emission_enabled = true
	glow.emission = Color("57b6a7")
	glow.emission_energy_multiplier = 0.3
	effect_ring = _torus(self, glow, 0.77, 0.795, Vector3.ZERO)
	effect_ring.visible = false
	set_visual_scale(1.0)

func _measure_name_anchor() -> void:
	_name_head_skeleton = null
	_name_head_bone = -1
	if not _species_head_heights.has(animal_kind):
		var highest: float = 0.0
		for mesh: MeshInstance3D in model_root.find_children("*", "MeshInstance3D", true, false):
			if mesh.mesh == null or not mesh.is_visible_in_tree(): continue
			var relative: Transform3D = animal_root.global_transform.affine_inverse() * mesh.global_transform
			highest = maxf(highest, (relative * mesh.get_aabb()).end.y)
		_species_head_heights[animal_kind] = highest
	name_head_height = float(_species_head_heights[animal_kind])
	for skeleton: Skeleton3D in ride_skeletons:
		var index: int = skeleton.find_bone("head")
		if index < 0: continue
		_name_head_skeleton = skeleton
		_name_head_bone = index
		_name_head_rest_y = animal_root.to_local(skeleton.to_global(skeleton.get_bone_global_rest(index).origin)).y
		break

func get_name_anchor() -> Vector3:
	if is_instance_valid(_name_head_skeleton) and _name_head_bone >= 0:
		var head: Vector3 = animal_root.to_local(_name_head_skeleton.to_global(_name_head_skeleton.get_bone_global_pose(_name_head_bone).origin))
		return animal_root.to_global(head + Vector3(0, name_head_height - _name_head_rest_y, 0))
	return animal_root.to_global(Vector3(0, name_head_height, 0))

func _load_character(character: Dictionary) -> void:
	# The exported model keeps its editable mesh parts, skin, face bones and
	# baked clips. Its display-only ball is hidden; physics owns our single ball.
	var path: String = "res://assets/animals/%s.glb" % animal_kind
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		push_error("Missing approved animal asset: " + path)
		return
	model_root = packed.instantiate() as Node3D
	model_root.name = "ApprovedAnimalModel"
	model_root.scale = Vector3.ONE * MODEL_SCALE
	model_root.position.y = -SOURCE_BALL_RADIUS * 2.0 * MODEL_SCALE
	animal_root.add_child(model_root)
	_prepare_model(model_root)
	_apply_character_style(character)
	var texture: Texture2D = _load_image(str(character.get("image", "")))
	if texture != null:
		_add_badges(texture, _material(Color("65b9a3")))
	_play_motion_clip("ready_balance")

func _apply_character_style(character: Dictionary) -> void:
	var style_id: String = str(character.get("id", ""))
	var custom: bool = style_id.begins_with("remix-character-") or bool(character.get("is_custom", false))
	var preset_scarf: bool = style_id in ["char-sunset", "char-ocean"]
	if not custom and not preset_scarf:
		return
	var colors: Array = character.get("colors", [])
	if colors.size() < 3:
		return
	for mesh_node: MeshInstance3D in model_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_name: String = String(mesh_node.name).to_lower()
		for surface: int in mesh_node.mesh.get_surface_count():
			var original: Material = mesh_node.mesh.surface_get_material(surface)
			if not original is StandardMaterial3D:
				continue
			var material_name: String = original.resource_name
			var slot: int = _character_color_slot(mesh_name, material_name)
			if slot < 0 or (preset_scarf and slot != 2):
				continue
			var material: StandardMaterial3D = original.duplicate() as StandardMaterial3D
			# Embedded base-colour images are already tinted. A second multiply
			# would make a chosen light colour muddy; retain other PBR maps.
			material.albedo_texture = null
			material.albedo_color = _color(colors, slot, "#ffffff")
			mesh_node.set_surface_override_material(surface, material)

func _character_color_slot(mesh_name: String, material_name: String) -> int:
	if mesh_name.contains("scarf"):
		return 2
	for protected_part: String in ["eye", "mouth", "smile", "cheek", "nose", "teeth", "tongue", "brow", "mask", "tail_ring"]:
		if mesh_name.contains(protected_part):
			return -1
	# Preserve dark panda markings, the raccoon mask/rings and expression parts.
	if material_name in ["Toy_ivory", "Toy_caramel", "Toy_coral", "Roster_cat_fur", "Roster_dog_fur", "Roster_fox_fur", "Roster_panda_white", "Roster_raccoon_fur"]:
		return 0
	if material_name in ["Toy_cream", "Roster_soft_cream", "Roster_dog_ear", "Toy_innerpink_Soft"] or (material_name == "Toy_innerpink" and mesh_name.contains("ear")):
		return 1
	return -1

func _prepare_model(node: Node) -> void:
	if node is Skeleton3D:
		ride_skeletons.append(node as Skeleton3D)
	if node is MeshInstance3D:
		var mesh_node: MeshInstance3D = node as MeshInstance3D
		if String(mesh_node.name).to_lower().contains("ball_independent"):
			mesh_node.visible = false
		else:
			mesh_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if node is AnimationPlayer:
		var player: AnimationPlayer = node as AnimationPlayer
		# Manual advancement uses the same paused clock and actual velocity as
		# the ball, including authoritative snapshots on a PK guest.
		player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		animation_players.append(player)
	for child: Node in node.get_children():
		_prepare_model(child)

func _find_clip(player: AnimationPlayer, clip: String) -> StringName:
	for value: StringName in player.get_animation_list():
		var candidate: String = String(value)
		if candidate == clip or candidate.ends_with("|" + clip) or candidate.ends_with("/" + clip):
			return value
	return &""

func _play_motion_clip(clip: String) -> void:
	if active_motion_clip == clip:
		return
	var keep_phase: bool = active_motion_clip in ["roll_move", "roll_boost"] and clip in ["roll_move", "roll_boost"]
	for player: AnimationPlayer in animation_players:
		var clip_name: StringName = _find_clip(player, clip)
		if clip_name == &"":
			push_error("Missing animal clip %s/%s" % [animal_kind, clip])
			continue
		var phase: float = fmod(player.current_animation_position / maxf(player.current_animation_length, 0.001), 1.0) if keep_phase else 0.0
		var animation: Animation = player.get_animation(clip_name)
		animation.loop_mode = Animation.LOOP_LINEAR
		player.play(clip_name, 0.10)
		if keep_phase:
			player.seek(phase * animation.length, true)
		player.advance(0.0)
	active_motion_clip = clip

func set_match_state(phase: String, winner: bool) -> void:
	match_phase = phase
	is_winner = winner

func face_start_center(direction: Vector3) -> void:
	if direction.length_squared() > 0.0001:
		animal_root.rotation.y = atan2(direction.x, direction.z)

func set_motion_paused(value: bool) -> void:
	motion_paused = value

func _label(font_size: int, pixel_size: float) -> Label3D:
	var label := Label3D.new()
	label.font_size = font_size
	label.pixel_size = pixel_size
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.outline_modulate = Color(0.08, 0.16, 0.18, 0.95)
	label.no_depth_test = true
	# The ocean uses alpha blending. Draw world labels after that pass so rear
	# falling markers are not washed out by the transparent ocean surface.
	label.render_priority = 10
	label.outline_render_priority = 9
	return label

func _load_image(path: String) -> Texture2D:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func _image_material(texture: Texture2D) -> StandardMaterial3D:
	var material := _material(Color.WHITE, 0.47)
	material.albedo_texture = texture
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.25
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _add_badges(texture: Texture2D, accent: Material) -> void:
	var skeletons: Array[Node] = model_root.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		return
	var skeleton: Skeleton3D = skeletons[0] as Skeleton3D
	var attachment := BoneAttachment3D.new()
	attachment.name = "RemixChestAndBack"
	attachment.bone_name = "spine"
	skeleton.add_child(attachment)
	for side: float in [-1.0, 1.0]:
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		for segment: int in 40:
			var angle_a: float = float(segment) / 40.0 * TAU
			var angle_b: float = float(segment + 1) / 40.0 * TAU
			for point: Vector2 in [Vector2.ZERO, Vector2(cos(angle_a), sin(angle_a)), Vector2(cos(angle_b), sin(angle_b))]:
				surface.set_normal(Vector3(0, 0, side))
				surface.set_uv(Vector2(point.x * side * 0.5 + 0.5, -point.y * 0.5 + 0.5))
				surface.add_vertex(Vector3(point.x * 0.22, point.y * 0.22, 0))
		_mesh(attachment, surface.commit(), _image_material(texture), Vector3(0, 0.20, side * 0.355))
		var border := _torus(attachment, accent, 0.22, 0.238, Vector3(0, 0.20, side * 0.35))
		border.rotation.x = PI * 0.5

func _build_ball(appearance: Dictionary) -> void:
	# Keep the single base colour and put the approved species print in two
	# large spherical medallions. Mesh-space mapping rotates with the ball.
	var palette: Array = appearance.get("colors", ["#173E69"])
	var base: Color = _color(palette, 0, "#173E69")
	configured_ball_color = base
	var material := ShaderMaterial.new()
	material.shader = BALL_SHADER
	material.set_shader_parameter("color_a", base)
	material.set_shader_parameter("footprint_mask", BallPrints.mask_for(animal_kind))
	material.set_shader_parameter("footprint_ink", BallPrints.ink_for(animal_kind, base))
	material.set_shader_parameter("medallion_radius", 0.8)
	ball_material = material
	_apply_role_ball_style()
	var sphere := SphereMesh.new()
	sphere.radius = BASE_RADIUS
	sphere.height = BASE_RADIUS * 2.0
	sphere.radial_segments = 48
	sphere.rings = 28
	_mesh(ball_root, sphere, material, Vector3.ZERO)
	# Appearance data is kept intact; character badges remain supported.

func set_visual_scale(value: float) -> void:
	# Expiring buffs still arrive in snapshots after elimination. They must not
	# move the swimmer back onto the sinking ball or reset its descent.
	if floating:
		return
	visual_scale = clampf(value, 0.25, 3.0)
	if ball_root == null:
		return
	ball_root.scale = Vector3.ONE * visual_scale
	animal_root.position.y = BASE_RADIUS * visual_scale
	name_label.position.y = BASE_RADIUS * visual_scale + name_head_height
	effect_label.position.y = BASE_RADIUS * visual_scale + 1.93
	local_ring.position.y = -BASE_RADIUS * visual_scale + 0.045
	local_ring.scale = Vector3.ONE * visual_scale
	effect_ring.scale = Vector3.ONE * visual_scale

func set_label(text: String, is_local: bool) -> void:
	# Older callers only know local/NPC. Preserve an already known human rival.
	set_player_identity(text, is_local, is_local or identity_role == "opponent")

func set_player_identity(text: String, is_local: bool, is_human: bool) -> void:
	if name_label == null:
		return
	is_local_player = is_local
	name_label.text = "你" if is_local else text
	name_label.modulate = Color(1, 1, 1, 0)
	local_ring.visible = false
	var next_role: String = "local" if is_local else ("opponent" if is_human else "npc")
	if identity_role != next_role:
		identity_role = next_role
		_apply_role_ball_style()

func _apply_role_ball_style() -> void:
	if ball_material == null:
		return
	var color: Color = configured_ball_color
	if identity_role == "local":
		color = LOCAL_BALL_COLOR
	elif identity_role == "opponent":
		color = OPPONENT_BALL_COLOR
	ball_material.set_shader_parameter("color_a", color)
	ball_material.set_shader_parameter("footprint_ink", BallPrints.ink_for(animal_kind, color))

func set_effects(effects: Variant) -> void:
	has_speed_boost = false
	var labels: Array[String] = []
	var names: Dictionary = {"grow": "变大", "shrink": "变小", "speedUp": "加速", "speedDown": "减速"}
	if effects is Array:
		for effect: Variant in effects:
			var kind: String = str(effect.get("kind", effect.get("type", ""))) if effect is Dictionary else str(effect)
			if kind == "speedUp":
				has_speed_boost = true
			if names.has(kind) and not labels.has(str(names[kind])):
				labels.append(str(names[kind]))
	elif effects is Dictionary:
		for key: Variant in effects:
			if str(key) == "speedUp" and float(effects[key]) > 0.0:
				has_speed_boost = true
			if names.has(str(key)) and float(effects[key]) > 0.0:
				labels.append(str(names[str(key)]))
	effect_label.text = ("互动×%d" % labels.size()) if labels.size() > 3 else " · ".join(labels)
	effect_ring.visible = not labels.is_empty() and not floating and not is_falling
	effect_label.visible = not floating and not is_falling

func set_fall_state(falling: bool, alive: bool) -> void:
	is_falling = falling
	if not falling and not floating:
		effect_label.visible = true
		return
	# Elimination is already shown by the fall and life ring. Keep only the name.
	if is_local_player:
		name_label.text = "你"
	effect_label.visible = false
	local_ring.visible = false
	effect_ring.visible = false

func start_floating(anchor: Vector3) -> void:
	if floating:
		return
	# Preserve both child positions while moving the visual origin away from the
	# rigid body. The presentation now lives at its fixed water-entry point.
	var body_at: Vector3 = animal_root.global_position
	var ball_at: Vector3 = ball_root.global_position
	float_start_yaw = animal_root.rotation.y
	float_turn_progress = 0.0
	float_anchor = anchor
	floating = true
	float_elapsed = 0.0
	float_water_height = anchor.y
	float_water_drift = Vector2.ZERO
	float_water_tilt = Vector2.ZERO
	global_position = Vector3(anchor.x, 0.0, anchor.z)
	var inward: Vector3 = global_transform.basis.inverse() * Vector3(-anchor.x, 0, -anchor.z)
	float_target_yaw = atan2(inward.x, inward.z) if inward.length_squared() > 0.0001 else float_start_yaw
	animal_root.global_position = body_at
	ball_root.global_position = ball_at
	float_start_body = animal_root.position
	float_start_ball = ball_root.position
	ride_weight = 0.0
	local_ring.visible = false
	effect_ring.visible = false
	effect_label.visible = false
	if is_local_player:
		name_label.text = "你"
	_build_life_ring()
	_play_motion_clip("ready_balance")

func _build_life_ring() -> void:
	if is_instance_valid(life_ring_root):
		life_ring_root.visible = true
		return
	life_ring_root = Node3D.new()
	life_ring_root.name = "LifeRing"
	animal_root.add_child(life_ring_root)
	# The torso is unchanged. A separate native torus supports its upper waist,
	# with a thin cream rope making the ring legible against the blue water.
	var ring: MeshInstance3D = _torus(life_ring_root, _material(Color("ffb85a"), 0.43), 0.285, 0.565, Vector3(0, 0.43, 0))
	ring.name = "InflatableLifeRing"
	var rope: MeshInstance3D = _torus(life_ring_root, _material(Color("fff0cf"), 0.58), 0.552, 0.578, Vector3(0, 0.445, 0))
	rope.name = "LifeRingOuterRope"
	for side: float in [-1.0, 1.0]:
		var handle: MeshInstance3D = _torus(life_ring_root, _material(Color("fff0cf"), 0.58), 0.06, 0.083, Vector3(side * 0.59, 0.43, 0))
		handle.name = "LifeRingHandleLeft" if side < 0 else "LifeRingHandleRight"

func set_water_motion(height: float, drift: Vector2, tilt: Vector2) -> void:
	if not floating or motion_paused:
		return
	float_water_height = height
	float_water_drift = drift
	float_water_tilt = tilt

func reset_floating() -> void:
	floating = false
	float_anchor = Vector3.ZERO
	float_elapsed = 0.0
	float_start_body = Vector3.ZERO
	float_start_ball = Vector3.ZERO
	float_water_height = -1.65
	float_water_drift = Vector2.ZERO
	float_water_tilt = Vector2.ZERO
	float_turn_progress = 0.0
	float_start_yaw = 0.0
	float_target_yaw = 0.0
	if is_instance_valid(life_ring_root):
		life_ring_root.free()
	life_ring_root = null
	if is_instance_valid(ball_root):
		ball_root.visible = true
		ball_root.position = Vector3.ZERO
	if is_instance_valid(animal_root):
		animal_root.position = Vector3(0, BASE_RADIUS * visual_scale, 0)
		animal_root.rotation.x = 0.0
		animal_root.rotation.y = 0.0
		animal_root.rotation.z = 0.0

func _animate_floating(dt: float) -> void:
	float_elapsed += dt
	# Start from the exact landing heading and take the shortest smooth arc to
	# the stage. The common paused clock freezes this turn with the swimmer.
	float_turn_progress = clampf(float_elapsed / FLOAT_TURN_SECONDS, 0.0, 1.0)
	var turn_weight: float = smoothstep(0.0, 1.0, float_turn_progress)
	animal_root.rotation.y = lerp_angle(float_start_yaw, float_target_yaw, turn_weight)
	_play_motion_clip("ready_balance")
	for player: AnimationPlayer in animation_players:
		player.speed_scale = 1.0
		player.advance(dt)
	# Feet remain short and relaxed below the ring. Only the short arms ease
	# outward, while the existing ready clip retains each animal's blinking.
	for skeleton: Skeleton3D in ride_skeletons:
		for side: String in ["L", "R"]:
			var index: int = skeleton.find_bone("arm." + side)
			if index < 0:
				continue
			var axis: Vector3 = (skeleton.get_bone_global_rest(index).basis.inverse() * Vector3(0, 0, 1)).normalized()
			var sign_value: float = 1.0 if side == "L" else -1.0
			var angle: float = sign_value * (0.38 + sin(animation_time * 1.7) * 0.025)
			skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index) * Quaternion(axis, angle))
	var settle: float = smoothstep(0.0, FLOAT_SETTLE_SECONDS, float_elapsed)
	var target_body := Vector3(float_water_drift.x, float_water_height + FLOAT_BODY_OFFSET, float_water_drift.y)
	animal_root.position = float_start_body.lerp(target_body, settle)
	animal_root.rotation.x = float_water_tilt.x * settle
	animal_root.rotation.z = float_water_tilt.y * settle
	var sinking: float = smoothstep(0.0, BALL_SINK_SECONDS, float_elapsed)
	var submerged_y: float = float_water_height - BASE_RADIUS * visual_scale * 2.0 - 0.2
	ball_root.position = float_start_ball.lerp(Vector3(float_start_ball.x, submerged_y, float_start_ball.z), sinking)
	ball_root.visible = float_elapsed < BALL_SINK_SECONDS
	name_label.position = animal_root.position + Vector3(0, name_head_height, 0)
	local_ring.visible = false
	effect_ring.visible = false
	effect_label.visible = false

func animate_motion(velocity: Vector3, dt: float) -> void:
	if motion_paused:
		return
	animation_time += dt
	if floating:
		_animate_floating(dt)
		return
	var horizontal := Vector3(velocity.x, 0, velocity.z)
	var speed: float = horizontal.length()
	if speed > 0.05 and not (is_winner and match_phase == "finished"):
		ball_root.rotate(Vector3.UP.cross(horizontal.normalized()), speed * dt / (BASE_RADIUS * visual_scale))
		ball_root.transform.basis = ball_root.transform.basis.orthonormalized().scaled(Vector3.ONE * visual_scale)
		var target: float = atan2(horizontal.x, horizontal.z)
		animal_root.rotation.y = lerp_angle(animal_root.rotation.y, target, minf(dt * 10.0, 1.0))
	var desired: String = "ready_balance"
	if is_falling:
		desired = "fall"
	elif is_winner and match_phase == "finished":
		desired = "victory"
	elif match_phase == "playing" and speed > 0.12:
		desired = "roll_boost" if has_speed_boost else "roll_move"
	_play_motion_clip(desired)
	var cadence: float = MOVE_CADENCE * speed / BASE_SPEED if desired in ["roll_move", "roll_boost"] else 1.0
	for player: AnimationPlayer in animation_players:
		player.speed_scale = cadence
		player.advance(dt)
	_apply_ride_sway(desired, speed, dt)
	if effect_ring != null:
		effect_ring.rotation.z = sin(animation_time * 2.0) * 0.12

func _apply_ride_sway(clip: String, speed: float, dt: float) -> void:
	var riding: bool = clip in ["roll_move", "roll_boost"]
	ride_weight = move_toward(ride_weight, clampf(speed / BASE_SPEED, 0.0, 1.0) if riding else 0.0, dt * 7.0)
	if not riding or animation_players.is_empty(): return
	var player: AnimationPlayer = animation_players[0]
	var phase: float = player.current_animation_position / maxf(player.current_animation_length, 0.001) * TAU
	var side: float = sin(phase) * ride_weight
	for skeleton: Skeleton3D in ride_skeletons:
		var spine: int = skeleton.find_bone("spine")
		var head_bone: int = skeleton.find_bone("head")
		if spine >= 0:
			var rotation: Quaternion = skeleton.get_bone_pose_rotation(spine)
			skeleton.set_bone_pose_rotation(spine, rotation * Quaternion(Vector3(0, 0, 1), -side * 0.09))
			var at: Vector3 = skeleton.get_bone_pose_position(spine)
			at.x += side * 0.032
			at.y += (1.0 - cos(phase * 2.0)) * 0.007 * ride_weight
			skeleton.set_bone_pose_position(spine, at)
		if head_bone >= 0:
			var rotation: Quaternion = skeleton.get_bone_pose_rotation(head_bone)
			skeleton.set_bone_pose_rotation(head_bone, rotation * Quaternion(Vector3(0, 0, 1), side * 0.025))
