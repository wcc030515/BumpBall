extends Node3D
## Native arena-wide gust: low flowing curves plus sparse GPU air/leaf particles.
## Integration calls update_wind(snapshot, delta); pass delta=0 while paused.
## No _process/TIME: the simulation snapshot owns the three-second phase.
## API basis: https://docs.godotengine.org/en/stable/classes/class_gpuparticles3d.html
## Visual reference, author explanation:
## https://www.reddit.com/r/godot/comments/1tbz08b/had_fun_making_some_wind_environmental_vfx_past/

const STREAM_SHADER: Shader = preload("res://shaders/wind_streamline.gdshader")
const PARTICLE_SHADER: Shader = preload("res://shaders/wind_particle.gdshader")
const GUST_SECONDS: float = 3.0
const DEFAULT_WIND := Vector3(12.0,0.0,1.8)
var active: bool = false
var remaining_seconds: float = 0.0
var visual_strength: float = 0.0
var wind_direction: Vector3 = DEFAULT_WIND.normalized()
var streams: Array[MeshInstance3D] = []
var particle_nodes: Array[GPUParticles3D] = []
var _materials: Array[ShaderMaterial] = []
var _phase: float = 0.0
var _last_snapshot_remaining: float = -1.0
var _built: bool = false

func _ready() -> void:
	name = "NativeSideWind"
	_build()
	clear()

func _build() -> void:
	if _built: return
	_built = true
	var stream_material := ShaderMaterial.new()
	stream_material.shader = STREAM_SHADER
	stream_material.render_priority = 2
	_materials.append(stream_material)
	# Keep the wind below faces/nameplates. Curves cross the grass and the
	# surrounding air; six lower strands skim the near-sea outside the island.
	for index: int in 20:
		var sea: bool = index >= 14
		var side: float = -1.0 if index % 2 == 0 else 1.0
		var crosswind: float = side * (9.6 + float((index-14)/2) * 1.1) if sea else lerpf(-7.8,7.8,float(index)/13.0)
		var height: float = -0.92 if sea else 0.20 + float(index%3)*0.17
		var seed: float = fposmod(float(index)*0.381966,1.0)
		var curve := Curve3D.new()
		curve.bake_interval = 0.16
		var points: Array[Vector3] = []
		for point_index: int in 7:
			var x: float = lerpf(-13.0,13.0,float(point_index)/6.0)
			var wave: float = sin(x*0.46 + seed*TAU)
			points.append(Vector3(x,height+wave*0.065,crosswind+wave*(0.22 if sea else 0.38)))
		for point_index: int in points.size():
			var previous: Vector3 = points[maxi(0,point_index-1)]
			var following: Vector3 = points[mini(points.size()-1,point_index+1)]
			var tangent: Vector3 = (following-previous)/6.0
			curve.add_point(points[point_index],-tangent,tangent)
		var path := Path3D.new()
		path.name = "SeaAirPath_%02d" % index if sea else "IslandAirPath_%02d" % index
		path.curve = curve
		add_child(path)
		var strand := MeshInstance3D.new()
		strand.name = "SoftDirectionalRibbon"
		strand.mesh = _ribbon(curve,0.13 if index%3==0 else 0.075,seed,0.80 if sea else 0.63)
		strand.material_override = stream_material
		strand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		strand.extra_cull_margin = 1.0
		path.add_child(strand)
		streams.append(strand)
	_make_particles("AirStreaks",0,34,1.60,Vector2(0.075,1.25),Vector3(10.8,0.35,8.9),Vector3(0.0,0.65,0.0),12.8,15.0)
	_make_particles("FlutteringLeaves",1,16,1.75,Vector2(0.19,0.27),Vector3(10.6,0.30,7.8),Vector3(0.0,1.15,0.0),10.8,13.4)
	_make_particles("FineAirMotes",2,22,1.60,Vector2(0.055,0.055),Vector3(10.5,0.40,8.5),Vector3(0.0,0.45,0.0),11.5,14.0)

func _ribbon(curve: Curve3D,width: float,seed: float,opacity: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length: float = curve.get_baked_length()
	for index: int in 97:
		var u: float = float(index)/96.0
		var distance: float = u*length
		var at: Vector3 = curve.sample_baked(distance,true)
		var tangent: Vector3 = (curve.sample_baked(minf(length,distance+0.12),true)-curve.sample_baked(maxf(0.0,distance-0.12),true)).normalized()
		var cross: Vector3 = Vector3.UP.cross(tangent).normalized()
		for edge: int in 2:
			surface.set_uv(Vector2(u,float(edge)))
			surface.set_color(Color(seed,opacity,0.0,1.0))
			surface.set_normal(Vector3.UP)
			surface.add_vertex(at+cross*width*(float(edge)-0.5))
	for index: int in 96:
		var start: int = index*2
		for vertex: int in [start,start+1,start+2,start+1,start+3,start+2]:
			surface.add_index(vertex)
	return surface.commit()

func _make_particles(node_name: String,kind: int,amount: int,lifetime: float,quad_size: Vector2,
	extents: Vector3,at: Vector3,speed_min: float,speed_max: float) -> void:
	var material := ShaderMaterial.new()
	material.shader = PARTICLE_SHADER
	material.render_priority = 3
	material.set_shader_parameter("particle_kind",kind)
	_materials.append(material)
	var quad := QuadMesh.new()
	quad.size = quad_size
	quad.material = material
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = extents
	process.direction = Vector3.RIGHT
	process.spread = 4.0 if kind==1 else 1.7
	process.gravity = Vector3.ZERO
	process.initial_velocity_min = speed_min
	process.initial_velocity_max = speed_max
	process.scale_min = 0.75
	process.scale_max = 1.25
	process.angle_min = 0.0
	process.angle_max = 360.0
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0,0.12,0.72,1.0])
	gradient.colors = PackedColorArray([Color(1,1,1,0),Color(1,1,1,0.86),Color(1,1,1,0.70),Color(1,1,1,0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	var particles := GPUParticles3D.new()
	particles.name = node_name
	particles.amount = amount
	particles.lifetime = lifetime
	particles.local_coords = true
	particles.fixed_fps = 60
	particles.interpolate = true
	particles.use_fixed_seed = true
	particles.seed = 9317+kind*71
	# Explicit GPU stepping follows snapshots and freezes with delta=0.
	particles.speed_scale = 0.0
	particles.visibility_aabb = AABB(Vector3(-15,-2,-14),Vector3(43,7,28))
	particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD if kind==1 else GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.process_material = process
	particles.draw_pass_1 = quad
	particles.position = at
	particles.emitting = false
	add_child(particles)
	particle_nodes.append(particles)

func update_wind(snapshot: Dictionary,delta: float) -> void:
	if not _built: _build()
	if str(snapshot.get("status","ready")) != "playing":
		clear()
		return
	var remaining: float = 0.0
	# A gust's direction comes from the host. Missing legacy fields retain the
	# last valid direction rather than replacing a random gust with fixed wind.
	var direction: Vector3 = wind_direction
	var explicit: Variant = snapshot.get("wind",null)
	if explicit is Dictionary:
		var state: Dictionary = explicit
		if bool(state.get("active",false)): remaining = float(state.get("remaining",0.0))
		var vector: Variant = state.get("direction",null)
		var candidate := Vector3.ZERO
		if vector is Dictionary:
			candidate = Vector3(float(vector.get("x",0.0)),0.0,float(vector.get("z",0.0)))
		elif vector is Vector3:
			candidate = Vector3(vector.x,0.0,vector.z)
		elif vector is Array and vector.size()>=3:
			candidate = Vector3(float(vector[0]),0.0,float(vector[2]))
		if candidate.length_squared()>0.0001: direction = candidate.normalized()
	else:
		for item: Variant in snapshot.get("entities",[]):
			if not item is Dictionary: continue
			var entity: Dictionary = item
			if not bool(entity.get("alive",true)) or bool(entity.get("falling",false)): continue
			var durations: Dictionary = entity.get("effectRemaining",{})
			remaining = maxf(remaining,float(durations.get("wind",0.0)))
	# Interpolate between ENet packets, but use authoritative remaining time
	# when it changes. Delta=0 deliberately prevents any free-running phase.
	var snapshot_remaining: float = remaining
	if active and is_equal_approx(snapshot_remaining,_last_snapshot_remaining) and delta>0.0:
		remaining = maxf(0.0,remaining_seconds-delta)
	_last_snapshot_remaining = snapshot_remaining
	set_wind(direction,remaining,remaining>0.0)

func set_wind(direction: Vector3,remaining: float,is_active: bool) -> void:
	if not _built: _build()
	if not is_active or remaining<=0.0:
		clear()
		return
	var horizontal := Vector3(direction.x,0.0,direction.z)
	var direction_changed: bool = false
	if horizontal.length_squared()>0.0001:
		var next_direction: Vector3 = horizontal.normalized()
		direction_changed = active and next_direction.dot(wind_direction)<0.9999
		wind_direction = next_direction
	rotation.y = -atan2(wind_direction.z,wind_direction.x)
	var was_active: bool = active
	var previous_phase: float = _phase
	var desired_phase: float = clampf(GUST_SECONDS-remaining,0.0,GUST_SECONDS)
	# Consecutive random gusts restart their seeded particles in the new frame;
	# old leaves must not be rotated and reused as if they belonged to this gust.
	var new_gust: bool = not was_active or direction_changed or desired_phase+0.20<previous_phase
	active = true
	if new_gust:
		_phase = desired_phase
		for particles: GPUParticles3D in particle_nodes:
			particles.emitting = true
			particles.restart(true)
	else:
		_phase = maxf(previous_phase,desired_phase)
	remaining_seconds = maxf(0.0,GUST_SECONDS-_phase)
	visual_strength = smoothstep(0.0,0.20,_phase)*smoothstep(0.0,0.34,remaining_seconds)
	var process_seconds: float = _phase if new_gust else maxf(0.0,_phase-previous_phase)
	visible = true
	for material: ShaderMaterial in _materials:
		material.set_shader_parameter("wind_phase",_phase)
		material.set_shader_parameter("wind_strength",visual_strength)
	for particles: GPUParticles3D in particle_nodes:
		if process_seconds>0.0: particles.request_particles_process(process_seconds)

func clear() -> void:
	active = false
	remaining_seconds = 0.0
	visual_strength = 0.0
	_phase = 0.0
	_last_snapshot_remaining = -1.0
	visible = false
	for material: ShaderMaterial in _materials:
		material.set_shader_parameter("wind_strength",0.0)
	for particles: GPUParticles3D in particle_nodes:
		particles.emitting = false
