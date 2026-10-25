# Interfaz de progreso: nivel, contador de estrellas, gema, vidas, tiempo,
# mensajes y el rotulo grande de celebracion. Tambien la pantalla de inicio
# (con el nickname y un resumen de records), la tabla de records completa (con
# vista "cerca de mi", divisiones por medalla o liga y franja de objetivo), la
# pantalla de estadisticas de cada jugador (con grafica de sus intentos), el
# boton de pausa y el menu de pausa: solo emiten senales, la logica y las
# consultas a la base de datos viven en main.gd.
extends CanvasLayer

signal start_pressed
signal level_selected(index: int)
signal quit_pressed
signal pause_pressed
signal resume_pressed
signal restart_pressed
signal menu_pressed
signal next_pressed
## Pide filas para la tabla. target: "preview" (pantalla de inicio) o "full".
## tab: "1".."5" (nivel), "general" o "historial". view: "top" (desde el
## primero) o "cerca" (el jugador en el centro con sus rivales cercanos).
signal board_query(target: String, tab: String, sort_by: String, filter: String, view: String)
## Se pidieron las estadisticas de un jugador: main.gd responde con show_profile().
signal profile_requested(nickname: String)

const BANNER_FONT_SIZE := 64
const HeartScript := preload("res://scripts/heart.gd")
const HEART_SIZE := Vector2(32, 30)
const DB := preload("res://scripts/leaderboard_db.gd")
const StatsChart := preload("res://scripts/stats_chart.gd")

const GOLD_TEXT := Color(1, 0.94, 0.55, 1)
const ME_TEXT := Color(0.6, 0.92, 1, 1)
const DIM_TEXT := Color(1, 1, 1, 0.7)
const RESULT_TEXT := {"completado": "Completado", "sin_vidas": "Sin vidas", "sin_tiempo": "Sin tiempo", "abandonado": "Abandonado"}
const TRIAL_CARD_COLOR := Color(0.55, 0.16, 0.12, 0.95)
const TRIAL_CARD_EDGE := Color(1, 0.55, 0.25, 1)
const COUNTDOWN_CALM := Color(1, 1, 1, 1)
const COUNTDOWN_WARN := Color(1, 0.72, 0.25, 1)
const COUNTDOWN_PANIC := Color(1, 0.3, 0.25, 1)
const VIEWS := [["top", "Top"], ["cerca", "Cerca de mi"]]

# Jerarquia de la tabla: puesto, nombre y metrica principal grandes y claros;
# el resto pequeno y apagado.
const PRIMARY_SIZE := 22
const SECONDARY_SIZE := 15
const SECONDARY_TEXT := Color(1, 1, 1, 0.6)
const ROW_HEIGHT := 42
## Color de cada medalla y liga.
const TIER_COLORS := {
	"Diamante": Color(0.55, 0.95, 1, 1),
	"Oro": Color(1, 0.8, 0.26, 1),
	"Plata": Color(0.8, 0.86, 0.94, 1),
	"Bronce": Color(0.9, 0.58, 0.32, 1),
	"Sin liga": Color(1, 1, 1, 0.35),
}
const PODIUM_COLORS := [Color(1, 0.8, 0.26, 1), Color(0.8, 0.86, 0.94, 1), Color(0.9, 0.58, 0.32, 1)]
# Columnas de cada tabla: [titulo, ancho (0 = ocupa el resto), principal].
const LEVEL_COLUMNS := [["#", 60, true], ["Jugador", 0, true], ["Tiempo", 120, true], ["Medalla", 100, true],
	["Estrellas", 86, false], ["Gema", 52, false], ["Caidas", 64, false], ["Intentos", 80, false], ["Fecha", 96, false]]
const GENERAL_COLUMNS := [["#", 60, true], ["Jugador", 0, true], ["Liga", 112, true], ["Niveles", 84, true],
	["Estrellas", 84, false], ["Gemas", 64, false], ["Suma tiempos", 116, false], ["Intentos", 76, false], ["Caidas", 64, false]]
const HISTORY_COLUMNS := [["Nivel", 0, true], ["Intento", 76, false], ["Resultado", 126, true], ["Tiempo", 106, true],
	["Estrellas", 86, false], ["Gema", 52, false], ["Corazones", 92, false], ["Caidas", 64, false], ["Fecha", 146, false]]

@onready var _level_label: Label = $Root/TopPill/TopBar/LevelLabel
@onready var _star_label: Label = $Root/TopPill/TopBar/Stars/StarLabel
@onready var _star_icon: Control = $Root/TopPill/TopBar/Stars/StarIcon
@onready var _hearts: HBoxContainer = $Root/TopPill/TopBar/Hearts
@onready var _message: Label = $Root/Message
@onready var _hint: Label = $Root/Hint
@onready var _dim: ColorRect = $Root/Dim
@onready var _pause_panel: Panel = $Root/PausePanel
@onready var _pause_button: Button = $Root/PauseButton
@onready var _resume_button: Button = $Root/PausePanel/Box/ResumeButton
@onready var _start_screen: Control = $Root/StartScreen
@onready var _title: Label = $Root/StartScreen/Columns/Box/Title
@onready var _start_button: Button = $Root/StartScreen/Columns/Box/StartButton
@onready var _level_buttons: HBoxContainer = $Root/StartScreen/Columns/Box/LevelButtons
@onready var _nick_edit: LineEdit = $Root/StartScreen/Columns/Box/NickRow/NickEdit
@onready var _nick_error: Label = $Root/StartScreen/Columns/Box/NickError
@onready var _preview_tabs: HBoxContainer = $Root/StartScreen/Columns/BoardPreview/Box/Tabs
@onready var _preview_rows: GridContainer = $Root/StartScreen/Columns/BoardPreview/Box/Rows
@onready var _welcome: Label = $Root/StartScreen/Columns/BoardPreview/Box/Welcome
@onready var _gem_icon: Control = $Root/TopPill/TopBar/Gems/GemIcon
@onready var _time_label: Label = $Root/TopPill/TopBar/TimeLabel
@onready var _power_label: Label = $Root/PowerLabel
@onready var _win_panel: Panel = $Root/WinPanel
@onready var _win_text: Label = $Root/WinPanel/Box/WinText
@onready var _next_button: Button = $Root/WinPanel/Box/NextButton

var _message_tween: Tween = null
var _banner_tween: Tween = null
var _star_tween: Tween = null
var _banner: Label = null
var _lives_shown := -1
var _title_tween: Tween = null
# Tween de escala de cada boton, para cortar el anterior al cambiar de estado.
var _button_tweens := {}
var _lives_card: PanelContainer = null
var _lives_card_hearts: HBoxContainer = null
var _lives_card_text: Label = null
var _lives_card_tween: Tween = null
var _water_overlay: ColorRect = null
var _water_tween: Tween = null
var _preview_tab := "1"
# Tabla completa, construida en codigo.
var _board_panel: Panel = null
var _board_header: HBoxContainer = null
var _board_list: VBoxContainer = null
var _board_scroll: ScrollContainer = null
var _board_filter: LineEdit = null
var _board_path: Label = null
var _board_goal: PanelContainer = null
var _board_goal_text: Label = null
var _board_goal_bar: ProgressBar = null
var _board_play: Button = null
var _board_tab_buttons := {}
var _board_sort_buttons := {}
var _board_view_buttons := {}
var _board_tab := "1"
var _board_sort := "tiempo"
var _board_view := "top"
var _me := ""
# Pantalla de estadisticas de un jugador, encima de la tabla o del menu.
var _stats_panel: Panel = null
var _stats_box: VBoxContainer = null
var _stats_data: Dictionary = {}
var _stats_level := 1
## Linea de comparacion de la grafica: "lider", "tu" o "nada".
var _stats_compare := "lider"
# Pestanas de nivel: [id, corto, largo]. main.gd las fija con set_level_tabs.
var _level_tabs: Array = [["1", "N1", "Nivel 1"], ["2", "N2", "Nivel 2"], ["3", "N3", "Nivel 3"]]
var _level_total := 3
var _gem_levels := 3
var _full_tabs_box: HBoxContainer = null
var _trial_label: Label = null
var _trial_buttons: HBoxContainer = null
# Contrarreloj.
var _countdown: Label = null
var _countdown_tween: Tween = null
var _countdown_second := -1
var _vignette: TextureRect = null
var _flash: ColorRect = null
var _damage_flash: ColorRect = null
var _damage_tween: Tween = null
var _trial_mode := false


# El rotulo de celebracion se crea en codigo para no tocar la escena.
func _ready() -> void:
	# Los botones tienen que responder con el arbol en pausa.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_start_button.pressed.connect(start_pressed.emit)
	$Root/StartScreen/Columns/Box/QuitButton.pressed.connect(quit_pressed.emit)
	$Root/StartScreen/Columns/BoardPreview/Box/FullBoardButton.pressed.connect(open_board)
	_nick_edit.text_submitted.connect(func(_t: String) -> void: start_pressed.emit())
	_nick_edit.text_changed.connect(func(_t: String) -> void: _nick_error.text = "")
	_style_line_edit(_nick_edit)
	_pause_button.pressed.connect(pause_pressed.emit)
	_resume_button.pressed.connect(resume_pressed.emit)
	$Root/PausePanel/Box/RestartButton.pressed.connect(restart_pressed.emit)
	$Root/PausePanel/Box/MenuButton.pressed.connect(menu_pressed.emit)
	_next_button.pressed.connect(next_pressed.emit)
	$Root/WinPanel/Box/WinMenuButton.pressed.connect(menu_pressed.emit)

	for button in find_children("*", "Button", true, false):
		_add_button_juice(button)

	var root := get_node_or_null("Root")
	if root == null:
		return

	_banner = Label.new()
	_banner.name = "Banner"
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_banner.anchor_left = 0.0
	_banner.anchor_right = 1.0
	_banner.anchor_top = 0.0
	_banner.anchor_bottom = 0.0
	_banner.offset_left = 0.0
	_banner.offset_right = 0.0
	_banner.offset_top = 120.0
	_banner.offset_bottom = 230.0
	_banner.add_theme_font_size_override("font_size", BANNER_FONT_SIZE)
	_banner.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_banner.add_theme_color_override("font_outline_color", Color(0.06, 0.1, 0.2, 1))
	_banner.add_theme_constant_override("outline_size", 10)
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.modulate.a = 0.0
	_banner.visible = false
	root.add_child(_banner)

	_build_water_overlay(root)
	_build_hurry_fx(root)
	_build_lives_card(root)
	_build_trial_row()
	# En la web no hay ventana que cerrar.
	if OS.has_feature("web"):
		$Root/StartScreen/Columns/Box/QuitButton.visible = false
	_build_preview_tabs()
	_build_board(root)

	# Desde la victoria tambien se puede consultar la tabla.
	var win_board := Button.new()
	win_board.name = "WinBoardButton"
	win_board.text = "Ver records"
	win_board.custom_minimum_size = Vector2(0, 44)
	win_board.theme_type_variation = &"SecondaryButton"
	win_board.add_theme_font_size_override("font_size", 22)
	win_board.pressed.connect(open_board)
	_add_button_juice(win_board)
	var win_box := $Root/WinPanel/Box
	win_box.add_child(win_board)
	win_box.move_child(win_board, $Root/WinPanel/Box/WinMenuButton.get_index())

	# Acceso directo a las estadisticas propias desde la pantalla de inicio.
	var my_stats := Button.new()
	my_stats.name = "MyStatsButton"
	my_stats.text = "Mis estadisticas"
	my_stats.custom_minimum_size = Vector2(0, 40)
	my_stats.theme_type_variation = &"SecondaryButton"
	my_stats.add_theme_font_size_override("font_size", 18)
	my_stats.pressed.connect(open_my_stats)
	_add_button_juice(my_stats)
	$Root/StartScreen/Columns/BoardPreview/Box.add_child(my_stats)


# Escape cierra las estadisticas y la tabla antes que cualquier otra cosa.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if is_stats_open():
		close_stats()
		get_viewport().set_input_as_handled()
	elif is_board_open():
		close_board()
		get_viewport().set_input_as_handled()


func set_level(current: int, total: int, level_name: String, prefix: String = "Nivel") -> void:
	_level_label.text = "%s %d/%d  -  %s" % [prefix, current, total, level_name]


func set_stars(collected: int, total: int) -> void:
	_star_label.text = "%d / %d" % [collected, total]


# Un corazon por vida: llenos los que quedan, apagados los perdidos.
func set_lives(lives: int, max_lives: int) -> void:
	while _hearts.get_child_count() < max_lives:
		var heart := HeartScript.new()
		heart.custom_minimum_size = HEART_SIZE
		heart.pivot_offset = HEART_SIZE * 0.5
		_hearts.add_child(heart)
	while _hearts.get_child_count() > max_lives:
		var extra := _hearts.get_child(_hearts.get_child_count() - 1)
		_hearts.remove_child(extra)
		extra.queue_free()
	for i in max_lives:
		_hearts.get_child(i).filled = i < lives
	# El corazon que se acaba de perder da un latido y el HUD muestra impacto de dano.
	if _lives_shown > lives and lives >= 0 and lives < max_lives:
		var lost: Control = _hearts.get_child(lives)
		lost.scale = Vector2(1.65, 1.65)
		var tween := create_tween()
		tween.tween_property(lost, "scale", Vector2.ONE, 0.35) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		show_damage_flash(0.45)
		_shake_hearts()
	_lives_shown = lives


func _shake_hearts() -> void:
	if _hearts == null:
		return
	var orig := _hearts.position
	var tween := create_tween()
	for offset in [Vector2(-8, 3), Vector2(7, -3), Vector2(-5, 1), Vector2(4, -1), Vector2.ZERO]:
		tween.tween_property(_hearts, "position", orig + offset, 0.035)


func show_message(text: String, hold: float = 1.6) -> void:
	_message.text = text
	_message.modulate.a = 1.0
	if _message_tween != null and _message_tween.is_valid():
		_message_tween.kill()
	_message_tween = create_tween()
	_message_tween.tween_interval(hold)
	_message_tween.tween_property(_message, "modulate:a", 0.0, 0.5)


# Rotulo grande y centrado: entra, se mantiene y se desvanece.
func show_banner(text: String, hold: float = 2.5) -> void:
	if _banner == null:
		return
	_banner.text = text
	_banner.visible = true
	_banner.modulate.a = 0.0
	_banner.pivot_offset = _banner.size * 0.5
	_banner.scale = Vector2(0.5, 0.5)
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	# Entra creciendo con un rebote y sale subiendo y desvaneciendose.
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.2)
	_banner_tween.parallel().tween_property(_banner, "scale", Vector2.ONE, 0.45) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.tween_interval(hold)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, 0.5)
	_banner_tween.parallel().tween_property(_banner, "scale", Vector2(1.15, 1.15), 0.5) \
		.set_ease(Tween.EASE_IN)
	_banner_tween.tween_callback(_hide_banner)


func _hide_banner() -> void:
	if _banner != null:
		_banner.visible = false


# Salto del contador cada vez que se recoge una estrella.
func pulse_stars() -> void:
	if _star_tween != null and _star_tween.is_valid():
		_star_tween.kill()
	_star_label.pivot_offset = Vector2(_star_label.size.x * 0.5, _star_label.size.y * 0.5)
	_star_label.scale = Vector2(1.4, 1.4)
	_star_label.modulate = Color(1.5, 1.35, 0.6)
	# La estrella del icono da una vuelta rapida mientras el numero salta.
	_star_icon.pivot_offset = _star_icon.size * 0.5
	_star_icon.scale = Vector2(1.45, 1.45)
	_star_icon.rotation = -0.6
	_star_tween = create_tween().set_parallel()
	_star_tween.tween_property(_star_label, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_star_tween.tween_property(_star_label, "modulate", Color(1, 1, 1), 0.28)
	_star_tween.tween_property(_star_icon, "scale", Vector2.ONE, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_star_tween.tween_property(_star_icon, "rotation", 0.0, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func set_hint(text: String) -> void:
	_hint.text = text


# Panel de felicitaciones al llegar a la meta. En el ultimo nivel el boton
# principal pasa a ser "Jugar de nuevo".
func show_win(title: String, text: String, next_label: String) -> void:
	$Root/WinPanel/Box/WinTitle.text = title
	_win_text.text = text
	_next_button.text = next_label
	_win_panel.visible = true
	_pause_button.visible = false
	_hide_lives_card()
	_show_dim(true)
	_pop_in(_win_panel)
	_next_button.grab_focus()


func hide_win() -> void:
	_win_panel.visible = false
	_show_dim(_pause_panel.visible)


func set_paused(paused: bool) -> void:
	_pause_panel.visible = paused
	_pause_button.visible = not paused and not _start_screen.visible and not _win_panel.visible
	_show_dim(paused or _win_panel.visible)
	if paused:
		_pop_in(_pause_panel)
		_resume_button.grab_focus()


# Un boton por nivel en la pantalla de inicio. Cada elemento de `choices`
# es un diccionario con "name", "difficulty", "best" (-1 si nunca se termino)
# y "total" (estrellas del nivel).
func set_level_choices(choices: Array) -> void:
	for key in _button_tweens.keys():
		if not is_instance_valid(key):
			_button_tweens.erase(key)
	_clear_grid(_level_buttons)
	_clear_grid(_trial_buttons)
	for i in choices.size():
		var choice: Dictionary = choices[i]
		var button := Button.new()
		button.add_theme_constant_override("line_spacing", -2)
		button.custom_minimum_size = Vector2(196, 116)
		button.theme_type_variation = &"LevelCard"
		button.add_theme_font_size_override("font_size", 20)
		button.text = "%d. %s\n%s\n%s" % [i + 1, choice.get("name", "Nivel %d" % (i + 1)), choice.get("difficulty", ""), choice.get("record", "Sin completar")]
		button.pressed.connect(level_selected.emit.bind(i))
		_add_button_juice(button)
		if choice.get("trial", false):
			_style_trial_card(button)
			_trial_buttons.add_child(button)
		else:
			_level_buttons.add_child(button)
	_trial_label.visible = _trial_buttons.get_child_count() > 0


# La pantalla de inicio tapa el HUD de juego; el boton de pausa no tiene
# sentido mientras esta visible.
func set_start_screen(visible_now: bool) -> void:
	_start_screen.visible = visible_now
	if visible_now:
		_win_panel.visible = false
		_show_dim(false)
	_pause_button.visible = not visible_now and not _pause_panel.visible
	_message.visible = not visible_now
	_hint.visible = not visible_now
	if visible_now:
		close_board()
		close_stats()
		_hide_lives_card()
		_countdown.visible = false
		_vignette.modulate.a = 0.0
		_power_label.visible = false
		if _nick_edit.text.strip_edges() == "":
			_nick_edit.grab_focus()
		else:
			_start_button.grab_focus()
		_fade_in(_start_screen)
		board_query.emit("preview", _preview_tab, "tiempo", "", "top")
		_start_title_bob()
	elif _title_tween != null and _title_tween.is_valid():
		_title_tween.kill()


func set_time(ms: int) -> void:
	_time_label.text = DB.format_time(ms)


func set_gem(found: bool) -> void:
	_gem_icon.found = found
	if found:
		_gem_icon.pivot_offset = _gem_icon.size * 0.5
		_gem_icon.scale = Vector2(1.7, 1.7)
		create_tween().tween_property(_gem_icon, "scale", Vector2.ONE, 0.45) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Cuenta atras del Super salto; con 0 se oculta.
func set_power(seconds: float) -> void:
	_power_label.visible = seconds > 0.0
	if seconds > 0.0:
		_power_label.text = "Super salto  %d s" % ceili(seconds)
		# Parpadea en los ultimos segundos para avisar de que se acaba.
		_power_label.modulate.a = 1.0 if seconds > 3.0 or fmod(seconds, 0.5) > 0.2 else 0.35


# --- Contrarreloj ------------------------------------------------------------------

# Fila de tarjetas de contrarreloj debajo de las de la aventura.
func _build_trial_row() -> void:
	var box := _level_buttons.get_parent()
	_trial_label = Label.new()
	_trial_label.text = "CONTRARRELOJ  -  corre antes de que suba la marea"
	_trial_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_trial_label.add_theme_font_size_override("font_size", 20)
	_trial_label.add_theme_color_override("font_color", COUNTDOWN_WARN)
	box.add_child(_trial_label)
	box.move_child(_trial_label, _level_buttons.get_index() + 1)
	_trial_buttons = HBoxContainer.new()
	_trial_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_trial_buttons.add_theme_constant_override("separation", 12)
	box.add_child(_trial_buttons)
	box.move_child(_trial_buttons, _trial_label.get_index() + 1)


# Las tarjetas de contrarreloj son rojizas: se distinguen de un vistazo.
func _style_trial_card(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		# Se lee del contenedor, que ya esta en el arbol y hereda el tema; el
		# boton recien creado todavia no.
		var base := _trial_buttons.get_theme_stylebox(state, &"LevelCard")
		if not (base is StyleBoxFlat):
			continue
		var box := base.duplicate() as StyleBoxFlat
		if state == "normal" or state == "focus":
			box.bg_color = TRIAL_CARD_COLOR
		else:
			box.bg_color = TRIAL_CARD_COLOR.lightened(0.15)
		box.border_color = TRIAL_CARD_EDGE
		button.add_theme_stylebox_override(state, box)


func _build_hurry_fx(root: Control) -> void:
	# Bordes rojos que laten cuando queda poco tiempo.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 0.1, 0.05, 0.0))
	gradient.add_point(0.55, Color(1, 0.1, 0.05, 0.0))
	gradient.set_color(gradient.get_point_count() - 1, Color(0.9, 0.05, 0.02, 0.85))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.05, 1.05)
	texture.width = 256
	texture.height = 256
	_vignette = TextureRect.new()
	_vignette.name = "Vignette"
	_vignette.texture = texture
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.anchor_right = 1.0
	_vignette.anchor_bottom = 1.0
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.modulate.a = 0.0
	root.add_child(_vignette)
	root.move_child(_vignette, 1)

	# Destello blanco de los relampagos.
	_flash = ColorRect.new()
	_flash.name = "Flash"
	_flash.color = Color(0.9, 0.95, 1, 1)
	_flash.anchor_right = 1.0
	_flash.anchor_bottom = 1.0
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.modulate.a = 0.0
	root.add_child(_flash)
	root.move_child(_flash, 1)

	# Destello rojo de dano / impacto.
	_damage_flash = ColorRect.new()
	_damage_flash.name = "DamageFlash"
	_damage_flash.color = Color(0.92, 0.08, 0.08, 1.0)
	_damage_flash.anchor_right = 1.0
	_damage_flash.anchor_bottom = 1.0
	_damage_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_damage_flash.modulate.a = 0.0
	root.add_child(_damage_flash)
	root.move_child(_damage_flash, 2)

	# Cuenta atras grande bajo la barra superior.
	_countdown = Label.new()
	_countdown.name = "Countdown"
	_countdown.visible = false
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown.anchor_left = 0.5
	_countdown.anchor_right = 0.5
	_countdown.offset_left = -160
	_countdown.offset_right = 160
	_countdown.offset_top = 70
	_countdown.offset_bottom = 140
	_countdown.add_theme_font_size_override("font_size", 58)
	_countdown.add_theme_constant_override("outline_size", 12)
	_countdown.add_theme_color_override("font_outline_color", Color(0.08, 0.04, 0.1, 1))
	_countdown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_countdown)


## En contrarreloj no hay vidas ni gema: se ve la cuenta atras.
func set_trial_mode(on: bool) -> void:
	_trial_mode = on
	$Root/TopPill/TopBar/Hearts.visible = not on
	$Root/TopPill/TopBar/Gems.visible = not on
	_countdown.visible = on
	_countdown_second = -1
	# Los mensajes bajan para no taparse con la cuenta atras y el rotulo.
	_message.offset_top = 236.0 if on else 108.0
	_message.offset_bottom = _message.offset_top + 54.0
	if not on:
		_vignette.modulate.a = 0.0


# Cuenta atras: blanca, naranja con menos de 10 s y roja con menos de 5.
# Cada segundo de los ultimos 10 el numero da un golpe y los bordes laten.
func set_countdown(seconds: float, limit: float) -> void:
	if _countdown == null or not _trial_mode:
		return
	var left := maxf(seconds, 0.0)
	_countdown.text = "%d.%d" % [floori(left), floori(fmod(left, 1.0) * 10.0)] if left < 10.0 else "%d" % ceili(left)
	var color := COUNTDOWN_CALM
	if left <= 5.0:
		color = COUNTDOWN_PANIC
	elif left <= 10.0:
		color = COUNTDOWN_WARN
	_countdown.add_theme_color_override("font_color", color)

	var urgency := clampf(1.0 - left / 10.0, 0.0, 1.0)
	var beat := fmod(left, 1.0)
	# Latido: maximo justo al cambiar de segundo y se apaga enseguida.
	var pulse := pow(beat, 3.0) if left <= 10.0 else 0.0
	_vignette.modulate.a = urgency * (0.35 + 0.45 * pulse)

	var second := ceili(left)
	if left <= 10.0 and second != _countdown_second:
		_countdown_second = second
		_countdown.pivot_offset = _countdown.size * 0.5
		_countdown.scale = Vector2.ONE * (1.25 + urgency * 0.25)
		if _countdown_tween != null and _countdown_tween.is_valid():
			_countdown_tween.kill()
		_countdown_tween = create_tween()
		_countdown_tween.tween_property(_countdown, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	elif left > 10.0:
		_countdown_second = -1


## "+3 s" en verde o "-3 s" en rojo, que sale de la cuenta atras y se va.
func show_time_delta(seconds: float) -> void:
	if _countdown == null:
		return
	var label := Label.new()
	label.text = ("+%d s" if seconds > 0.0 else "%d s") % roundi(seconds)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 36)
	label.add_theme_constant_override("outline_size", 9)
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.1, 1))
	label.add_theme_color_override("font_color", Color(0.5, 1, 0.55) if seconds > 0.0 else COUNTDOWN_PANIC)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.position = _countdown.position + Vector2(_countdown.size.x * 0.5 + 70, 10)
	_countdown.get_parent().add_child(label)
	var tween := create_tween().set_parallel()
	tween.tween_property(label, "position:y", label.position.y + (-40.0 if seconds > 0.0 else 40.0), 0.9)
	tween.tween_property(label, "modulate:a", 0.0, 0.9).set_delay(0.3)
	tween.chain().tween_callback(label.queue_free)
	# La cuenta atras tambien reacciona.
	_countdown.pivot_offset = _countdown.size * 0.5
	_countdown.scale = Vector2.ONE * (1.3 if seconds > 0.0 else 0.85)
	create_tween().tween_property(_countdown, "scale", Vector2.ONE, 0.35) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func flash(strength: float = 0.5) -> void:
	if _flash == null:
		return
	_flash.modulate.a = strength
	var tween := create_tween()
	tween.tween_property(_flash, "modulate:a", 0.0, 0.08)
	tween.tween_property(_flash, "modulate:a", strength * 0.6, 0.06)
	tween.tween_property(_flash, "modulate:a", 0.0, 0.35)


## Destello rojo de impacto / dano en la pantalla.
func show_damage_flash(strength: float = 0.55) -> void:
	if _damage_flash == null:
		return
	if _damage_tween != null and _damage_tween.is_valid():
		_damage_tween.kill()
	_damage_flash.modulate.a = strength
	_damage_tween = create_tween()
	_damage_tween.tween_property(_damage_flash, "modulate:a", 0.0, 0.42) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# --- Vidas al reaparecer -------------------------------------------------------

func _build_lives_card(root: Control) -> void:
	_lives_card = PanelContainer.new()
	_lives_card.name = "LivesCard"
	_lives_card.theme_type_variation = &"HudPill"
	_lives_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lives_card.visible = false
	_lives_card.anchor_left = 0.5
	_lives_card.anchor_right = 0.5
	_lives_card.anchor_top = 0.3
	_lives_card.anchor_bottom = 0.3
	_lives_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_lives_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(_lives_card)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 8)
	_lives_card.add_child(box)

	_lives_card_text = Label.new()
	_lives_card_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lives_card_text.add_theme_font_size_override("font_size", 34)
	_lives_card_text.add_theme_color_override("font_color", GOLD_TEXT)
	box.add_child(_lives_card_text)

	_lives_card_hearts = HBoxContainer.new()
	_lives_card_hearts.alignment = BoxContainer.ALIGNMENT_CENTER
	_lives_card_hearts.add_theme_constant_override("separation", 10)
	box.add_child(_lives_card_hearts)


# Tarjeta centrada con las vidas que quedan, al reaparecer tras una caida.
func show_lives_card(lives: int, max_lives: int) -> void:
	if _lives_card == null:
		return
	if lives == 1:
		_lives_card_text.text = "¡Ultima vida!"
	else:
		_lives_card_text.text = "Vidas restantes: %d" % lives
	for child in _lives_card_hearts.get_children():
		child.queue_free()
	for i in max_lives:
		var heart := HeartScript.new()
		heart.custom_minimum_size = HEART_SIZE * 1.4
		heart.filled = i < lives
		_lives_card_hearts.add_child(heart)

	_lives_card.visible = true
	_lives_card.reset_size()
	_lives_card.pivot_offset = _lives_card.size * 0.5
	_lives_card.scale = Vector2(0.6, 0.6)
	_lives_card.modulate.a = 0.0
	if _lives_card_tween != null and _lives_card_tween.is_valid():
		_lives_card_tween.kill()
	_lives_card_tween = create_tween()
	_lives_card_tween.tween_property(_lives_card, "modulate:a", 1.0, 0.15)
	_lives_card_tween.parallel().tween_property(_lives_card, "scale", Vector2.ONE, 0.4) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_lives_card_tween.tween_interval(1.6)
	_lives_card_tween.tween_property(_lives_card, "modulate:a", 0.0, 0.4)
	_lives_card_tween.tween_callback(func() -> void: _lives_card.visible = false)


func _hide_lives_card() -> void:
	if _lives_card_tween != null and _lives_card_tween.is_valid():
		_lives_card_tween.kill()
	if _lives_card != null:
		_lives_card.visible = false


# --- Agua -----------------------------------------------------------------------

func _build_water_overlay(root: Control) -> void:
	_water_overlay = ColorRect.new()
	_water_overlay.name = "WaterOverlay"
	_water_overlay.color = Color(0.04, 0.24, 0.45, 1)
	_water_overlay.anchor_right = 1.0
	_water_overlay.anchor_bottom = 1.0
	_water_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_water_overlay.modulate.a = 0.0
	_water_overlay.visible = false
	root.add_child(_water_overlay)
	# Detras de todo el HUD: tine el juego, no los textos.
	root.move_child(_water_overlay, 0)


# Al hundirse la pantalla se tine de azul; al reaparecer se aclara.
func set_underwater(on: bool) -> void:
	if _water_overlay == null:
		return
	if _water_tween != null and _water_tween.is_valid():
		_water_tween.kill()
	_water_overlay.visible = true
	_water_tween = create_tween()
	if on:
		_water_tween.tween_property(_water_overlay, "modulate:a", 0.55, 1.2) \
			.set_ease(Tween.EASE_IN)
	else:
		_water_tween.tween_property(_water_overlay, "modulate:a", 0.0, 0.45)
		_water_tween.tween_callback(func() -> void: _water_overlay.visible = false)


# --- Nickname --------------------------------------------------------------------

func get_nickname() -> String:
	return _nick_edit.text


func set_nickname(nickname: String) -> void:
	_nick_edit.text = nickname
	_me = nickname


func show_nick_error(text: String) -> void:
	_nick_error.text = text
	_nick_edit.grab_focus()
	# Pequena sacudida del campo para que se vea donde esta el problema.
	var row := _nick_edit.get_parent() as Control
	var tween := create_tween()
	for offset in [12.0, -10.0, 6.0, 0.0]:
		tween.tween_property(row, "position:x", row.position.x + offset, 0.05)


func set_welcome(text: String) -> void:
	_welcome.text = text


func _style_line_edit(edit: LineEdit) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.09, 0.13, 0.29, 0.94)
	box.border_color = Color(1, 0.8, 0.26, 1)
	box.set_border_width_all(2)
	box.set_corner_radius_all(12)
	box.content_margin_left = 12
	box.content_margin_right = 12
	var focus := box.duplicate() as StyleBoxFlat
	focus.border_color = Color(0.6, 0.92, 1, 1)
	focus.set_border_width_all(3)
	edit.add_theme_stylebox_override("normal", box)
	edit.add_theme_stylebox_override("focus", focus)
	edit.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	edit.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.45))
	edit.add_theme_color_override("caret_color", GOLD_TEXT)


# --- Tabla de records: resumen en la pantalla de inicio -----------------------------

## Pestanas de cada nivel ([id, nombre corto, nombre largo]) y totales para
## la tabla general.
func set_level_tabs(tabs: Array, level_total: int, gem_levels: int) -> void:
	_level_tabs = tabs
	_level_total = level_total
	_gem_levels = gem_levels
	_build_preview_tabs()
	_build_full_tabs()


func _build_preview_tabs() -> void:
	_clear_grid(_preview_tabs)
	for tab in _level_tabs + [["general", "Gral", "General"]]:
		var button := Button.new()
		button.text = tab[1]
		button.custom_minimum_size = Vector2(62, 34)
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", 16)
		button.set_meta("tab", tab[0])
		button.pressed.connect(func() -> void:
			_preview_tab = tab[0]
			_style_tabs(_preview_tabs.get_children(), _preview_tab)
			board_query.emit("preview", _preview_tab, "tiempo", "", "top"))
		_preview_tabs.add_child(button)
	_style_tabs(_preview_tabs.get_children(), _preview_tab)


# Filas del resumen: los 5 primeros del nivel (o de la general). Si el jugador
# no esta entre ellos, main.gd anade su fila al final y aqui se separa con "...".
func set_board_preview(tab: String, rows: Array, available: bool) -> void:
	_clear_grid(_preview_rows)
	if not available:
		_preview_rows.columns = 1
		_add_cell(_preview_rows, "Base de datos no disponible", DIM_TEXT, 18)
		return
	_preview_rows.columns = 4
	var headers := ["#", "Jugador", "Liga", "Niveles"] if tab == "general" else ["#", "Jugador", "Tiempo", "Estrellas"]
	for h in headers:
		_add_cell(_preview_rows, h, GOLD_TEXT, 18)
	var last := 0
	for r in rows:
		var puesto := int(r.get("puesto", last + 1))
		if puesto > last + 1:
			for text in ["...", "", "", ""]:
				_add_cell(_preview_rows, text, DIM_TEXT, 18)
		last = puesto
		var color := _row_color(r)
		_add_cell(_preview_rows, str(puesto), _podium_color(puesto, color), 18)
		_add_cell(_preview_rows, str(r["nickname"]), color, 18, true)
		if tab == "general":
			var league := _league(int(r.get("puntos", 0)))
			_add_cell(_preview_rows, league, TIER_COLORS.get(league, color), 18)
			_add_cell(_preview_rows, "%d / %d" % [int(r["niveles"]), _level_total], color, 18)
		else:
			_add_cell(_preview_rows, DB.format_time(int(r["tiempo_ms"])), color, 18)
			_add_cell(_preview_rows, "%d/%d%s" % [int(r["estrellas"]), int(r["estrellas_total"]), "  +gema" if int(r["gema"]) == 1 else ""], color, 18)
	if rows.is_empty():
		for text in ["", "Sin records aun", "", ""]:
			_add_cell(_preview_rows, text, DIM_TEXT, 18)


# --- Tabla de records completa -----------------------------------------------------

func _build_board(root: Control) -> void:
	_board_panel = Panel.new()
	_board_panel.name = "BoardPanel"
	_board_panel.visible = false
	_board_panel.anchor_left = 0.5
	_board_panel.anchor_right = 0.5
	_board_panel.anchor_top = 0.5
	_board_panel.anchor_bottom = 0.5
	_board_panel.offset_left = -550
	_board_panel.offset_right = 550
	_board_panel.offset_top = -312
	_board_panel.offset_bottom = 312
	root.add_child(_board_panel)
	_make_opaque(_board_panel)

	var box := VBoxContainer.new()
	box.anchor_right = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = 24
	box.offset_right = -24
	box.offset_top = 14
	box.offset_bottom = -14
	box.add_theme_constant_override("separation", 8)
	_board_panel.add_child(box)

	var title := Label.new()
	title.text = "TABLA DE RECORDS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", GOLD_TEXT)
	box.add_child(title)

	_full_tabs_box = HBoxContainer.new()
	_full_tabs_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_full_tabs_box.add_theme_constant_override("separation", 6)
	box.add_child(_full_tabs_box)
	_build_full_tabs()

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 10)
	box.add_child(tools)
	for view in VIEWS:
		var button := _small_toggle(view[1], view[0], Vector2(130, 36), 18)
		button.pressed.connect(func() -> void:
			_board_view = view[0]
			_refresh_board())
		tools.add_child(button)
		_board_view_buttons[view[0]] = button
	_board_filter = LineEdit.new()
	_board_filter.custom_minimum_size = Vector2(220, 36)
	_board_filter.placeholder_text = "Buscar jugador"
	_board_filter.add_theme_font_size_override("font_size", 18)
	_board_filter.clear_button_enabled = true
	_style_line_edit(_board_filter)
	_board_filter.text_changed.connect(func(_t: String) -> void: _refresh_board())
	tools.add_child(_board_filter)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tools.add_child(spacer)
	var order := Label.new()
	order.text = "Ordenar:"
	order.add_theme_font_size_override("font_size", 18)
	tools.add_child(order)
	for sort in [["tiempo", "Tiempo"], ["estrellas", "Estrellas"]]:
		var button := _small_toggle(sort[1], sort[0], Vector2(120, 36), 18)
		button.pressed.connect(func() -> void:
			_board_sort = sort[0]
			_refresh_board())
		tools.add_child(button)
		_board_sort_buttons[sort[0]] = button

	_build_goal_strip(box)

	_board_header = HBoxContainer.new()
	_board_header.add_theme_constant_override("separation", 8)
	var header_pad := MarginContainer.new()
	header_pad.add_theme_constant_override("margin_left", 10)
	header_pad.add_theme_constant_override("margin_right", 10)
	header_pad.add_child(_board_header)
	box.add_child(header_pad)

	_board_scroll = ScrollContainer.new()
	_board_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_board_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_board_scroll)
	_board_list = VBoxContainer.new()
	_board_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board_list.add_theme_constant_override("separation", 4)
	_board_scroll.add_child(_board_list)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	box.add_child(footer)
	_board_path = Label.new()
	_board_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board_path.add_theme_font_size_override("font_size", 13)
	_board_path.add_theme_color_override("font_color", DIM_TEXT)
	_board_path.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	footer.add_child(_board_path)
	var mine := Button.new()
	mine.text = "Mis estadisticas"
	mine.custom_minimum_size = Vector2(190, 44)
	mine.theme_type_variation = &"SecondaryButton"
	mine.add_theme_font_size_override("font_size", 20)
	mine.pressed.connect(open_my_stats)
	_add_button_juice(mine)
	footer.add_child(mine)
	# Jugar el nivel que se esta mirando sin pasar por el menu.
	_board_play = Button.new()
	_board_play.custom_minimum_size = Vector2(190, 44)
	_board_play.add_theme_font_size_override("font_size", 20)
	_board_play.pressed.connect(func() -> void: _play_level(int(_board_tab)))
	_add_button_juice(_board_play)
	footer.add_child(_board_play)
	var close := Button.new()
	close.text = "Cerrar"
	close.custom_minimum_size = Vector2(130, 44)
	close.theme_type_variation = &"SecondaryButton"
	close.add_theme_font_size_override("font_size", 20)
	close.pressed.connect(close_board)
	_add_button_juice(close)
	footer.add_child(close)

	_build_stats(root)


func _build_full_tabs() -> void:
	if _full_tabs_box == null:
		return
	_clear_grid(_full_tabs_box)
	_board_tab_buttons.clear()
	for tab in _level_tabs + [["general", "General", "General"], ["historial", "Historial", "Mi historial"]]:
		var button := _small_toggle(tab[2], tab[0], Vector2(132, 40), 17)
		button.pressed.connect(func() -> void:
			_board_tab = tab[0]
			_refresh_board())
		_full_tabs_box.add_child(button)
		_board_tab_buttons[tab[0]] = button


# Franja de objetivo: puesto actual y cuanto falta para pasar al siguiente.
func _build_goal_strip(parent: Control) -> void:
	_board_goal = PanelContainer.new()
	_board_goal.theme_type_variation = &"HudPill"
	parent.add_child(_board_goal)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_board_goal.add_child(row)
	_board_goal_text = Label.new()
	_board_goal_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board_goal_text.add_theme_font_size_override("font_size", 18)
	_board_goal_text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_board_goal_text)
	_board_goal_bar = ProgressBar.new()
	_board_goal_bar.custom_minimum_size = Vector2(220, 18)
	_board_goal_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_board_goal_bar.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.35)
	bg.set_corner_radius_all(9)
	var fill := bg.duplicate() as StyleBoxFlat
	fill.bg_color = TIER_COLORS["Oro"]
	_board_goal_bar.add_theme_stylebox_override("background", bg)
	_board_goal_bar.add_theme_stylebox_override("fill", fill)
	row.add_child(_board_goal_bar)


func open_board() -> void:
	if _board_panel == null:
		return
	_board_panel.visible = true
	_show_dim(true)
	_pop_in(_board_panel)
	_refresh_board()


func close_board() -> void:
	close_stats()
	if _board_panel == null or not _board_panel.visible:
		return
	_board_panel.visible = false
	_show_dim(_pause_panel.visible or _win_panel.visible)


func is_board_open() -> bool:
	return _board_panel != null and _board_panel.visible


func _refresh_board() -> void:
	_style_tabs(_board_tab_buttons.values(), _board_tab)
	_style_tabs(_board_sort_buttons.values(), _board_sort)
	_style_tabs(_board_view_buttons.values(), _board_view)
	var is_level := _board_tab.is_valid_int()
	# Ordenar solo tiene sentido en las tablas de nivel; la vista y la busqueda,
	# en todas menos el historial.
	for button in _board_sort_buttons.values():
		button.disabled = not is_level
	for button in _board_view_buttons.values():
		button.disabled = _board_tab == "historial"
	# La vista "cerca" ya centra al jugador: buscar a otro la contradice.
	_board_filter.editable = _board_tab != "historial" and _board_view == "top"
	_board_play.visible = is_level
	_board_play.text = "Jugar " + _tab_name(_board_tab)
	board_query.emit("full", _board_tab, _board_sort, _board_filter.text.strip_edges(), _board_view)


# Rellena la tabla completa. `rows` llega ya consultado por main.gd, cada fila
# con su "puesto". `goal` describe la franja de objetivo del jugador: en un
# nivel {puesto, total, tiempo_ms, par_ms, rival, rival_ms, rival_puesto}; en
# la general {puesto, total, puntos}. Vacio la oculta.
func set_board_rows(tab: String, rows: Array, available: bool, db_path: String, goal: Dictionary = {}) -> void:
	if tab != _board_tab:
		return
	_clear_grid(_board_list)
	_clear_grid(_board_header)
	_board_path.text = "Pulsa un jugador para ver sus estadisticas" if available else "Base de datos no disponible (extension SQLite sin cargar)"
	_board_path.tooltip_text = "Base de datos: " + db_path
	_set_goal(tab, goal)
	if not available:
		return
	var columns: Array = GENERAL_COLUMNS if tab == "general" else (HISTORY_COLUMNS if tab == "historial" else LEVEL_COLUMNS)
	for column in columns:
		_add_board_cell(_board_header, column, column[0], GOLD_TEXT, SECONDARY_SIZE)

	# Divisiones: las filas se agrupan por medalla (niveles por tiempo) o por
	# liga (general), con una cabecera de color al empezar cada grupo.
	var by_tier := tab == "general" or (tab.is_valid_int() and _board_sort == "tiempo")
	var current_tier := ""
	var last_puesto := 0
	for r in rows:
		if tab == "historial":
			_board_list.add_child(_history_row(r))
			continue
		var tier := _row_tier(tab, r)
		var puesto := int(r.get("puesto", 0))
		if last_puesto > 0 and puesto > last_puesto + 1:
			_board_list.add_child(_division_header(""))
		if by_tier and tier != current_tier:
			_board_list.add_child(_division_header(tier))
			current_tier = tier
		last_puesto = puesto
		_board_list.add_child(_board_row(tab, r, columns, tier))
	if rows.is_empty():
		var empty := Label.new()
		if tab == "historial":
			empty.text = "Aun no has jugado con este nickname."
		elif _board_view == "cerca":
			empty.text = "Aun no tienes record aqui: completalo para ver a tus rivales."
		else:
			empty.text = "Sin registros todavia."
		empty.add_theme_color_override("font_color", DIM_TEXT)
		empty.add_theme_font_size_override("font_size", 18)
		_board_list.add_child(empty)
	# En la vista "cerca" el jugador queda en el centro del scroll.
	if _board_view == "cerca":
		_center_me.call_deferred()


func _set_goal(tab: String, goal: Dictionary) -> void:
	_board_goal.visible = not goal.is_empty()
	if goal.is_empty():
		return
	var parts: Array[String] = []
	var ratio := 1.0
	parts.append("Puesto #%d de %d" % [int(goal["puesto"]), int(goal["total"])])
	if tab == "general":
		var points := int(goal.get("puntos", 0))
		var league := _league(points)
		parts.append("Liga %s (%d pts)" % [league, points])
		var next := DB.next_league(points, _max_points())
		if next.is_empty():
			parts.append("¡Liga maxima!")
		else:
			var missing := int(next[1]) - points
			parts.append(("Falta 1 pt para %s" % next[0]) if missing == 1 else ("Faltan %d pts para %s" % [missing, next[0]]))
			ratio = float(points) / float(next[1])
		_board_goal_text.add_theme_color_override("font_color", TIER_COLORS.get(league, Color.WHITE))
	else:
		var me_ms := int(goal["tiempo_ms"])
		if goal.has("rival"):
			parts.append("Faltan %s s para superar a %s (#%d)" % [_seconds(me_ms - int(goal["rival_ms"])), goal["rival"], int(goal["rival_puesto"])])
			ratio = float(goal["rival_ms"]) / float(maxi(me_ms, 1))
		else:
			parts.append("¡Eres el #1!")
		var par_ms := int(goal.get("par_ms", 0))
		if par_ms > 0 and me_ms > par_ms:
			parts.append("Oro: %s s menos" % _seconds(me_ms - par_ms))
		_board_goal_text.add_theme_color_override("font_color", ME_TEXT)
	_board_goal_text.text = "  -  ".join(parts)
	_board_goal_bar.value = clampf(ratio, 0.0, 1.0) * 100.0


# 2310 ms -> "2.31"
static func _seconds(ms: int) -> String:
	return "%.2f" % (maxi(ms, 0) / 1000.0)


func _max_points() -> int:
	return _level_total * int(DB.MEDAL_POINTS["Oro"])


func _league(points: int) -> String:
	return DB.league_for(points, _max_points())


func _tab_name(tab: String) -> String:
	for t in _level_tabs:
		if t[0] == tab:
			return t[2]
	return tab


func _row_tier(tab: String, row: Dictionary) -> String:
	if tab == "general":
		return _league(int(row.get("puntos", 0)))
	var medal: Variant = row.get("medalla")
	return str(medal) if medal != null else "Sin liga"


func _center_me() -> void:
	for row in _board_list.get_children():
		if row.has_meta("me"):
			_board_scroll.scroll_vertical = int(row.position.y + row.size.y * 0.5 - _board_scroll.size.y * 0.5)
			return


# Fila de un jugador: un boton plano que abre sus estadisticas.
func _board_row(tab: String, r: Dictionary, columns: Array, tier: String) -> Button:
	var is_me := _is_me(r)
	var row := _row_button(is_me)
	var nickname := str(r["nickname"])
	row.tooltip_text = "Ver estadisticas de " + nickname
	row.pressed.connect(func() -> void: _request_stats(nickname, int(tab) if tab.is_valid_int() else 0))
	var cells := _row_cells(row)
	var puesto := int(r.get("puesto", 0))
	var text_color := ME_TEXT if is_me else Color.WHITE
	var values: Array
	if tab == "general":
		var total_time := DB.format_time(int(r["tiempo_ms"])) if int(r["niveles"]) > 0 else "-"
		values = ["#%d" % puesto, nickname, tier, "%d / %d" % [int(r["niveles"]), _level_total], str(r["estrellas"]),
			"%d / %d" % [int(r["gemas"]), _gem_levels], total_time, str(r["intentos"]), str(r["caidas"])]
	else:
		values = ["#%d" % puesto, nickname, DB.format_time(int(r["tiempo_ms"])), tier,
			"%d/%d" % [int(r["estrellas"]), int(r["estrellas_total"])], "Si" if int(r["gema"]) == 1 else "-",
			str(r["caidas"]), "%d de %d" % [int(r["numero"]), int(r["intentos_totales"])],
			str(r["fecha"]).substr(0, 10)]
	for i in columns.size():
		var column: Array = columns[i]
		if column[0] in ["Medalla", "Liga"]:
			_add_tier_chip(cells, column, values[i])
		elif i == 0:
			_add_board_cell(cells, column, values[i], _podium_color(puesto, text_color), PRIMARY_SIZE)
		elif column[2]:
			_add_board_cell(cells, column, values[i], text_color, PRIMARY_SIZE)
		else:
			_add_board_cell(cells, column, values[i], SECONDARY_TEXT, SECONDARY_SIZE)
	return row


func _history_row(r: Dictionary) -> Control:
	var res := str(r["resultado"])
	var row := _row_button(res == "completado")
	if row.has_meta("me"):
		row.remove_meta("me")
	row.tooltip_text = "Ver tus estadisticas en este nivel"
	var nivel := int(r["nivel"])
	row.pressed.connect(func() -> void: _request_stats(_me, nivel))
	var cells := _row_cells(row)
	var values := ["%d. %s" % [nivel, r["nivel_nombre"]], "#%d" % int(r["numero"]),
		RESULT_TEXT.get(res, res), DB.format_time(int(r["tiempo_ms"])),
		"%d/%d" % [int(r["estrellas"]), int(r["estrellas_total"])],
		"Si" if int(r["gema"]) == 1 else "-", str(r["corazones"]), str(r["caidas"]),
		str(r["fecha"]).substr(0, 16)]
	for i in HISTORY_COLUMNS.size():
		var column: Array = HISTORY_COLUMNS[i]
		var color := (ME_TEXT if res == "completado" else Color.WHITE) if column[2] else SECONDARY_TEXT
		_add_board_cell(cells, column, values[i], color, PRIMARY_SIZE - 4 if column[2] else SECONDARY_SIZE)
	return row


func _row_button(is_me: bool) -> Button:
	var row := Button.new()
	row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	row.focus_mode = Control.FOCUS_NONE
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.6, 0.92, 1, 0.16) if is_me else Color(1, 1, 1, 0.04)
	normal.set_corner_radius_all(10)
	if is_me:
		normal.border_color = ME_TEXT
		normal.border_width_left = 4
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = normal.bg_color + Color(0.1, 0.1, 0.1, 0.1)
	for state in ["normal", "disabled", "focus"]:
		row.add_theme_stylebox_override(state, normal)
	row.add_theme_stylebox_override("hover", hover)
	row.add_theme_stylebox_override("pressed", hover)
	if is_me:
		row.set_meta("me", true)
	return row


func _row_cells(row: Button) -> HBoxContainer:
	var cells := HBoxContainer.new()
	cells.anchor_right = 1.0
	cells.anchor_bottom = 1.0
	cells.offset_left = 10
	cells.offset_right = -10
	cells.add_theme_constant_override("separation", 8)
	cells.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(cells)
	return cells


# Cabecera de una division ("ORO", "PLATA"...). Sin nombre es un salto de
# puestos, por ejemplo al buscar un jugador.
func _division_header(tier: String) -> Control:
	var label := Label.new()
	label.text = "  " + tier.to_upper() if tier != "" else "  ..."
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", TIER_COLORS.get(tier, DIM_TEXT))
	label.add_theme_constant_override("outline_size", 4)
	return label


func _add_board_cell(parent: Container, column: Array, text: String, color: Color, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_vertical = Control.SIZE_FILL
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 4)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if int(column[1]) == 0:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.custom_minimum_size.x = 90
	else:
		label.custom_minimum_size.x = column[1]
	parent.add_child(label)
	return label


# Medalla o liga como pastilla de color: se distingue de un vistazo.
func _add_tier_chip(parent: Container, column: Array, tier: String) -> void:
	var holder := CenterContainer.new()
	holder.custom_minimum_size.x = column[1]
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(holder)
	if tier == "Sin liga":
		var none := Label.new()
		none.text = "-"
		none.add_theme_color_override("font_color", SECONDARY_TEXT)
		holder.add_child(none)
	else:
		holder.add_child(_tier_chip(tier, SECONDARY_SIZE))


func _tier_chip(tier: String, font_size: int) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var color: Color = TIER_COLORS.get(tier, TIER_COLORS["Sin liga"])
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color, 0.22)
	style.border_color = color
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 10
	style.content_margin_right = 10
	chip.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = tier
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color.lightened(0.25))
	chip.add_child(label)
	return chip


# El panel del tema es translucido; encima del menu (o las estadisticas encima
# de la tabla) se mezclaban los textos de detras.
static func _make_opaque(panel: Panel) -> void:
	var style := panel.get_theme_stylebox("panel") as StyleBoxFlat
	if style == null:
		return
	style = style.duplicate() as StyleBoxFlat
	style.bg_color.a = 1.0
	panel.add_theme_stylebox_override("panel", style)


func _small_toggle(text: String, key: String, min_size: Vector2, font_size: int) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = min_size
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", font_size)
	button.set_meta("tab", key)
	return button


func _play_level(nivel: int) -> void:
	close_board()
	level_selected.emit(nivel - 1)


# --- Estadisticas de jugador ---------------------------------------------------------

func open_my_stats() -> void:
	if _me == "":
		_nick_error.text = "Juega con un nickname para tener estadisticas."
		return
	_request_stats(_me, _stats_level)


func _request_stats(nickname: String, nivel: int) -> void:
	if nivel > 0:
		_stats_level = nivel
	profile_requested.emit(nickname)


func _build_stats(root: Control) -> void:
	_stats_panel = Panel.new()
	_stats_panel.name = "StatsPanel"
	_stats_panel.visible = false
	# Ocupa la ventana con un margen: la grafica aprovecha todo el alto.
	_stats_panel.anchor_right = 1.0
	_stats_panel.anchor_bottom = 1.0
	_stats_panel.offset_left = 16
	_stats_panel.offset_right = -16
	_stats_panel.offset_top = 60
	_stats_panel.offset_bottom = -40
	root.add_child(_stats_panel)
	_make_opaque(_stats_panel)
	_stats_box = VBoxContainer.new()
	_stats_box.anchor_right = 1.0
	_stats_box.anchor_bottom = 1.0
	_stats_box.offset_left = 24
	_stats_box.offset_right = -24
	_stats_box.offset_top = 16
	_stats_box.offset_bottom = -16
	_stats_box.add_theme_constant_override("separation", 10)
	_stats_panel.add_child(_stats_box)


func close_stats() -> void:
	if _stats_panel != null:
		_stats_panel.visible = false
	if _board_panel == null or not _board_panel.visible:
		_show_dim(_pause_panel.visible or _win_panel.visible)


func is_stats_open() -> bool:
	return _stats_panel != null and _stats_panel.visible


## Pantalla de estadisticas de un jugador. `profile` sale de
## leaderboard_db.player_profile(); `mine` es el perfil del jugador actual
## (para comparar, vacio si es el mismo); `leaders` es el record #1 de cada
## nivel ({nivel: {nickname, tiempo_ms}}); `pars` el tiempo de oro de cada
## nivel en ms ({nivel: ms}).
func show_profile(profile: Dictionary, mine: Dictionary, leaders: Dictionary, pars: Dictionary) -> void:
	if _stats_panel == null or profile.is_empty():
		return
	_stats_data = {"profile": profile, "mine": mine, "leaders": leaders, "pars": pars}
	if _stats_compare == "tu" and mine.is_empty():
		_stats_compare = "lider"
	_render_stats()
	if not _stats_panel.visible:
		_stats_panel.visible = true
		_show_dim(true)
		_pop_in(_stats_panel)


func _render_stats() -> void:
	_clear_grid(_stats_box)
	var profile: Dictionary = _stats_data["profile"]
	var mine: Dictionary = _stats_data["mine"]
	var points := int(profile.get("puntos", 0))
	var league := _league(points)
	var tier_color: Color = TIER_COLORS.get(league, Color.WHITE)
	var nickname := str(profile["nickname"])
	var records: Dictionary = profile.get("records", {})
	var levels: Dictionary = profile.get("niveles", {})

	# Cabecera: avatar, nombre, liga y puesto general.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	_stats_box.add_child(head)
	head.add_child(_avatar(nickname, tier_color))
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.add_theme_constant_override("separation", 2)
	head.add_child(names)
	var title := Label.new()
	title.text = nickname + ("  (tu)" if _is_me(profile) else "")
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", ME_TEXT if _is_me(profile) else GOLD_TEXT)
	names.add_child(title)
	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", 10)
	names.add_child(sub)
	if league != "Sin liga":
		sub.add_child(_tier_chip(league, 15))
	var sub_text := Label.new()
	sub_text.text = "Puesto general #%d de %d  -  %d de %d pts  -  Jugando desde %s" % [
		int(profile.get("puesto", 0)), int(profile.get("jugadores", 0)), points, _max_points(),
		str(profile.get("creado", "")).substr(0, 10)]
	sub_text.add_theme_font_size_override("font_size", 15)
	sub_text.add_theme_color_override("font_color", SECONDARY_TEXT)
	sub.add_child(sub_text)
	var close := Button.new()
	close.text = "Volver"
	close.custom_minimum_size = Vector2(120, 42)
	close.theme_type_variation = &"SecondaryButton"
	close.add_theme_font_size_override("font_size", 18)
	close.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close.pressed.connect(close_stats)
	head.add_child(close)

	# Fichas de resumen.
	var attempts := int(profile.get("intentos", 0))
	var done := int(profile.get("completados", 0))
	var medals := {"Oro": 0, "Plata": 0, "Bronce": 0}
	for rec in records.values():
		var m: Variant = rec.get("medalla")
		if m != null and medals.has(str(m)):
			medals[str(m)] += 1
	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 8)
	_stats_box.add_child(tiles)
	tiles.add_child(_stat_tile("Niveles completados", "%d / %d" % [records.size(), _level_total]))
	tiles.add_child(_stat_tile("Intentos", str(attempts)))
	tiles.add_child(_stat_tile("Tasa de exito", "%d%%" % roundi(100.0 * done / maxi(attempts, 1))))
	tiles.add_child(_stat_tile("Caidas por intento", "%.1f" % (float(profile.get("caidas", 0)) / maxi(attempts, 1))))
	tiles.add_child(_stat_tile("Tiempo jugado", DB.format_time(int(profile.get("jugado_ms", 0))).get_slice(".", 0)))
	tiles.add_child(_stat_tile("Medallas O / P / B", "%d / %d / %d" % [medals["Oro"], medals["Plata"], medals["Bronce"]]))

	# Selector de nivel: una pastilla por nivel con el color de su medalla.
	var picker := HBoxContainer.new()
	picker.add_theme_constant_override("separation", 6)
	_stats_box.add_child(picker)
	var pick_label := Label.new()
	pick_label.text = "Nivel:"
	pick_label.add_theme_font_size_override("font_size", 17)
	picker.add_child(pick_label)
	if _stats_level < 1 or _stats_level > _level_tabs.size():
		_stats_level = 1
	for tab in _level_tabs:
		var nivel := int(tab[0])
		var button := _small_toggle(tab[1], tab[0], Vector2(70, 36), 17)
		var rec: Dictionary = records.get(nivel, {})
		if not rec.is_empty():
			button.tooltip_text = "%s  -  %s  -  %s" % [tab[2], DB.format_time(int(rec["tiempo_ms"])), str(rec.get("medalla", ""))]
		button.pressed.connect(func() -> void:
			_stats_level = nivel
			_render_stats())
		picker.add_child(button)
	_style_tabs(picker.get_children().slice(1), str(_stats_level))
	var pick_spacer := Control.new()
	pick_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_child(pick_spacer)
	var cmp_label := Label.new()
	cmp_label.text = "Comparar con:"
	cmp_label.add_theme_font_size_override("font_size", 17)
	picker.add_child(cmp_label)
	var cmp_buttons: Array = []
	for option in [["lider", "Lider"], ["tu", "Tu record"], ["nada", "Nada"]]:
		if option[0] == "tu" and mine.is_empty():
			continue
		var button := _small_toggle(option[1], option[0], Vector2(108, 36), 16)
		button.pressed.connect(func() -> void:
			_stats_compare = option[0]
			_render_stats())
		picker.add_child(button)
		cmp_buttons.append(button)
	_style_tabs(cmp_buttons, _stats_compare)

	# Detalle del nivel: grafica a la izquierda, datos a la derecha.
	var detail := HBoxContainer.new()
	detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 14)
	_stats_box.add_child(detail)
	var compare := _compare_for(_stats_level)
	var chart := StatsChart.new()
	chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chart.custom_minimum_size = Vector2(620, 0)
	detail.add_child(chart)
	chart.set_data(profile.get("series", {}).get(_stats_level, []), int(_stats_data["pars"].get(_stats_level, 0)),
		int(compare.get("tiempo_ms", 0)), str(compare.get("label", "")))
	detail.add_child(_level_facts(records.get(_stats_level, {}), levels.get(_stats_level, {}), compare))

	# Pie: leyenda de la grafica y acciones.
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	_stats_box.add_child(footer)
	var legend := Label.new()
	legend.text = "Puntos: intentos completados (color = medalla)  -  Rojo abajo: intentos fallidos  -  Cian: tu mejor marca en cada momento"
	legend.add_theme_font_size_override("font_size", 13)
	legend.add_theme_color_override("font_color", DIM_TEXT)
	legend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_child(legend)
	var see := Button.new()
	see.text = "Ver en la tabla"
	see.custom_minimum_size = Vector2(170, 42)
	see.theme_type_variation = &"SecondaryButton"
	see.add_theme_font_size_override("font_size", 18)
	see.pressed.connect(func() -> void:
		close_stats()
		_board_tab = str(_stats_level)
		if _board_panel.visible:
			_refresh_board()
		else:
			open_board())
	_add_button_juice(see)
	footer.add_child(see)
	var play := Button.new()
	play.text = "Jugar " + _tab_name(str(_stats_level))
	play.custom_minimum_size = Vector2(170, 42)
	play.add_theme_font_size_override("font_size", 18)
	play.pressed.connect(func() -> void:
		var nivel := _stats_level
		close_stats()
		_play_level(nivel))
	_add_button_juice(play)
	footer.add_child(play)


# Linea de comparacion de la grafica segun la opcion elegida.
func _compare_for(nivel: int) -> Dictionary:
	match _stats_compare:
		"lider":
			var leader: Dictionary = _stats_data["leaders"].get(nivel, {})
			if not leader.is_empty():
				return {"tiempo_ms": int(leader["tiempo_ms"]), "label": "Lider %s" % leader["nickname"], "nickname": str(leader["nickname"])}
		"tu":
			var rec: Dictionary = _stats_data["mine"].get("records", {}).get(nivel, {})
			if not rec.is_empty():
				return {"tiempo_ms": int(rec["tiempo_ms"]), "label": "Tu record", "nickname": _me}
	return {}


# Columna de datos del nivel elegido.
func _level_facts(rec: Dictionary, lvl: Dictionary, compare: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380, 0)
	box.add_theme_constant_override("separation", 6)
	var heading := Label.new()
	heading.text = _tab_name(str(_stats_level))
	heading.add_theme_font_size_override("font_size", 22)
	heading.add_theme_color_override("font_color", GOLD_TEXT)
	box.add_child(heading)
	var attempts := int(lvl.get("intentos", 0))
	var wins := int(lvl.get("completados", 0))
	if rec.is_empty():
		_fact(box, "Record", "Sin completar")
	else:
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 10)
		var time := Label.new()
		time.text = DB.format_time(int(rec["tiempo_ms"]))
		time.add_theme_font_size_override("font_size", 36)
		head.add_child(time)
		var medal: Variant = rec.get("medalla")
		if medal != null:
			var holder := CenterContainer.new()
			holder.add_child(_tier_chip(str(medal), 16))
			head.add_child(holder)
		box.add_child(head)
		_fact(box, "Puesto", "#%d de %d" % [int(rec["puesto"]), int(rec["de"])])
		var par_ms := int(_stats_data["pars"].get(_stats_level, 0))
		if par_ms > 0:
			var gap := int(rec["tiempo_ms"]) - par_ms
			_fact(box, "Frente al oro", ("%s s por debajo" % _seconds(-gap)) if gap <= 0 else ("%s s por encima" % _seconds(gap)))
		if not compare.is_empty() and str(compare.get("nickname", "")).to_lower() != str(rec.get("nickname", "")).to_lower():
			var diff := int(rec["tiempo_ms"]) - int(compare["tiempo_ms"])
			var who := "tu record" if compare.get("nickname") == _me else str(compare["nickname"])
			var text := ("%s s mas rapido que %s" % [_seconds(-diff), who]) if diff < 0 else ("%s s mas lento que %s" % [_seconds(diff), who])
			_fact(box, "Comparacion", text, Color(0.55, 1, 0.6) if diff < 0 else Color(1, 0.6, 0.5))
		_fact(box, "En el record", "%d/%d estrellas  -  %d caidas  -  %d corazones  -  %d Super salto" % [
			int(rec["estrellas"]), int(rec["estrellas_total"]), int(rec["caidas"]), int(rec["corazones"]), int(rec["poderes"])])
	_fact(box, "Intentos", "%d  (%d completados, %d%%)" % [attempts, wins, roundi(100.0 * wins / maxi(attempts, 1))])
	if lvl.get("primera_victoria") != null:
		_fact(box, "Primera vez completado", "en el intento #%d" % int(lvl["primera_victoria"]))
	if attempts > 0:
		_fact(box, "Caidas por intento", "%.1f" % (float(lvl.get("caidas", 0)) / attempts))
	return box


func _fact(parent: Container, label: String, value: String, color: Color = Color.WHITE) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", -2)
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", SECONDARY_TEXT)
	row.add_child(l)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 18)
	v.add_theme_color_override("font_color", color)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(v)
	parent.add_child(row)


func _stat_tile(label: String, value: String) -> Control:
	var tile := PanelContainer.new()
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.06)
	style.set_corner_radius_all(10)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	tile.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", -2)
	tile.add_child(box)
	var l := Label.new()
	l.text = label
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", SECONDARY_TEXT)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.clip_text = true
	box.add_child(l)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 24)
	box.add_child(v)
	return tile


# Avatar: la inicial del nickname en un circulo del color de su liga.
func _avatar(nickname: String, color: Color) -> Control:
	var avatar := PanelContainer.new()
	avatar.custom_minimum_size = Vector2(64, 64)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var circle := StyleBoxFlat.new()
	circle.bg_color = Color(color, 0.3)
	circle.border_color = color
	circle.set_border_width_all(3)
	circle.set_corner_radius_all(32)
	avatar.add_theme_stylebox_override("panel", circle)
	var initial := Label.new()
	initial.text = nickname.substr(0, 1).to_upper()
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	initial.add_theme_font_size_override("font_size", 34)
	avatar.add_child(initial)
	return avatar


func _is_me(row: Dictionary) -> bool:
	return _me != "" and str(row.get("nickname", "")).to_lower() == _me.to_lower()


func _row_color(row: Dictionary) -> Color:
	return ME_TEXT if _is_me(row) else Color(1, 1, 1, 1)


func _podium_color(puesto: int, fallback: Color) -> Color:
	return PODIUM_COLORS[puesto - 1] if puesto >= 1 and puesto <= PODIUM_COLORS.size() else fallback


func _add_cell(grid: GridContainer, text: String, color: Color, font_size: int, expand: bool = false) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 4)
	if expand:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.custom_minimum_size.x = 90
	grid.add_child(label)


static func _clear_grid(grid: Container) -> void:
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()


# La pestana activa se ve como boton dorado; las demas, azules.
static func _style_tabs(buttons: Array, selected: String) -> void:
	for button in buttons:
		button.theme_type_variation = &"" if button.get_meta("tab") == selected else &"SecondaryButton"


# --- Animaciones de la interfaz ----------------------------------------------

# Las ventanas entran creciendo desde el centro con un pequeno rebote.
func _pop_in(panel: Control) -> void:
	panel.pivot_offset = panel.size * 0.5
	panel.scale = Vector2(0.85, 0.85)
	panel.modulate.a = 0.0
	var tween := create_tween().set_parallel()
	tween.tween_property(panel, "scale", Vector2.ONE, 0.32) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(panel, "modulate:a", 1.0, 0.18)


func _fade_in(control: Control) -> void:
	control.modulate.a = 0.0
	create_tween().tween_property(control, "modulate:a", 1.0, 0.35)


# Fondo oscuro detras de pausa y victoria: separa la ventana del juego.
func _show_dim(on: bool) -> void:
	if on == _dim.visible:
		return
	_dim.visible = on
	if on:
		_fade_in(_dim)


# El titulo respira y se balancea despacio mientras el menu esta abierto.
func _start_title_bob() -> void:
	if _title_tween != null and _title_tween.is_valid():
		_title_tween.kill()
	# El VBox recoloca al titulo, pero no toca escala ni giro: se anima eso.
	await get_tree().process_frame
	_title.pivot_offset = _title.size * 0.5
	_title_tween = create_tween().set_loops()
	_title_tween.tween_property(_title, "scale", Vector2(1.04, 1.04), 1.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_title_tween.parallel().tween_property(_title, "rotation", deg_to_rad(1.5), 1.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_title_tween.tween_property(_title, "scale", Vector2.ONE, 1.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_title_tween.parallel().tween_property(_title, "rotation", deg_to_rad(-1.5), 1.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# Los botones crecen un poco con el raton encima o con el foco del teclado,
# y se encogen al pulsarlos.
func _add_button_juice(button: Button) -> void:
	button.mouse_entered.connect(_scale_button.bind(button, 1.06))
	button.focus_entered.connect(_scale_button.bind(button, 1.06))
	button.mouse_exited.connect(_on_button_released.bind(button))
	button.focus_exited.connect(_on_button_released.bind(button))
	button.button_down.connect(_scale_button.bind(button, 0.96))
	button.button_up.connect(_on_button_released.bind(button))


func _on_button_released(button: Button) -> void:
	var over := button.get_global_rect().has_point(button.get_global_mouse_position())
	_scale_button(button, 1.06 if over or button.has_focus() else 1.0)


func _scale_button(button: Button, target: float) -> void:
	if not is_instance_valid(button):
		return
	var old: Tween = _button_tweens.get(button)
	if old != null and old.is_valid():
		old.kill()
	button.pivot_offset = button.size * 0.5
	var tween := create_tween()
	tween.tween_property(button, "scale", Vector2(target, target), 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_button_tweens[button] = tween
