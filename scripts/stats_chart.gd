# Grafica de progreso de un jugador en un nivel, dibujada a mano.
#
# Eje X: numero de intento. Eje Y: tiempo de los intentos completados (mas
# abajo = mas rapido). Cada intento completado es un punto del color de su
# medalla; los fallidos (sin vidas, sin tiempo, abandonados) son marcas rojas
# en una franja bajo el eje, porque su tiempo no es comparable. La escalera
# cian es el record personal de cada momento; la linea dorada, el tiempo para
# el oro; la linea blanca, el record con el que se compara (opcional).
#
# Pasar el raton muestra el detalle del intento mas cercano.
extends Control

const DB := preload("res://scripts/leaderboard_db.gd")

const PAD_LEFT := 64.0
const PAD_RIGHT := 18.0
const PAD_TOP := 16.0
const PAD_BOTTOM := 52.0
## Alto de la franja de intentos fallidos, bajo el eje X.
const FAIL_LANE := 16.0

const GRID := Color(1, 1, 1, 0.08)
const AXIS := Color(1, 1, 1, 0.25)
const MUTED := Color(1, 1, 1, 0.55)
const TEXT := Color(1, 1, 1, 0.92)
const BEST_LINE := Color(0.6, 0.92, 1, 1)
const PAR_LINE := Color(1, 0.8, 0.26, 0.9)
const COMPARE_LINE := Color(1, 1, 1, 0.75)
const FAIL_MARK := Color(1, 0.42, 0.38, 0.9)
const SURFACE := Color(0.09, 0.13, 0.29, 1)
const MEDAL_COLORS := {
	"Oro": Color(1, 0.8, 0.26, 1),
	"Plata": Color(0.8, 0.86, 0.94, 1),
	"Bronce": Color(0.9, 0.58, 0.32, 1),
}
const RESULT_TEXT := {"completado": "Completado", "sin_vidas": "Sin vidas", "sin_tiempo": "Sin tiempo", "abandonado": "Abandonado"}

var _series: Array = []
var _par_ms := 0
var _compare_ms := 0
var _compare_label := ""
var _hover := -1
var _y_min := 0.0
var _y_max := 1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(func() -> void:
		_hover = -1
		queue_redraw())


## series: intentos en orden ({numero, resultado, tiempo_ms, estrellas, caidas,
## medalla}). compare_ms 0 = sin linea de comparacion.
func set_data(series: Array, par_ms: int, compare_ms: int = 0, compare_label: String = "") -> void:
	_series = series
	_par_ms = par_ms
	_compare_ms = compare_ms
	_compare_label = compare_label
	_hover = -1
	var times: Array = []
	for a in _series:
		if str(a["resultado"]) == "completado":
			times.append(float(a["tiempo_ms"]))
	for extra in [_par_ms, _compare_ms]:
		if extra > 0:
			times.append(float(extra))
	if times.is_empty():
		_y_min = 0.0
		_y_max = 60000.0
	else:
		var lo: float = times.min()
		var hi: float = times.max()
		var pad := maxf((hi - lo) * 0.15, 2000.0)
		_y_min = maxf(0.0, lo - pad)
		_y_max = hi + pad
	queue_redraw()


func _plot_rect() -> Rect2:
	return Rect2(PAD_LEFT, PAD_TOP, size.x - PAD_LEFT - PAD_RIGHT, size.y - PAD_TOP - PAD_BOTTOM)


func _x_of(index: int) -> float:
	var r := _plot_rect()
	if _series.size() <= 1:
		return r.position.x + r.size.x * 0.5
	return r.position.x + r.size.x * float(index) / float(_series.size() - 1)


func _y_of(ms: float) -> float:
	var r := _plot_rect()
	var t := (ms - _y_min) / maxf(_y_max - _y_min, 1.0)
	return r.end.y - r.size.y * t


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and not _series.is_empty():
		# El intento mas cercano en X: no hace falta apuntar al punto exacto.
		var best := -1
		var best_dist := INF
		for i in _series.size():
			var d := absf(_x_of(i) - event.position.x)
			if d < best_dist:
				best_dist = d
				best = i
		if best != _hover:
			_hover = best
			queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var r := _plot_rect()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.18))
	if _series.is_empty():
		_text(font, "Sin intentos en este nivel todavia", size * 0.5, 18, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		return

	# Rejilla y eje Y con tiempos redondos.
	var step := _nice_step((_y_max - _y_min) / 4.0)
	var tick := ceilf(_y_min / step) * step
	while tick <= _y_max:
		var y := _y_of(tick)
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), GRID, 1.0)
		_text(font, _short_time(int(tick)), Vector2(r.position.x - 8, y + 5), 13, MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
		tick += step
	draw_line(Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.end.y), AXIS, 1.0)
	_text(font, "mas abajo = mas rapido", Vector2(r.position.x + 4, r.position.y + 12), 12, MUTED)

	# Eje X: numeros de intento, sin amontonarse.
	var every := maxi(1, ceili(_series.size() / 12.0))
	for i in _series.size():
		if i % every == 0 or i == _series.size() - 1:
			_text(font, "#%d" % int(_series[i]["numero"]), Vector2(_x_of(i), size.y - 8), 12, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	var lane_y := r.end.y + 6.0 + FAIL_LANE * 0.5

	# Referencias: oro y record comparado.
	if _par_ms > 0:
		_ref_line(font, _par_ms, PAR_LINE, "Oro %s" % _short_time(_par_ms))
	if _compare_ms > 0:
		_ref_line(font, _compare_ms, COMPARE_LINE, _compare_label)

	# Escalera del record personal.
	var best := INF
	var last := Vector2.ZERO
	for i in _series.size():
		var a: Dictionary = _series[i]
		if str(a["resultado"]) != "completado":
			continue
		var t := float(a["tiempo_ms"])
		var x := _x_of(i)
		if t < best:
			if best < INF:
				draw_line(last, Vector2(x, last.y), BEST_LINE, 2.0)
				draw_line(Vector2(x, last.y), Vector2(x, _y_of(t)), BEST_LINE, 2.0)
			best = t
			last = Vector2(x, _y_of(t))
	if best < INF:
		draw_line(last, Vector2(r.end.x, last.y), BEST_LINE, 2.0)

	# Crosshair del intento bajo el raton.
	if _hover >= 0:
		var hx := _x_of(_hover)
		draw_line(Vector2(hx, r.position.y), Vector2(hx, lane_y + FAIL_LANE * 0.5), Color(1, 1, 1, 0.3), 1.0)

	# Puntos: completados por medalla, fallidos en la franja inferior.
	for i in _series.size():
		var a: Dictionary = _series[i]
		var x := _x_of(i)
		var hovered := i == _hover
		if str(a["resultado"]) == "completado":
			var medal: Variant = a.get("medalla")
			var color: Color = MEDAL_COLORS.get(str(medal), TEXT)
			var p := Vector2(x, _y_of(float(a["tiempo_ms"])))
			draw_circle(p, 7.0 if hovered else 5.5, SURFACE)
			draw_circle(p, 5.5 if hovered else 4.0, color)
		else:
			var h := FAIL_LANE * (0.5 if hovered else 0.35)
			draw_line(Vector2(x, lane_y - h), Vector2(x, lane_y + h), FAIL_MARK, 3.0 if hovered else 2.0)

	if _hover >= 0:
		_tooltip(font, _series[_hover], _x_of(_hover))


func _ref_line(font: Font, ms: int, color: Color, label: String) -> void:
	var r := _plot_rect()
	var y := _y_of(ms)
	draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), color, 1.0)
	_text(font, label, Vector2(r.end.x - 4, y - 5), 13, color, HORIZONTAL_ALIGNMENT_RIGHT)


func _tooltip(font: Font, a: Dictionary, x: float) -> void:
	var res := str(a["resultado"])
	var lines := [
		"Intento #%d  -  %s" % [int(a["numero"]), RESULT_TEXT.get(res, res)],
		"%s%s" % [DB.format_time(int(a["tiempo_ms"])), ("  -  " + str(a["medalla"])) if a.get("medalla") != null else ""],
		"Estrellas %d  -  Caidas %d" % [int(a["estrellas"]), int(a["caidas"])],
	]
	var width := 0.0
	for line in lines:
		width = maxf(width, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x)
	var box := Rect2(0, 0, width + 20, 70)
	box.position = Vector2(clampf(x + 12, 0, size.x - box.size.x), PAD_TOP + 4)
	if x + 12 + box.size.x > size.x:
		box.position.x = maxf(0, x - 12 - box.size.x)
	draw_rect(box, Color(0.05, 0.07, 0.16, 0.96))
	draw_rect(box, Color(1, 1, 1, 0.2), false, 1.0)
	for i in lines.size():
		_text(font, lines[i], box.position + Vector2(10, 20 + i * 20), 14 if i > 0 else 15, TEXT if i == 1 else MUTED)


func _text(font: Font, text: String, pos: Vector2, font_size: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := pos.x
	if align == HORIZONTAL_ALIGNMENT_CENTER:
		x -= w * 0.5
	elif align == HORIZONTAL_ALIGNMENT_RIGHT:
		x -= w
	draw_string(font, Vector2(x, pos.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


# 45000 -> "0:45", 61500 -> "1:01.5"
static func _short_time(ms: int) -> String:
	var s := ms / 1000.0
	var minutes := int(s) / 60
	var rest := s - minutes * 60
	if absf(rest - roundf(rest)) < 0.05:
		return "%d:%02d" % [minutes, roundi(rest)]
	return "%d:%04.1f" % [minutes, rest]


# Paso "redondo" de la rejilla: 1, 2, 5, 10, 15, 30 s...
static func _nice_step(raw_ms: float) -> float:
	for step in [500.0, 1000.0, 2000.0, 5000.0, 10000.0, 15000.0, 30000.0, 60000.0, 120000.0]:
		if raw_ms <= step:
			return step
	return 300000.0
