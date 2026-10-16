extends RefCounted

const PROFILE_PATH: String = "user://wardrobe.json"
const REMIX_COST: int = 20
const ANIMALS: Dictionary = {
	"rabbit":"小兔", "bear":"小熊", "pig":"小猪", "cat":"小猫",
	"dog":"小狗", "fox":"小狐狸", "panda":"熊猫", "raccoon":"小浣熊"
}
const DEFAULT_CHARACTERS: Array = [
	{"id":"char-mint", "name":"薄荷假日", "colors":["#f4e5d2", "#5bbdac", "#fc8b70"], "image":""},
	{"id":"char-sunset", "name":"落日桃桃", "colors":["#edb8a7", "#fc8b70", "#ffe4a4"], "image":""},
	{"id":"char-ocean", "name":"海盐蓝", "colors":["#dbe6ed", "#5c91b6", "#f7e7c8"], "image":""}
]
const DEFAULT_BALLS: Array = [
	{"id":"ball-night", "name":"深海蓝", "colors":["#173e69", "#173e69", "#173e69"], "image":""},
	{"id":"ball-mint", "name":"海岛薄荷", "colors":["#52bda7", "#52bda7", "#52bda7"], "image":""},
	{"id":"ball-coral", "name":"珊瑚日落", "colors":["#f58e76", "#f58e76", "#f58e76"], "image":""},
	{"id":"ball-ocean", "name":"深海汽水", "colors":["#478bb9", "#478bb9", "#478bb9"], "image":""}
]

var points: int = 100
var characters: Array = DEFAULT_CHARACTERS.duplicate(true)
var balls: Array = DEFAULT_BALLS.duplicate(true)
var selection: Dictionary = {"animal":"rabbit", "character":DEFAULT_CHARACTERS[0].duplicate(true), "ball":DEFAULT_BALLS[0].duplicate(true)}
var last_error: String = ""

func load_profile() -> void:
	if not FileAccess.file_exists(PROFILE_PATH):
		return
	var file: FileAccess = FileAccess.open(PROFILE_PATH, FileAccess.READ)
	if file == null:
		last_error = "无法读取本地衣柜存档"
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		last_error = "衣柜存档损坏，已使用初始样式"
		return
	var data: Dictionary = parsed as Dictionary
	points = maxi(0, int(data.get("points", 100)))
	characters = _restore_styles(data.get("characters", []), DEFAULT_CHARACTERS)
	balls = _restore_styles(data.get("balls", []), DEFAULT_BALLS)
	var selection_value: Variant = data.get("selection", {})
	var saved_selection: Dictionary = selection_value as Dictionary if selection_value is Dictionary else {}
	var animal: String = str(saved_selection.get("animal", "rabbit"))
	selection["animal"] = animal if ANIMALS.has(animal) else "rabbit"
	var saved_character: Variant = saved_selection.get("character", {})
	var saved_ball: Variant = saved_selection.get("ball", {})
	var character_id: String = str(saved_character.get("id", "char-mint")) if saved_character is Dictionary else "char-mint"
	var ball_id: String = str(saved_ball.get("id", "ball-mint")) if saved_ball is Dictionary else "ball-mint"
	# Upgrade only the old default once. Explicit later choices and all custom
	# Remix selections remain the user's choice, including after restarting.
	if int(data.get("version",1)) < 2 and ball_id == "ball-mint": ball_id = "ball-night"
	selection["character"] = _find_style(characters, character_id)
	selection["ball"] = _find_style(balls, ball_id)

func save_profile() -> bool:
	var file: FileAccess = FileAccess.open(PROFILE_PATH + ".tmp", FileAccess.WRITE)
	if file == null:
		last_error = "无法写入本地存档，请检查目录权限"
		return false
	file.store_string(JSON.stringify({"version":2, "points":points, "characters":characters, "balls":balls, "selection":selection}, "\t"))
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK:
		last_error = "本地存档写入失败（%s）" % write_error
		return false
	var error: Error = DirAccess.rename_absolute(ProjectSettings.globalize_path(PROFILE_PATH + ".tmp"), ProjectSettings.globalize_path(PROFILE_PATH))
	if error != OK:
		last_error = "保存衣柜失败（%s）" % error
		return false
	last_error = ""
	return true

func award_points(amount: int) -> void:
	if amount <= 0:
		return
	points += amount
	save_profile()

func select_animal(kind: String) -> void:
	if not ANIMALS.has(kind):
		return
	selection["animal"] = kind
	save_profile()

func select_style(category: String, id: String) -> void:
	if category not in ["character", "ball"]:
		return
	var styles: Array = characters if category == "character" else balls
	for item: Dictionary in styles:
		if str(item.get("id", "")) == id:
			selection[category] = item.duplicate(true)
			save_profile()
			return

func save_remix(category: String, colors: Array, image_path: String = "") -> Dictionary:
	if category not in ["character", "ball"] or (category == "character" and colors.size() != 3) or (category == "ball" and colors.is_empty()):
		return {"ok":false, "message":"角色请选择三种颜色，球体请选择一种颜色"}
	if category == "ball" and not image_path.is_empty():
		return {"ok":false, "message":"球体仅支持纯色，图片创作可用于角色"}
	if points < REMIX_COST:
		return {"ok":false, "message":"需要 20 Remix 积分，开赛互动可获得积分"}
	var saved_image: String = ""
	if not image_path.is_empty():
		saved_image = crop_image(image_path)
		if saved_image.is_empty():
			return {"ok":false, "message":last_error}
	var safe_colors: Array = []
	for value: Variant in colors:
		safe_colors.append("#" + Color.from_string(str(value), Color.WHITE).to_html(false))
	if category == "ball": safe_colors = [safe_colors[0],safe_colors[0],safe_colors[0]]
	var stamp: String = str(Time.get_unix_time_from_system()).replace(".", "-") + "-" + str(Time.get_ticks_usec())
	var title: String = "角色创作" if category == "character" else "球体创作"
	var list: Array = characters if category == "character" else balls
	var style: Dictionary = {"id":"remix-" + category + "-" + stamp, "name":title + " %02d" % (list.size() - 2), "colors":safe_colors, "image":saved_image}
	var previous_selection: Dictionary = selection[category].duplicate(true)
	list.append(style)
	selection[category] = style.duplicate(true)
	points -= REMIX_COST
	if not save_profile():
		list.pop_back()
		selection[category] = previous_selection
		points += REMIX_COST
		return {"ok":false, "message":last_error}
	return {"ok":true, "message":"新造型已永久保存，并已装备", "style":style}

func crop_image(source_path: String) -> String:
	var source: Image = Image.new()
	var error: Error = source.load(source_path)
	if error != OK or source.is_empty():
		last_error = "无法读取图片，请选择 PNG、JPG、WEBP 等图片"
		return ""
	var side: int = mini(source.get_width(), source.get_height())
	var start: Vector2i = Vector2i((source.get_width() - side) / 2, (source.get_height() - side) / 2)
	var cropped: Image = source.get_region(Rect2i(start, Vector2i(side, side)))
	cropped.convert(Image.FORMAT_RGBA8)
	cropped.resize(512, 512, Image.INTERPOLATE_LANCZOS)
	for y: int in range(512):
		for x: int in range(512):
			var distance: float = Vector2(float(x) + 0.5 - 256.0, float(y) + 0.5 - 256.0).length()
			var pixel: Color = cropped.get_pixel(x, y)
			pixel.a *= clampf(256.0 - distance, 0.0, 1.0)
			cropped.set_pixel(x, y, pixel)
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://remix"))
	if directory_error != OK:
		last_error = "无法创建本地图片目录"
		return ""
	var filename: String = "user://remix/" + str(Time.get_ticks_usec()) + "-" + str(randi()) + ".png"
	if cropped.save_png(filename) != OK:
		last_error = "圆形图片保存失败"
		return ""
	last_error = ""
	return filename

func _find_style(styles: Array, id: String) -> Dictionary:
	for style: Dictionary in styles:
		if str(style.get("id", "")) == id:
			return style.duplicate(true)
	return styles[0].duplicate(true)

func _restore_styles(raw: Variant, defaults: Array) -> Array:
	var restored: Array = defaults.duplicate(true)
	if not raw is Array:
		return restored
	var known_ids: Array = []
	for item: Dictionary in restored:
		known_ids.append(str(item["id"]))
	for value: Variant in raw:
		if not value is Dictionary:
			continue
		var style: Dictionary = value as Dictionary
		var id: String = str(style.get("id", ""))
		var colors: Variant = style.get("colors", [])
		if id.is_empty() or id in known_ids or not colors is Array or colors.size() != 3:
			continue
		var safe_colors: Array = []
		for color: Variant in colors:
			safe_colors.append("#" + Color.from_string(str(color), Color.WHITE).to_html(false))
		var image: String = str(style.get("image", ""))
		if not image.begins_with("user://remix/") or not FileAccess.file_exists(image):
			image = ""
		restored.append({"id":id, "name":str(style.get("name", "我的创作")), "colors":safe_colors, "image":image})
		known_ids.append(id)
	return restored
