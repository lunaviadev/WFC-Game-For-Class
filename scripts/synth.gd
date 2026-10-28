extends AudioStreamPlayer

enum { BELL, PLUCK, DRUM, HAT, TICK }

const RATE := 22050.0
const MAX_VOICES := 16

var _playback: AudioStreamGeneratorPlayback
var _kind := PackedInt32Array()
var _freq := PackedFloat64Array()
var _phase := PackedFloat64Array()
var _amp := PackedFloat64Array()
var _decay := PackedFloat64Array()

var _pad_freq := 55.0
var _pad_target := 55.0
var _pad_gain := 0.0
var _pad_gain_target := 0.03
var _p1 := 0.0
var _p2 := 0.0
var _p3 := 0.0
var _lfo := 0.0


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate_mode = AudioStreamGenerator.MIX_RATE_CUSTOM
	gen.mix_rate = RATE
	gen.buffer_length = 0.2
	stream = gen
	volume_db = -3.0
	play()
	_playback = get_stream_playback()


func _process(_delta: float) -> void:
	_render(_playback.get_frames_available())


func bell(freq: float, gain := 0.14) -> void:
	_note(BELL, freq, gain, 1.8)


func pluck(freq: float, gain := 0.12) -> void:
	_note(PLUCK, freq, gain, 0.45)


func drum() -> void:
	_note(DRUM, 150.0, 0.45, 0.3)


func hat() -> void:
	_note(HAT, 0.0, 0.05, 0.05)


func tick(freq: float) -> void:
	_note(TICK, freq, 0.035, 0.08)


func set_pad(root_freq: float, gain: float) -> void:
	_pad_target = root_freq
	_pad_gain_target = gain


func _note(kind: int, freq: float, gain: float, seconds: float) -> void:
	if _kind.size() >= MAX_VOICES:
		_drop(0)
	_kind.append(kind)
	_freq.append(freq)
	_phase.append(0.0)
	_amp.append(gain)
	_decay.append(pow(0.001, 1.0 / (seconds * RATE)))


func _drop(v: int) -> void:
	_kind.remove_at(v)
	_freq.remove_at(v)
	_phase.remove_at(v)
	_amp.remove_at(v)
	_decay.remove_at(v)


func _render(frames: int) -> void:
	if frames <= 0:
		return
	var buffer := PackedVector2Array()
	buffer.resize(frames)
	var step := TAU / RATE
	var voices := _kind.size()
	for s in frames:
		var out := 0.0
		for v in voices:
			var a := _amp[v]
			var p := _phase[v] + _freq[v] * step
			_phase[v] = p
			var k := _kind[v]
			if k == BELL:
				out += a * (sin(p) + 0.45 * sin(p * 2.76) + 0.2 * sin(p * 5.4))
			elif k == PLUCK:
				out += a * (sin(p) + a * 3.0 * sin(p * 2.0))
			elif k == DRUM:
				out += a * sin(p)
				_freq[v] *= 0.99975
			elif k == HAT:
				out += a * randf_range(-1.0, 1.0)
			else:
				out += a * sin(p)
			_amp[v] = a * _decay[v]

		_pad_freq += (_pad_target - _pad_freq) * 0.0003
		_pad_gain += (_pad_gain_target - _pad_gain) * 0.0002
		_p1 += _pad_freq * step
		_p2 += _pad_freq * 1.5 * step
		_p3 += _pad_freq * 2.004 * step
		_lfo += 0.25 * step
		out += _pad_gain * (0.8 + 0.2 * sin(_lfo)) * (sin(_p1) + 0.5 * sin(_p2) + 0.35 * sin(_p3))

		out = out / (1.0 + absf(out))
		buffer[s] = Vector2(out, out)
	_playback.push_buffer(buffer)

	_p1 = fmod(_p1, TAU)
	_p2 = fmod(_p2, TAU)
	_p3 = fmod(_p3, TAU)
	for v in range(voices - 1, -1, -1):
		if _amp[v] < 0.0005:
			_drop(v)
