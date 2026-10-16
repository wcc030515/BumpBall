extends Node
## Native ENet transport. The host owns physics; clients send intent only.
signal room_changed(state: Dictionary)
signal match_started(players: Array)
signal snapshot_received(snapshot: Dictionary)
signal remote_input(id: String, vector: Vector2)
signal remote_effect(kind: String, target_id: String)
signal effect_result(result: Dictionary, actor: String)
signal disconnected(reason: String)

const DEFAULT_PORT: int = 54130
const MAX_IMAGE_BYTES: int = 1500000
const WardrobeStore = preload("res://scripts/wardrobe_store.gd")
var role: String = "offline"
var room_ready: bool = false
var running: bool = false
var guest_peer_id: int = 0
var address: String = "127.0.0.1"
var port: int = DEFAULT_PORT
var local_config: Dictionary = {}
var host_config: Dictionary = {}
var guest_config: Dictionary = {}
var _profiles: Dictionary = {}
var _connect_age: float = 0.0

func _ready() -> void:
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(_connection_failed)
	multiplayer.server_disconnected.connect(_server_disconnected)
	set_process(true)

func _process(dt: float) -> void:
	if role == "guest" and not room_ready:
		_connect_age += dt
		if _connect_age > 12.0:
			_connection_failed()

func create_room(config: Dictionary, selected_port: int = DEFAULT_PORT) -> Dictionary:
	close_room()
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var error: Error = peer.create_server(clampi(selected_port, 1024, 65535), 1)
	if error != OK:
		return {"ok":false, "message":"端口被占用或无法创建房间，请更换端口"}
	multiplayer.multiplayer_peer = peer
	role = "host"
	port = selected_port
	local_config = config.duplicate(true)
	local_config["id"] = "host"
	host_config = local_config.duplicate(true)
	_profiles = {"host":host_config}
	_emit_room("等待另一位主播加入")
	return {"ok":true, "message":"房间已创建 · 端口 %d" % port}

func join_room(config: Dictionary, target_address: String, selected_port: int = DEFAULT_PORT) -> Dictionary:
	close_room()
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	address = target_address.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	port = clampi(selected_port, 1024, 65535)
	var error: Error = peer.create_client(address, port)
	if error != OK:
		return {"ok":false,"message":"无法连接，请检查地址与端口"}
	multiplayer.multiplayer_peer = peer
	role = "guest"
	local_config = config.duplicate(true)
	local_config["id"] = "guest"
	_connect_age = 0.0
	_emit_room("正在连接房主…")
	return {"ok":true,"message":"正在连接…"}

func _connected() -> void:
	if role == "guest":
		_register_player.rpc_id(1, _pack_config(local_config))

@rpc("any_peer", "call_remote", "reliable", 0)
func _register_player(wire: Dictionary) -> void:
	if role != "host" or running:
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender <= 1 or (guest_peer_id != 0 and guest_peer_id != sender):
		return
	guest_peer_id = sender
	guest_config = _unpack_config(wire, "guest")
	_profiles["guest"] = guest_config
	room_ready = true
	_room_ready.rpc_id(sender, _pack_config(host_config), _pack_config(guest_config))
	_emit_room("双方已就绪 · 房主可开始比赛")

@rpc("authority", "call_remote", "reliable", 0)
func _room_ready(host_wire: Dictionary, guest_wire: Dictionary) -> void:
	host_config = _unpack_config(host_wire, "host")
	guest_config = _unpack_config(guest_wire, "guest")
	_profiles = {"host":host_config,"guest":guest_config}
	room_ready = true
	_emit_room("双方已就绪 · 等待房主开赛")

func start_match() -> bool:
	if role != "host" or not room_ready or guest_peer_id == 0:
		return false
	running = true
	_begin_match.rpc_id(guest_peer_id, [_pack_config(host_config), _pack_config(guest_config)])
	match_started.emit([host_config.duplicate(true),guest_config.duplicate(true)])
	return true

@rpc("authority", "call_remote", "reliable", 0)
func _begin_match(players: Array) -> void:
	if role != "guest" or players.size() != 2:
		return
	var decoded: Array = [_unpack_config(players[0], "host"), _unpack_config(players[1], "guest")]
	_profiles = {"host":decoded[0],"guest":decoded[1]}
	running = true
	match_started.emit(decoded)

func send_snapshot(snapshot: Dictionary) -> void:
	if role == "host" and room_ready and running:
		var packed: PackedByteArray = var_to_bytes(snapshot).compress(FileAccess.COMPRESSION_DEFLATE)
		if snapshot.get("status", "") == "finished":
			_receive_final_snapshot.rpc_id(guest_peer_id, packed)
		else:
			_receive_snapshot.rpc_id(guest_peer_id, packed)

@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _receive_snapshot(packed: PackedByteArray) -> void:
	if role != "guest":
		return
	var raw: PackedByteArray = packed.decompress_dynamic(262144, FileAccess.COMPRESSION_DEFLATE)
	if raw.is_empty():
		return
	var decoded: Variant = bytes_to_var(raw)
	if not decoded is Dictionary:
		return
	var snapshot: Dictionary = decoded
	for entity: Dictionary in snapshot.get("entities", []):
		var id: String = str(entity.get("id", ""))
		if _profiles.has(id):
			entity["character"] = _profiles[id].get("character", {})
			entity["ball"] = _profiles[id].get("ball", {})
	snapshot_received.emit(snapshot)

@rpc("authority", "call_remote", "reliable", 0)
func _receive_final_snapshot(packed: PackedByteArray) -> void:
	_receive_snapshot(packed)

func send_input(vector: Vector2) -> void:
	if role == "guest" and running:
		_receive_input.rpc_id(1, vector.limit_length())

@rpc("any_peer", "call_remote", "unreliable_ordered", 2)
func _receive_input(vector: Vector2) -> void:
	if role == "host" and running and multiplayer.get_remote_sender_id() == guest_peer_id:
		if is_finite(vector.x) and is_finite(vector.y):
			remote_input.emit("guest", vector.limit_length())

func request_effect(kind: String, target_id: String) -> void:
	if role == "guest" and running:
		_receive_effect.rpc_id(1, kind, target_id)

@rpc("any_peer", "call_remote", "reliable", 0)
func _receive_effect(kind: String, target_id: String) -> void:
	if role == "host" and running and multiplayer.get_remote_sender_id() == guest_peer_id:
		if kind in ["grow","shrink","speedUp","speedDown","wind"] and target_id in ["host","guest"]:
			remote_effect.emit(kind, target_id)

func send_effect_result(result: Dictionary, actor: String) -> void:
	if role == "host" and room_ready and running:
		_receipt.rpc_id(guest_peer_id, result, actor)

@rpc("authority", "call_remote", "reliable", 0)
func _receipt(result: Dictionary, actor: String) -> void:
	effect_result.emit(result, actor)

func close_room() -> void:
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	role = "offline"
	room_ready = false
	running = false
	guest_peer_id = 0
	_profiles.clear()

func _connection_failed() -> void:
	if role == "guest":
		close_room()
		disconnected.emit("连接失败：请检查房主地址、端口及防火墙")

func _server_disconnected() -> void:
	if role == "guest":
		close_room()
		disconnected.emit("房主已断开，比赛中止")

func _peer_disconnected(id: int) -> void:
	if role == "host" and id == guest_peer_id:
		close_room()
		disconnected.emit("另一位主播已离开，比赛中止")

func _emit_room(status_text: String) -> void:
	var addresses: Array = []
	for ip: String in IP.get_local_addresses():
		if ip.contains(".") and not ip.begins_with("127.") and not ip.begins_with("169.254."):
			addresses.append(ip)
	room_changed.emit({"status":status_text,"role":role,"address":address if role == "guest" else ", ".join(addresses),"port":port,"ready":room_ready,"peerName":guest_config.get("name", "") if role == "host" else host_config.get("name", "")})

func _pack_config(config: Dictionary) -> Dictionary:
	var result: Dictionary = config.duplicate(true)
	for part: String in ["character","ball"]:
		var appearance: Dictionary = result.get(part, {})
		var image_path: String = str(appearance.get("image", ""))
		appearance.erase("image")
		if not image_path.is_empty() and FileAccess.file_exists(image_path):
			var bytes: PackedByteArray = FileAccess.get_file_as_bytes(image_path)
			if bytes.size() <= MAX_IMAGE_BYTES:
				appearance["imageBytes"] = bytes
		result[part] = appearance
	return result

func _unpack_config(wire: Dictionary, id: String) -> Dictionary:
	var result: Dictionary = {"id":id,"name":str(wire.get("name", "玩家1" if id == "host" else "玩家2")).left(24),"human":true,"animal":str(wire.get("animal","rabbit"))}
	if not WardrobeStore.ANIMALS.has(result["animal"]):
		result["animal"] = "rabbit"
	for part: String in ["character","ball"]:
		var appearance: Dictionary = wire.get(part, {}).duplicate(true)
		appearance["image"] = ""
		var bytes: PackedByteArray = appearance.get("imageBytes", PackedByteArray())
		appearance.erase("imageBytes")
		if bytes.size() > 0 and bytes.size() <= MAX_IMAGE_BYTES:
			var image: Image = Image.new()
			if image.load_png_from_buffer(bytes) == OK and image.get_width() <= 1024 and image.get_height() <= 1024:
				DirAccess.make_dir_recursive_absolute("user://remix")
				var hasher: HashingContext = HashingContext.new()
				hasher.start(HashingContext.HASH_SHA256)
				hasher.update(bytes)
				var image_path: String = "user://remix/remote_" + hasher.finish().hex_encode() + ".png"
				if image.save_png(image_path) == OK:
					appearance["image"] = image_path
		result[part] = appearance
	return result
