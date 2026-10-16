extends RefCounted
class_name IslandCollisionModel

## Native rigid bodies resolve solid contact and gravity. Only the horizontal
## reaction is calibrated here; every contestant uses the same coefficients.
const RESTITUTION: float = 1.0
const SLIDE_DECELERATION: float = 3.6
const MIN_DISTANCE: float = 1.3
const MAX_DISTANCE: float = 8.0
const ZERO_SPEED: float = 0.0001

static func _outward_distance(response: float, first_body: bool) -> float:
	if (first_body and response >= -ZERO_SPEED) or (not first_body and response <= ZERO_SPEED):
		return 0.0
	return response * response / (2.0 * SLIDE_DECELERATION)

static func _scale_response(response: float, first_body: bool, scale: float) -> float:
	# A ceiling scales both related normal components to keep separation, including
	# a continuing heavy striker. The minimum boosts only real outward feedback;
	# it never accelerates a continuing striker or reverses a stopped body.
	if scale < 1.0 or _outward_distance(response, first_body) > 0.0:
		return response * scale
	return response

static func solve(velocity_a: Vector3, velocity_b: Vector3, mass_a: float, mass_b: float, normal: Vector3) -> Dictionary:
	var n: Vector3 = Vector3(normal.x, 0.0, normal.z).normalized()
	if n.length_squared() < 0.5:
		n = Vector3.RIGHT
	var safe_mass_a: float = maxf(mass_a, 0.01)
	var safe_mass_b: float = maxf(mass_b, 0.01)
	var normal_before_a: float = velocity_a.dot(n)
	var normal_before_b: float = velocity_b.dot(n)
	var closing: float = maxf(0.0, normal_before_a - normal_before_b)
	var impulse: float = (1.0 + RESTITUTION) * closing / (1.0 / safe_mass_a + 1.0 / safe_mass_b)
	var delta_a: float = impulse / safe_mass_a
	var delta_b: float = impulse / safe_mass_b
	var raw_after_a: float = normal_before_a - delta_a
	var raw_after_b: float = normal_before_b + delta_b
	# Shared same-direction movement remains ordinary drive. A 5.8 catch of 5.5
	# therefore has common drive 5.5 and a 0.3 response, not a new 5.8 hit slide.
	var common_drive: float = 0.0
	if normal_before_a > ZERO_SPEED and normal_before_b > ZERO_SPEED:
		common_drive = minf(normal_before_a, normal_before_b)
	elif normal_before_a < -ZERO_SPEED and normal_before_b < -ZERO_SPEED:
		common_drive = maxf(normal_before_a, normal_before_b)
	var response_a: float = raw_after_a - common_drive
	var response_b: float = raw_after_b - common_drive
	if absf(response_a) <= ZERO_SPEED:
		response_a = 0.0
	if absf(response_b) <= ZERO_SPEED:
		response_b = 0.0
	var raw_distance_a: float = _outward_distance(response_a, true)
	var raw_distance_b: float = _outward_distance(response_b, false)
	var pair_distance: float = maxf(raw_distance_a, raw_distance_b)
	var pair_scale: float = 1.0
	if pair_distance > 0.0:
		pair_scale = sqrt(clampf(pair_distance, MIN_DISTANCE, MAX_DISTANCE) / pair_distance)
	var nominal_response_a: float = _scale_response(response_a, true, pair_scale)
	var nominal_response_b: float = _scale_response(response_b, false, pair_scale)
	var distance_a: float = _outward_distance(nominal_response_a, true)
	var distance_b: float = _outward_distance(nominal_response_b, false)
	# Native contact travel is reserved near the ceiling with ONE pair multiplier.
	# This preserves unequal recoil and cannot leave a capped victim being pushed
	# by a continuing striker whose related normal motion was not also reduced.
	var physics_hz: float = maxf(1.0, float(Engine.physics_ticks_per_second))
	var native_budget_a: float = 2.0 * delta_a / (1.0 + RESTITUTION) / physics_hz + 0.02
	var native_budget_b: float = 2.0 * delta_b / (1.0 + RESTITUTION) / physics_hz + 0.02
	var contact_scale: float = 1.0
	if distance_a > 0.0:
		contact_scale = minf(contact_scale, sqrt(maxf(MIN_DISTANCE, MAX_DISTANCE - native_budget_a) / distance_a))
	if distance_b > 0.0:
		contact_scale = minf(contact_scale, sqrt(maxf(MIN_DISTANCE, MAX_DISTANCE - native_budget_b) / distance_b))
	var applied_response_a: float = nominal_response_a * contact_scale
	var applied_response_b: float = nominal_response_b * contact_scale
	var normal_after_a: float = common_drive + applied_response_a
	var normal_after_b: float = common_drive + applied_response_b
	var baseline_a: Vector3 = Vector3(velocity_a.x, 0.0, velocity_a.z)
	var baseline_b: Vector3 = Vector3(velocity_b.x, 0.0, velocity_b.z)
	var drive_a: Vector3 = baseline_a - n * normal_before_a + n * common_drive
	var drive_b: Vector3 = baseline_b - n * normal_before_b + n * common_drive
	var preserve_drive: bool = absf(common_drive) > ZERO_SPEED
	var mode: String = "shared_drive" if preserve_drive else "full_response"
	return {
		"closingSpeed": closing, "impulse": impulse,
		"distanceA": distance_a, "distanceB": distance_b,
		"appliedDistanceA": _outward_distance(applied_response_a, true),
		"appliedDistanceB": _outward_distance(applied_response_b, false),
		"nativeContactBudgetA": native_budget_a, "nativeContactBudgetB": native_budget_b,
		"normalBeforeA": normal_before_a, "normalBeforeB": normal_before_b,
		"normalAfterA": normal_after_a, "normalAfterB": normal_after_b,
		"rawNormalAfterA": raw_after_a, "rawNormalAfterB": raw_after_b,
		"outwardA": applied_response_a < -ZERO_SPEED, "outwardB": applied_response_b > ZERO_SPEED,
		"kickA": n * (normal_after_a - normal_before_a),
		"kickB": n * (normal_after_b - normal_before_b),
		"baselineA": baseline_a, "baselineB": baseline_b,
		"pairScale": pair_scale, "sharedScale": pair_scale * contact_scale,
		"nativeContactScale": contact_scale, "commonDrive": common_drive, "responseMode": mode,
		"duration": maxf(absf(applied_response_a), absf(applied_response_b)) / SLIDE_DECELERATION,
		"normal": n,
		"channelA": {"driveVelocity": drive_a, "responseVelocity": n * applied_response_a,
			"normal": n, "preserveDrive": preserve_drive, "mode": mode},
		"channelB": {"driveVelocity": drive_b, "responseVelocity": n * applied_response_b,
			"normal": n, "preserveDrive": preserve_drive, "mode": mode},
	}
