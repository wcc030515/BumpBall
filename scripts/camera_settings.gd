extends RefCounted
## Local presentation preferences, independent of player appearance and networking.
const PROFILE_PATH := "user://camera_settings.json"
const PROFILE_VERSION := 2
const DEFAULTS: Dictionary = {
	"match": {"height": 12.0, "distance": 15.5, "fov": 40.0, "yaw": -11.7},
	"victory": {"height": 4.523996466, "distance": 6.354011015, "fov": 42.0, "yaw": 32.275644315}
}
const LIMITS: Dictionary = {
	"match": {"height": Vector2(8, 55), "distance": Vector2(8, 55), "fov": Vector2(25, 75), "yaw": Vector2(-180, 180)},
	"victory": {"height": Vector2(2, 14), "distance": Vector2(3, 20), "fov": Vector2(25, 75), "yaw": Vector2(-180, 180)}
}
var settings: Dictionary = DEFAULTS.duplicate(true)
var profile_path: String = PROFILE_PATH

func update_scope(scope: String, values: Dictionary) -> bool:
	if not DEFAULTS.has(scope): return false
	for key: String in DEFAULTS[scope]:
		var value: Variant = values.get(key)
		if (value is float or value is int) and is_finite(float(value)):
			var limits: Vector2 = LIMITS[scope][key]
			settings[scope][key] = clampf(float(value), limits.x, limits.y)
	return true

func reset_scope(scope: String) -> bool:
	if not DEFAULTS.has(scope): return false
	settings[scope] = DEFAULTS[scope].duplicate(true)
	return true

func load_profile() -> void:
	if not FileAccess.file_exists(profile_path): return
	var file := FileAccess.open(profile_path, FileAccess.READ)
	if file == null: return
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not data is Dictionary or not data.get("settings") is Dictionary: return
	for scope: String in DEFAULTS:
		if data.settings.get(scope) is Dictionary: update_scope(scope, data.settings[scope])
	var stored_version: Variant = data.get("version", 1)
	var version: int = int(stored_version) if stored_version is int or stored_version is float else 1
	if version < PROFILE_VERSION:
		# Apply the approved match framing once; keep the user's victory framing.
		# Saving v2 lets later slider changes survive subsequent game launches.
		reset_scope("match")
		save_profile()

func save_profile() -> bool:
	var file := FileAccess.open(profile_path + ".tmp", FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify({"version": PROFILE_VERSION, "settings": settings}, "\t"))
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK: return false
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(profile_path + ".tmp"), ProjectSettings.globalize_path(profile_path)) == OK
