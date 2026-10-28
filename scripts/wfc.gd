extends RefCounted

const DX := [1, -1, 0, 0]
const DY := [0, 0, 1, -1]

var width: int
var height: int
var domains := PackedInt32Array()
var pins := PackedInt32Array()
var changed := PackedInt32Array()
var repairs := 0
var guide_strength := 1.0

var _n_tiles: int
var _all: int
var _weights: PackedFloat32Array
var _levels: PackedInt32Array
var _adj := PackedInt32Array()
var _compat := PackedInt32Array()
var _entropy := PackedFloat32Array()
var _single := PackedInt32Array()
var _guide := PackedFloat32Array()
var _jitter := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()
var _noise := FastNoiseLite.new()


func _init(w: int, h: int, adjacency: Array, weights: Array, levels: Array) -> void:
	width = w
	height = h
	_n_tiles = weights.size()
	_all = (1 << _n_tiles) - 1
	_weights = PackedFloat32Array(weights)
	_levels = PackedInt32Array(levels)
	domains.resize(w * h)
	pins.resize(w * h)
	_guide.resize(w * h)
	_jitter.resize(w * h)

	_adj.resize(_n_tiles)
	for t in _n_tiles:
		_adj[t] |= 1 << t
		for other in adjacency[t]:
			_adj[t] |= 1 << other
			_adj[other] |= 1 << t

	var size := _all + 1
	_compat.resize(size)
	_entropy.resize(size)
	_single.resize(size)
	for m in size:
		var compat := 0
		var sum_w := 0.0
		var sum_wlogw := 0.0
		var count := 0
		var last := -1
		for t in _n_tiles:
			if m & (1 << t):
				compat |= _adj[t]
				sum_w += _weights[t]
				sum_wlogw += _weights[t] * log(_weights[t])
				count += 1
				last = t
		_compat[m] = compat
		_entropy[m] = log(sum_w) - sum_wlogw / sum_w if sum_w > 0.0 else 0.0
		_single[m] = last if count == 1 else -1


func reset(seed_value: int) -> void:
	_rng.seed = seed_value
	domains.fill(_all)
	pins.fill(-1)
	changed.clear()
	repairs = 0
	_noise.seed = seed_value
	_noise.frequency = 0.055
	_noise.fractal_octaves = 3
	var radius := width / TAU
	for y in height:
		for x in width:
			var a := TAU * x / width
			var v := _noise.get_noise_3d(cos(a) * radius, y, sin(a) * radius)
			_guide[y * width + x] = clampf((v + 0.4) * 7.5, 0.0, 6.0)
			_jitter[y * width + x] = _rng.randf() * 0.001


func tile_at(i: int) -> int:
	return _single[domains[i]]


func count_collapsed() -> int:
	var count := 0
	for m in domains:
		if _single[m] >= 0:
			count += 1
	return count


func guide_at(i: int) -> float:
	return _guide[i]


func step(cx := 0, cy := 0, radius := -1) -> int:
	changed.clear()
	var i := _lowest_entropy_cell(cx, cy, radius)
	if i < 0:
		return -1
	domains[i] = 1 << _choose_tile(i)
	changed.append(i)
	if not _propagate(PackedInt32Array([i])):
		_repair(i)
	return i


func pin(i: int, tile: int) -> bool:
	changed.clear()
	if pins[i] == tile:
		return true
	pins[i] = tile
	if _rebuild(i, 2) or _rebuild(i, 5) or _rebuild(i, -1):
		return true
	pins[i] = -1
	_rebuild(i, -1)
	return false


func lock(i: int) -> void:
	pins[i] = tile_at(i)


func unlock(i: int) -> void:
	pins[i] = -1


func erase(i: int, radius: int) -> void:
	changed.clear()
	var cx := i % width
	var cy := i / width
	for j in pins.size():
		if in_region(j, cx, cy, radius):
			pins[j] = -1
	if not _rebuild(i, radius):
		_rebuild(i, -1)


func _lowest_entropy_cell(cx: int, cy: int, radius: int) -> int:
	var best := -1
	var best_e := INF
	for i in domains.size():
		var m := domains[i]
		if _single[m] >= 0 or not in_region(i, cx, cy, radius):
			continue
		var e := _entropy[m] + _jitter[i]
		if e < best_e:
			best_e = e
			best = i
	return best


func _choose_tile(i: int) -> int:
	var m := domains[i]
	var total := 0.0
	for t in _n_tiles:
		if m & (1 << t):
			total += _tile_weight(t, i)
	var r := _rng.randf() * total
	var pick := -1
	for t in _n_tiles:
		if m & (1 << t):
			pick = t
			r -= _tile_weight(t, i)
			if r <= 0.0:
				break
	return pick


func _tile_weight(t: int, i: int) -> float:
	var d := _levels[t] - _guide[i]
	return _weights[t] * exp(-1.5 * d * d * guide_strength)


func _propagate(stack: PackedInt32Array) -> bool:
	while not stack.is_empty():
		var i := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		var allowed := _compat[domains[i]]
		var x := i % width
		var y := i / width
		for d in 4:
			var ny: int = y + DY[d]
			if ny < 0 or ny >= height:
				continue
			var nx: int = (x + DX[d] + width) % width
			var j := ny * width + nx
			var before := domains[j]
			var after := before & allowed
			if after != before:
				if after == 0:
					return false
				domains[j] = after
				changed.append(j)
				stack.append(j)
	return true


func _repair(i: int) -> void:
	repairs += 1
	if _rebuild(i, 3) or _rebuild(i, 8) or _rebuild(i, -1):
		return
	pins.fill(-1)
	_rebuild(i, -1)


func _rebuild(center: int, radius: int) -> bool:
	var cx := center % width
	var cy := center / width
	var stack := PackedInt32Array()
	for j in domains.size():
		if pins[j] >= 0:
			domains[j] = 1 << pins[j]
		elif in_region(j, cx, cy, radius):
			domains[j] = _all
			changed.append(j)
		elif _single[domains[j]] < 0:
			domains[j] = _all
		if domains[j] != _all:
			stack.append(j)
	return _propagate(stack)


func in_region(j: int, cx: int, cy: int, radius: int) -> bool:
	if radius < 0:
		return true
	var dx := absi(j % width - cx)
	dx = mini(dx, width - dx)
	var dy := j / width - cy
	return dx * dx + dy * dy <= radius * radius + radius
