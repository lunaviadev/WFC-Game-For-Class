extends Node2D

const WFCSolver := preload("res://scripts/wfc.gd")
const Synth := preload("res://scripts/synth.gd")

enum { DEEP, WATER, SAND, GRASS, FOREST, VILLAGE, HILL, MOUNTAIN, SNOW, LIGHTHOUSE }
enum State { PLAYING, WON, LOST }
const NAMES := ["Deep sea", "Shallows", "Sand", "Grass", "Forest", "Village", "Hills", "Mountain", "Snow", "Lighthouse"]
const COLORS := [
	Color("1b3a6b"), Color("2f6fa8"), Color("e3cf8f"), Color("7fb350"), Color("3f7a3a"),
	Color("c98a5a"), Color("9aa05a"), Color("7d7a80"), Color("e8edf5"), Color("e3cf8f"),
]
const LEVELS := [0, 1, 2, 3, 3, 3, 4, 5, 6, 2]
const WEIGHTS := [3.0, 3.0, 1.5, 4.0, 2.5, 0.35, 2.0, 1.4, 0.8, 0.001]
const ADJACENCY := [
	[WATER],
	[SAND],
	[GRASS, VILLAGE],
	[FOREST, VILLAGE, HILL],
	[HILL, VILLAGE],
	[],
	[MOUNTAIN],
	[SNOW],
	[],
	[SAND, WATER],
]
const WALK_COST := {SAND: 1, GRASS: 1, VILLAGE: 1, LIGHTHOUSE: 1, FOREST: 2, HILL: 2}
const DIRS := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]

const COLS := 48
const ROWS := 23
const CELL := 26
const ORIGIN := Vector2(16, 50)
const START_OIL := 60
const VILLAGE_OIL := 25
const START_ANCHORS := 3
const MOVE_DELAY := 0.14
const REVEAL_SPEED := 3
const PENTATONIC := [0, 2, 4, 7, 9]
const CHORD_ROOTS := [57, 53, 48, 55]
const FOG := Color(0.02, 0.03, 0.06)

var solver: WFCSolver
var synth: Synth
var seed_value := 0
var state := State.PLAYING
var player := Vector2i.ZERO
var player_draw := Vector2.ZERO
var goal := 0
var oil := START_OIL
var anchors := START_ANCHORS
var steps := 0
var time := 0.0
var move_timer := 0.0
var tick_cooldown := 0.0
var pad_timer := 0.0
var glow := PackedFloat32Array()
var seen := PackedByteArray()
var used_villages := {}
var anchor_cells := {}
var bad_cell := -1
var bad_time := 0.0
var demo_mode := false
var demo_visits := {}

var seed_box: SpinBox


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.035, 0.04, 0.07))
	solver = WFCSolver.new(COLS, ROWS, ADJACENCY, WEIGHTS, LEVELS)
	synth = Synth.new()
	add_child(synth)
	glow.resize(COLS * ROWS)
	seen.resize(COLS * ROWS)
	demo_mode = "--demo" in OS.get_cmdline_user_args()
	_build_ui()
	_new_world(7 if demo_mode else randi() % 100000)


func _new_world(new_seed: int) -> void:
	seed_value = new_seed
	seed_box.set_value_no_signal(new_seed)
	solver.reset(new_seed)
	glow.fill(0.0)
	seen.fill(0)
	used_villages.clear()
	anchor_cells.clear()
	demo_visits.clear()
	state = State.PLAYING
	oil = START_OIL
	anchors = START_ANCHORS
	steps = 0

	var rng := RandomNumberGenerator.new()
	rng.seed = new_seed
	var start := _find_cell(rng, 2.7, 3.3, -1, 0.0)
	goal = _find_cell(rng, 1.6, 2.4, start, COLS / 3.0)
	solver.pin(goal, LIGHTHOUSE)
	solver.pin(start, GRASS)
	player = Vector2i(start % COLS, start / COLS)
	player_draw = _cell_center(start)


func _find_cell(rng: RandomNumberGenerator, lo: float, hi: float, away: int, min_dist: float) -> int:
	for attempt in 4000:
		var i := rng.randi_range(0, COLS * ROWS - 1)
		var h := solver.guide_at(i)
		if h >= lo and h <= hi and (away < 0 or _dist(i, away) >= min_dist):
			return i
	return rng.randi_range(0, COLS * ROWS - 1)


func _process(delta: float) -> void:
	time += delta
	var view := _view_radius()
	if state == State.PLAYING:
		_mark_seen(view)
		_handle_movement(delta)
	else:
		seen.fill(1)

	var revealed := -1
	for k in (REVEAL_SPEED if state == State.PLAYING else 25):
		var i := solver.step(player.x, player.y, view if state == State.PLAYING else -1)
		if i < 0:
			break
		_light(solver.changed, 0.15)
		glow[i] = 0.8
		revealed = solver.tile_at(i)
	tick_cooldown -= delta
	if revealed >= 0 and tick_cooldown <= 0.0:
		synth.tick(_pitch(LEVELS[revealed] * 2, 72))
		tick_cooldown = 0.05

	pad_timer -= delta
	if pad_timer <= 0.0:
		pad_timer = 0.5
		_update_pad(view)

	var target := _cell_center(_index(player))
	if player_draw.distance_to(target) > CELL * 3:
		player_draw = target
	player_draw = player_draw.lerp(target, 1.0 - exp(-delta * 20.0))

	bad_time -= delta
	for i in glow.size():
		glow[i] = maxf(glow[i] - delta * 2.0, 0.0)
	queue_redraw()


func _view_radius() -> int:
	return clampi(2 + ceili(oil / 20.0), 2, 5)


func _mark_seen(view: int) -> void:
	for i in seen.size():
		if solver.in_region(i, player.x, player.y, view):
			seen[i] = 1


func _handle_movement(delta: float) -> void:
	move_timer -= delta
	if move_timer > 0.0:
		return
	var dir := Vector2i.ZERO
	if demo_mode:
		dir = _demo_direction()
	elif Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir = Vector2i.LEFT
	elif Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir = Vector2i.RIGHT
	elif Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir = Vector2i.UP
	elif Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir = Vector2i.DOWN
	if dir != Vector2i.ZERO:
		_try_move(dir)
		move_timer = MOVE_DELAY


func _try_move(dir: Vector2i) -> void:
	var target := _wrap(player + dir)
	if target.y < 0 or target.y >= ROWS:
		return
	var i := _index(target)
	var t := solver.tile_at(i)
	if t < 0 or not WALK_COST.has(t):
		return
	var old := _index(player)
	if not anchor_cells.has(old) and old != goal:
		solver.unlock(old)
	solver.lock(i)
	player = target
	steps += 1
	oil -= WALK_COST[t]
	_footstep(t, target.y)
	if t == VILLAGE and not used_villages.has(i):
		used_villages[i] = true
		oil += VILLAGE_OIL
		synth.bell(_pitch(7, 67), 0.12)
		synth.bell(_pitch(9, 67), 0.10)
	if t == LIGHTHOUSE:
		_end(State.WON)
	elif oil <= 0:
		_end(State.LOST)


func _end(result: State) -> void:
	state = result
	if result == State.WON:
		for degree in [5, 7, 9, 10]:
			synth.bell(_pitch(degree, 67), 0.1)
	else:
		synth.drum()
		synth.set_pad(_midi_to_freq(33), 0.06)


func _throw_anchor(i: int) -> void:
	if state != State.PLAYING or anchors <= 0 or i < 0 or i == goal or i == _index(player):
		return
	if solver.pin(i, GRASS):
		anchors -= 1
		anchor_cells[i] = true
		synth.drum()
		synth.bell(_pitch(2, 55), 0.12)
	else:
		bad_cell = i
		bad_time = 0.5
	_light(solver.changed, 0.5)


func _footstep(t: int, y: int) -> void:
	match t:
		GRASS:
			synth.pluck(_row_pitch(y, 60), 0.08)
		FOREST:
			synth.pluck(_row_pitch(y, 48), 0.12)
		SAND:
			synth.hat()
			synth.pluck(_row_pitch(y, 60), 0.05)
		HILL:
			synth.bell(_row_pitch(y, 55), 0.07)
		VILLAGE:
			synth.drum()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		get_viewport().gui_release_focus()
		_throw_anchor(_cell_at(get_local_mouse_position()))
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_new_world(randi() % 100000)


func _demo_direction() -> Vector2i:
	var here := _index(player)
	var best := Vector2i.ZERO
	var best_score := INF
	var toward := Vector2i.ZERO
	var toward_dist := INF
	for d: Vector2i in DIRS:
		var c := _wrap(player + d)
		if c.y < 0 or c.y >= ROWS:
			continue
		var i := _index(c)
		if _dist(i, goal) < toward_dist:
			toward_dist = _dist(i, goal)
			toward = c
		var t := solver.tile_at(i)
		if t < 0 or not WALK_COST.has(t):
			continue
		var score: float = _dist(i, goal) + demo_visits.get(i, 0) * 3.0
		if score < best_score:
			best_score = score
			best = d
	var toward_tile := solver.tile_at(_index(toward))
	if demo_visits.get(here, 0) >= 2 and anchors > 0 and (toward_tile == WATER or toward_tile == DEEP):
		_throw_anchor(_index(toward))
		return Vector2i.ZERO
	demo_visits[here] = demo_visits.get(here, 0) + 1
	return best


func _update_pad(view: int) -> void:
	if state != State.PLAYING:
		return
	var height_sum := 0.0
	var water := 0
	var known := 0
	for i in seen.size():
		var t := solver.tile_at(i)
		if t < 0 or not solver.in_region(i, player.x, player.y, view):
			continue
		known += 1
		height_sum += LEVELS[t]
		if t <= WATER:
			water += 1
	if known == 0:
		return
	var chord := clampi(int((height_sum / known - 1.2) / 0.7), 0, 3)
	synth.set_pad(_midi_to_freq(CHORD_ROOTS[chord] - 24), 0.03 + 0.08 * water / known)


func _row_pitch(y: int, base: int) -> float:
	return _pitch((ROWS - 1 - y) / 2, base)


func _pitch(degree: int, base: int) -> float:
	return _midi_to_freq(base + 12 * (degree / 5) + PENTATONIC[degree % 5])


func _midi_to_freq(midi: int) -> float:
	return 440.0 * pow(2.0, (midi - 69) / 12.0)


func _index(c: Vector2i) -> int:
	return c.y * COLS + c.x


func _wrap(c: Vector2i) -> Vector2i:
	return Vector2i(posmod(c.x, COLS), c.y)


func _dist(a: int, b: int) -> float:
	var dx := absi(a % COLS - b % COLS)
	dx = mini(dx, COLS - dx)
	return Vector2(dx, a / COLS - b / COLS).length()


func _cell_at(pos: Vector2) -> int:
	var c := Vector2i(((pos - ORIGIN) / CELL).floor())
	if c.x < 0 or c.y < 0 or c.x >= COLS or c.y >= ROWS:
		return -1
	return _index(c)


func _cell_rect(i: int) -> Rect2:
	return Rect2(ORIGIN + Vector2(i % COLS, i / COLS) * CELL, Vector2(CELL, CELL))


func _cell_center(i: int) -> Vector2:
	return _cell_rect(i).get_center()


func _light(cells: PackedInt32Array, amount: float) -> void:
	for c in cells:
		glow[c] = maxf(glow[c], amount)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bar := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.11)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	bar.add_theme_stylebox_override("panel", style)
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	layer.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	bar.add_child(row)

	var title := _label(row, "UNOBSERVED")
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("f2c46d"))
	var tagline := _label(row, "the world isn't decided until you look at it")
	tagline.add_theme_font_size_override("font_size", 14)
	tagline.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_label(row, "Seed")
	seed_box = SpinBox.new()
	seed_box.max_value = 99999
	seed_box.value_changed.connect(func(v: float) -> void: _new_world(int(v)))
	row.add_child(seed_box)

	var new_button := Button.new()
	new_button.text = "New world"
	new_button.focus_mode = Control.FOCUS_NONE
	new_button.pressed.connect(func() -> void: _new_world(randi() % 100000))
	row.add_child(new_button)


func _label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(label)
	return label


func _draw() -> void:
	var view := _view_radius()
	var here := _index(player)
	for i in COLS * ROWS:
		var r := _cell_rect(i)
		var t := solver.tile_at(i)
		if seen[i] and t >= 0:
			_draw_tile(r, t, i)
			if state == State.PLAYING:
				var d := _dist(i, here)
				var shade := 0.62 if d > view else clampf(d / view - 0.55, 0.0, 1.0) * 0.6
				draw_rect(r, Color(FOG, shade))
		else:
			_draw_superposition(r, solver.domains[i])
		if glow[i] > 0.01:
			draw_rect(r, Color(1, 1, 1, glow[i] * 0.4))
		if anchor_cells.has(i):
			draw_rect(r.grow(-3), Color(1, 1, 1, 0.8), false, 1.5)

	if seen[goal] and solver.tile_at(goal) == LIGHTHOUSE:
		var top := _cell_rect(goal).position + Vector2(13, 5)
		var a := time * 1.6
		_tri(top, top + Vector2.from_angle(a - 0.1) * 320.0, top + Vector2.from_angle(a + 0.1) * 320.0, Color(1, 0.9, 0.5, 0.16))

	if state == State.PLAYING:
		draw_circle(player_draw, view * CELL, Color(1, 0.8, 0.45, 0.05))
		draw_circle(player_draw, CELL * 1.4, Color(1, 0.8, 0.45, 0.08))
		draw_circle(player_draw, 7.0, Color("2a2238"))
		draw_circle(player_draw + Vector2(5, -4), 3.5 + sin(time * 9.0) * 0.4, Color("ffcc66"))
		var hover := _cell_at(get_local_mouse_position())
		if hover >= 0 and anchors > 0 and not demo_mode:
			draw_rect(_cell_rect(hover).grow(1), Color(1, 1, 1, 0.5), false, 2.0)
	if bad_time > 0.0 and bad_cell >= 0:
		draw_rect(_cell_rect(bad_cell), Color(1, 0.2, 0.2, bad_time))

	if state != State.PLAYING:
		_draw_banner()
	_draw_footer()


func _draw_superposition(r: Rect2, mask: int) -> void:
	draw_rect(r.grow(-1), Color(0.08, 0.09, 0.14))
	var options := 0
	for t in NAMES.size():
		if mask & (1 << t):
			options += 1
	var alpha := 0.15 + 0.65 * (1.0 - options / float(NAMES.size()))
	var s := (CELL - 6) / 3.0
	for t in 9:
		if mask & (1 << t):
			var c: Color = COLORS[t]
			c.a = alpha
			draw_rect(Rect2(r.position + Vector2(3 + (t % 3) * s, 3 + (t / 3) * s), Vector2(s - 1, s - 1)), c)


func _draw_tile(r: Rect2, t: int, i: int) -> void:
	var h := _hash(i)
	var base: Color = COLORS[t]
	draw_rect(r, base.darkened(h * 0.12))
	var p := r.position
	var dark := base.darkened(0.35)
	match t:
		DEEP, WATER:
			if h < 0.4:
				var wx := 3.0 + fposmod(time * 3.0 + h * 60.0, CELL - 14.0)
				var wy := 8.0 + h * 25.0
				draw_polyline(PackedVector2Array([
					p + Vector2(wx, wy), p + Vector2(wx + 3, wy - 2),
					p + Vector2(wx + 6, wy), p + Vector2(wx + 9, wy - 2),
				]), base.lightened(0.25), 1.5)
		SAND:
			draw_circle(p + Vector2(6 + h * 12, 8 + h * 8), 1.2, dark)
			draw_circle(p + Vector2(18 - h * 6, 18), 1.2, dark)
		GRASS:
			if h > 0.7:
				draw_line(p + Vector2(10, 18), p + Vector2(12, 12), dark, 1.5)
				draw_line(p + Vector2(14, 18), p + Vector2(12, 12), dark, 1.5)
		FOREST:
			_tree(p + Vector2(8, 19), 6.0)
			_tree(p + Vector2(17, 15 + h * 4), 7.0)
		VILLAGE:
			draw_rect(Rect2(p + Vector2(6, 12), Vector2(14, 9)), Color("f1e3c6"))
			_tri(p + Vector2(4, 12), p + Vector2(13, 5), p + Vector2(22, 12), Color("a8432f"))
			var lit := not used_villages.has(i)
			draw_rect(Rect2(p + Vector2(11, 15), Vector2(4, 4)), Color("ffd36b") if lit else Color("4a3a2a"))
		HILL:
			draw_arc(p + Vector2(13, 20), 8.0, PI, TAU, 10, dark, 2.0)
		MOUNTAIN:
			_tri(p + Vector2(3, 22), p + Vector2(13, 4), p + Vector2(23, 22), Color("5d5a62"))
			_tri(p + Vector2(13, 4), p + Vector2(23, 22), p + Vector2(15, 22), Color("4a474e"))
		SNOW:
			_tri(p + Vector2(3, 22), p + Vector2(13, 4), p + Vector2(23, 22), Color("aab4c4"))
			_tri(p + Vector2(9, 11), p + Vector2(13, 4), p + Vector2(17, 11), Color.WHITE)
		LIGHTHOUSE:
			draw_rect(Rect2(p + Vector2(10, 7), Vector2(6, 16)), Color.WHITE)
			draw_rect(Rect2(p + Vector2(10, 11), Vector2(6, 3)), Color("c0392b"))
			draw_rect(Rect2(p + Vector2(10, 17), Vector2(6, 3)), Color("c0392b"))
			draw_circle(p + Vector2(13, 5), 3.0, Color("ffd36b"))


func _tree(foot: Vector2, size: float) -> void:
	_tri(foot + Vector2(-size * 0.7, 0), foot + Vector2(0, -size * 1.6), foot + Vector2(size * 0.7, 0), Color("234d24"))


func _tri(a: Vector2, b: Vector2, c: Vector2, color: Color) -> void:
	draw_colored_polygon(PackedVector2Array([a, b, c]), color)


func _hash(i: int) -> float:
	return fposmod(sin(i * 12.9898 + seed_value * 78.233) * 43758.5453, 1.0)


func _draw_banner() -> void:
	var font := ThemeDB.fallback_font
	var width := COLS * CELL
	var y := ORIGIN.y + ROWS * CELL * 0.5
	draw_rect(Rect2(ORIGIN.x, y - 50, width, 84), Color(FOG, 0.8))
	var won := state == State.WON
	var title := "YOU FOUND THE LIGHTHOUSE" if won else "YOUR LANTERN WENT OUT"
	var sub := ("%d steps, %d oil to spare." % [steps, oil]) if won \
			else ("The lighthouse was %d tiles away." % roundi(_dist(_index(player), goal)))
	draw_string(font, Vector2(ORIGIN.x, y - 6), title, HORIZONTAL_ALIGNMENT_CENTER, width, 32,
			Color("f2c46d") if won else Color("e07a6a"))
	draw_string(font, Vector2(ORIGIN.x, y + 22), sub + "   Press R for a new world.", HORIZONTAL_ALIGNMENT_CENTER, width, 16, Color(1, 1, 1, 0.8))


func _draw_footer() -> void:
	var font := ThemeDB.fallback_font
	var y := ORIGIN.y + ROWS * CELL + 26
	var x := ORIGIN.x
	for t in NAMES.size():
		var swatch := Rect2(x, y - 12, 14, 14)
		draw_rect(swatch, COLORS[t])
		draw_string(font, Vector2(x + 20, y), NAMES[t], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.5))
		x += 34 + font.get_string_size(NAMES[t], HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x

	var right := ORIGIN.x + COLS * CELL
	var gauge := Rect2(right - 150, y - 11, 150, 12)
	draw_rect(gauge, Color(1, 1, 1, 0.1))
	draw_rect(Rect2(gauge.position, Vector2(gauge.size.x * clampf(oil / float(START_OIL), 0.0, 1.0), gauge.size.y)),
			Color("ffcc66") if oil > 15 else Color("e07a6a"))
	draw_string(font, Vector2(right - 260, y), "Lantern oil %d" % maxi(oil, 0), HORIZONTAL_ALIGNMENT_RIGHT, 100, 14, Color(1, 1, 1, 0.7))

	var hints := "WASD / arrows: walk   Click: throw an anchor (forces land)   Villages refill oil   R: new world"
	draw_string(font, Vector2(ORIGIN.x, y + 24), hints, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.38))
	var status := "anchors %d    steps %d    seed %d" % [anchors, steps, seed_value]
	draw_string(font, Vector2(ORIGIN.x, y + 24), status, HORIZONTAL_ALIGNMENT_RIGHT, COLS * CELL, 13, Color(1, 1, 1, 0.6))
