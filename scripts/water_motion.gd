extends RefCounted
## CPU sample of the existing ocean's Gerstner displacement. Coordinates are
## ocean-local XZ; the sea mesh itself is translated to WATER_Y.

const WATER_Y: float = -1.65
const STEEPNESS: float = 0.48
const DIRECTIONS: Array[Vector2] = [
	Vector2(0.94, 0.34), Vector2(-0.72, 0.68), Vector2(0.28, 0.96),
	Vector2(0.85, -0.52), Vector2(-0.91, -0.41)
]
const WAVES: Array[Vector3] = [
	Vector3(0.21, 12.0, 1.4), Vector3(0.12, 7.3, 1.8),
	Vector3(0.075, 4.2, 2.35), Vector3(0.040, 2.6, 2.8),
	Vector3(0.022, 1.6, 3.6)
]

static func sample(position: Vector2, time: float, high_quality: bool = true) -> Dictionary:
	var height: float = WATER_Y
	var drift: Vector2 = Vector2.ZERO
	var tangent_x := Vector3.RIGHT
	var tangent_z := Vector3(0, 0, 1)
	for index: int in (5 if high_quality else 4):
		var direction: Vector2 = DIRECTIONS[index].normalized()
		var wave: Vector3 = WAVES[index]
		var k: float = TAU / wave.y
		var phase: float = k * direction.dot(position) - time * wave.z
		var sine: float = sin(phase)
		var cosine: float = cos(phase)
		height += wave.x * sine
		drift += direction * wave.x * STEEPNESS * cosine
		tangent_x += Vector3(-STEEPNESS * direction.x * direction.x * wave.x * k * sine,
			direction.x * wave.x * k * cosine, -STEEPNESS * direction.x * direction.y * wave.x * k * sine)
		tangent_z += Vector3(-STEEPNESS * direction.x * direction.y * wave.x * k * sine,
			direction.y * wave.x * k * cosine, -STEEPNESS * direction.y * direction.y * wave.x * k * sine)
	var normal: Vector3 = tangent_z.cross(tangent_x).normalized()
	# A small ring rocks less than the complete surface normal, but follows the
	# same wave phase instead of adding an unrelated sine-wave animation.
	var tilt := Vector2(atan2(normal.z, normal.y), -atan2(normal.x, normal.y)) * 0.55
	tilt.x = clampf(tilt.x, -0.12, 0.12)
	tilt.y = clampf(tilt.y, -0.12, 0.12)
	return {"height": height, "drift": drift, "tilt": tilt}
