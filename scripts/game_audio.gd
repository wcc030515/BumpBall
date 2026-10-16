extends Node
## Small procedural UI/impact sounds generated as native AudioStreamWAV resources.
var _voices: Array[AudioStreamPlayer] = []
var _cache: Dictionary = {}
var _voice: int = 0
const WIND_LEVEL: float = 0.40
const WIND_FADE_IN: float = 0.20
const WIND_FADE_OUT: float = 0.45
var _wind_player: AudioStreamPlayer
var _wind_active: bool = false
var _wind_paused: bool = false
var _wind_gain: float = 0.0
var _wind_target_gain: float = 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i: int in range(5):
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.volume_db = -17.0
		add_child(player)
		_voices.append(player)
	_wind_player = AudioStreamPlayer.new()
	_wind_player.name = "WindLoop"
	_wind_player.volume_db = -80.0
	_wind_player.stream = _generate_wind()
	add_child(_wind_player)

func set_wind(active: bool, strength: float = 1.0, paused: bool = false) -> void:
	_wind_active = active
	_wind_paused = paused
	_wind_target_gain = WIND_LEVEL * clampf(strength, 0.0, 1.5) if active else 0.0
	if not is_instance_valid(_wind_player):
		return
	# has_stream_playback remains true while stream_paused, so snapshots never
	# restart a paused loop from the beginning or reset its fade envelope.
	if active and not _wind_player.has_stream_playback():
		_wind_gain = 0.0
		_wind_player.volume_db = -80.0
		_wind_player.play()
	_wind_player.stream_paused = paused

func _process(delta: float) -> void:
	if not is_instance_valid(_wind_player) or _wind_paused:
		return
	var fade: float = WIND_FADE_IN if _wind_target_gain > _wind_gain else WIND_FADE_OUT
	_wind_gain = move_toward(_wind_gain, _wind_target_gain, WIND_LEVEL * delta / fade)
	_wind_player.volume_db = linear_to_db(maxf(_wind_gain, 0.0001))
	if not _wind_active and _wind_gain <= 0.0001 and _wind_player.has_stream_playback():
		_wind_player.stop()
		_wind_gain = 0.0
		_wind_player.volume_db = -80.0

func play_tone(kind: String) -> void:
	if _voices.is_empty(): return
	if not _cache.has(kind):
		_cache[kind] = _generate(kind)
	var player: AudioStreamPlayer = _voices[_voice % _voices.size()]
	_voice += 1
	player.stream = _cache[kind]
	player.play()

func _exit_tree() -> void:
	if is_instance_valid(_wind_player):
		_wind_player.stop()
		_wind_player.stream = null
	for player: AudioStreamPlayer in _voices:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_voices.clear()
	_cache.clear()

func _generate_wind() -> AudioStreamWAV:
	# Smooth filtered noise, not a pitched UI cue. The short overlap makes the
	# generated PCM loop continuous at its boundary without an external asset.
	var rate: int = 22050
	var count: int = rate * 4
	var overlap: int = int(float(rate) * 0.12)
	var samples: PackedFloat32Array = PackedFloat32Array()
	samples.resize(count + overlap)
	var random: RandomNumberGenerator = RandomNumberGenerator.new()
	random.seed = 716031
	var fast: float = 0.0
	var slow: float = 0.0
	for i: int in range(count + overlap):
		var noise: float = random.randf_range(-1.0, 1.0)
		fast += (noise - fast) * 0.12
		slow += (fast - slow) * 0.015
		var t: float = float(i) / float(rate)
		var swell: float = 0.84 + 0.10 * sin(TAU * t / 4.0) + 0.06 * sin(TAU * t / 2.0 + 0.7)
		samples[i] = (fast * 0.72 + slow * 0.24) * swell
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 2)
	for i: int in range(count):
		var sample: float = samples[i]
		if i < overlap:
			var weight: float = smoothstep(0.0, 1.0, float(i) / float(overlap - 1))
			sample = lerpf(samples[count + i], sample, weight)
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	var stream: AudioStreamWAV = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = data
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = count
	return stream

func _generate(kind: String) -> AudioStreamWAV:
	var duration: float = 0.09
	var frequency: float = 660.0
	match kind:
		"impact": duration = 0.13; frequency = 130.0
		"gift": duration = 0.23; frequency = 780.0
		"start": duration = 0.36; frequency = 440.0
		"finish": duration = 0.55; frequency = 523.25
	var rate: int = 22050
	var count: int = int(duration * float(rate))
	var data: PackedByteArray = PackedByteArray()
	data.resize(count * 2)
	for i: int in range(count):
		var t: float = float(i) / float(rate)
		var envelope: float = pow(1.0 - t / duration, 2.0) * minf(t * 220.0, 1.0)
		var pitch: float = frequency * (1.0 - t * 2.0) if kind == "impact" else frequency * (1.0 + floorf(t * 10.0) * 0.12)
		var wave: float = sin(TAU * pitch * t) * envelope * 0.35
		data.encode_s16(i * 2, int(wave * 32767.0))
	var stream: AudioStreamWAV = AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream
