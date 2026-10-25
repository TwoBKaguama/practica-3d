# Raiz del juego: carga los tres niveles, lleva el progreso y controla el raton.
#
# Tambien lleva cada intento (tiempo, estrellas, gema, caidas...) y lo guarda
# en la base SQLite al terminar, ya sea en la meta, sin vidas o abandonado.
# Ademas registra en segundo plano datos para analizar el diseno: la sesion,
# donde y por que cae el jugador y donde deja el intento.
#
# Contrarreloj (niveles 4 y 5): cuenta atras con "3, 2, 1, YA", aros que dan
# segundos, marea que sube mientras corre el reloj y que se traga al jugador
# al llegar a 0. La prisa se refuerza con tic-tac, musica acelerada, bordes
# rojos que laten y, en la tormenta, lluvia y relampagos.
#
# Unico responsable del modo del raton: lo captura al empezar y lo libera con
# Escape (y con raton). Sin eso, el jugador no podria salir de la ventana.
extends Node3D

const LevelBuilderScript := preload("res://scripts/level_builder.gd")
const SceneryScript := preload("res://scripts/scenery.gd")
const DbScript := preload("res://scripts/leaderboard_db.gd")
const LevelDataScript := preload("res://scripts/level_data.gd")

const START_LIVES := 3
## Los corazones pueden subir las vidas hasta aqui.
const MAX_LIVES := 5
## Duracion del Super salto al recoger el objeto.
const POWER_SECONDS := 12.0
## Un intento abandonado mas corto que esto no se guarda (p. ej. pulsar R
## nada mas aparecer).
const MIN_ATTEMPT_SECONDS := 1.0

## Cuanto sube la marea (m) entre el inicio y el final de la cuenta atras.
const TIDE_MAX_RISE := 5.0
## Por debajo de estos segundos empieza el tic-tac y la musica se acelera.
const HURRY_SECONDS := 10.0
const HURRY_MUSIC_PITCH := 1.12

# Nodos del mundo que deben congelarse de verdad cuando el arbol se pausa.
# La raiz NO esta en esta lista: procesa siempre, porque es el unico nodo que
# escucha Escape.
const WORLD_PAUSABLE_PATHS: Array[String] = ["Player", "LevelRoot", "CameraYaw", "Clouds"]

# Efectos de sonido y su archivo. Generados para este juego y guardados en
# res://assets/audio/ con nombres estables.
const SOUND_PATHS := {
	"jump": "res://assets/audio/sfx_jump.wav",
	"step": "res://assets/audio/sfx_step.wav",
	"star": "res://assets/audio/sfx_star.wav",
	"checkpoint": "res://assets/audio/sfx_checkpoint.wav",
	"death": "res://assets/audio/sfx_death.wav",
	"level_complete": "res://assets/audio/sfx_level_complete.wav",
	"splash": "res://assets/audio/sfx_splash.wav",
	"spring": "res://assets/audio/sfx_spring.wav",
	"heart": "res://assets/audio/sfx_heart.wav",
	"gem": "res://assets/audio/sfx_gem.wav",
	"power": "res://assets/audio/sfx_powerup.wav",
	"tick": "res://assets/audio/sfx_tick.wav",
	"count": "res://assets/audio/sfx_count.wav",
	"go": "res://assets/audio/sfx_go.wav",
	"time": "res://assets/audio/sfx_time.wav",
	"boost": "res://assets/audio/sfx_boost.wav",
	"crumble": "res://assets/audio/sfx_crumble.wav",
	"timeout": "res://assets/audio/sfx_timeout.wav",
	"thunder": "res://assets/audio/sfx_thunder.wav",
	"land": "res://assets/audio/sfx_land.wav",
	"hurt": "res://assets/audio/sfx_hurt.wav",
}
## Cuantos sonidos pueden sonar a la vez.
const SFX_POOL_SIZE := 6

# Musica de fondo: una sola pista en bucle, creada una vez en _ready().
# NO se toca en _start_level(), que se ejecuta en cada cambio de nivel y al
# pulsar R: recrearla ahi reiniciaria la pista en cada nivel.
const MUSIC_PATH := "res://assets/audio/music_theme.mp3"
## Por debajo de los efectos: la musica es fondo, no protagonista.
const MUSIC_VOLUME_DB := -16.0

# Record de estrellas por nivel, guardado entre partidas. Solo cuenta al
# llegar a la meta: una partida abandonada a medias no deja record.
const PROGRESS_PATH := "user://progreso.cfg"

@export var levels: Array[String] = [
	"res://scenes/levels/level_01.tscn",
	"res://scenes/levels/level_02.tscn",
	"res://scenes/levels/level_03.tscn",
	"res://scenes/levels/level_04.tscn",
	"res://scenes/levels/level_05.tscn",
]

# Sin tipo estatico a proposito: player.gd y hud.gd no exponen class_name,
# asi que tiparlos aqui impediria llamar a sus metodos propios.
@onready var _player = $Player
@onready var _hud = $HUD
@onready var _level_root: Node3D = $LevelRoot

var _level_index := 0
var _lives := START_LIVES
var _stars := 0
var _star_total := 0
var _spawn_point := Vector3.ZERO
var _fall_y := -18.0
var _paused := false
## La pantalla de inicio esta abierta: el juego espera a que se pulse Iniciar.
var _in_menu := false
## Cambia en cada arranque de nivel y al volver al menu. Las esperas de
## muerte y meta lo comparan al despertar para no actuar sobre una partida
## que ya no existe (por ejemplo, si se reinicio o se volvio al menu).
var _run_id := 0
## El panel de felicitaciones esta abierto tras llegar a la meta.
var _win_open := false
var _busy := false
var _level_name := ""
var _level_data: Dictionary = {}
var _game_finished := false
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_streams: Dictionary = {}
var _music_player: AudioStreamPlayer = null
## Mejor numero de estrellas por indice de nivel.
var _best_stars: Dictionary = {}

var _db = DbScript.new()
var _nickname := ""
var _player_id := -1
## Hay un intento en curso que se guardara al terminar.
var _attempt_active := false
## El cronometro avanza (se para en la meta y con el juego en pausa).
var _timer_running := false
var _attempt_time := 0.0
var _deaths := 0
var _gem_found := false
var _gem_total := 0
var _hearts_taken := 0
var _powers_taken := 0
var _checkpoints_taken := 0
## Caidas del intento en curso: {causa, pos, tiempo_ms}. Se guardan con el intento.
var _death_log: Array = []
var _session_id := -1
var _star_combo := 0
var _star_combo_time := 0.0

# --- Contrarreloj ---
var _trial := false
var _time_left := 0.0
var _time_limit := 0.0
var _timed_out := false
var _last_tick := -1
var _base_sea_y := -17.0
## Metros que ha subido la marea sobre su altura normal.
var _tide_rise := 0.0
var _tide_node: Node3D = null
var _surge_tween: Tween = null
# Tormenta: relampagos cada pocos segundos.
var _storm := false
var _storm_timer := 0.0
var _storm_sun := 1.0
var _storm_ambient := 1.0
## El raton estuvo capturado jugando: si se suelta (Esc en la web, cambio de
## ventana) se pausa el juego.
var _was_captured := false


func _ready() -> void:
	# La raiz sigue procesando aunque el arbol este en pausa. Con el modo por
	# defecto tambien se pausaba a si misma, asi que al pulsar Escape no
	# quedaba nadie escuchando las teclas: la pausa era una trampa sin salida.
	process_mode = Node.PROCESS_MODE_ALWAYS
	for world_path in WORLD_PAUSABLE_PATHS:
		var world_node: Node = get_node_or_null(world_path)
		if world_node != null:
			world_node.process_mode = Node.PROCESS_MODE_PAUSABLE

	# El raton no se captura aqui: se arranca en el menu, y en la web el
	# navegador solo deja capturarlo tras un clic del jugador.
	# Al cerrar la ventana se guarda antes el intento en curso.
	get_tree().auto_accept_quit = false
	_db.open()
	_build_audio()
	# Una sola vez en toda la partida: la musica sobrevive a los cambios de nivel.
	_build_music()
	_hud.set_level_tabs(_level_tabs(), levels.size(), LevelDataScript.CAMPAIGN_LEVELS)
	_player.died.connect(_on_player_died)
	_player.splashed.connect(_on_player_splashed)
	_player.fall_y = -18.0
	_hud.start_pressed.connect(_on_start_pressed)
	_hud.level_selected.connect(_on_level_selected)
	_load_progress()
	_hud.set_nickname(_nickname)
	_hud.quit_pressed.connect(_quit_game)
	_hud.board_query.connect(_on_board_query)
	_hud.profile_requested.connect(_on_profile_requested)
	_hud.pause_pressed.connect(_set_paused.bind(true))
	_hud.resume_pressed.connect(_set_paused.bind(false))
	_hud.restart_pressed.connect(_on_restart_pressed)
	_hud.menu_pressed.connect(_show_start_screen)
	_hud.next_pressed.connect(_on_next_pressed)
	# El primer nivel se construye de fondo y queda congelado tras el menu. Con
	# _in_menu activo no cuenta como intento.
	_in_menu = true
	_start_level(0)
	_show_start_screen()


func _process(delta: float) -> void:
	var running := not get_tree().paused
	if _timer_running and running:
		_attempt_time += delta
		_hud.set_time(int(_attempt_time * 1000.0))
		if _trial:
			_tick_countdown(delta)
	_hud.set_power(_player.get_boost_time() if not _in_menu else 0.0)
	var camera := get_node_or_null("CameraYaw")
	if camera != null:
		camera.call("set_speed_fx", running and not _in_menu and _player.get_turbo_time() > 0.0)
	if _trial and running:
		_update_tide(delta)
	if _storm and running:
		_storm_timer -= delta
		if _storm_timer <= 0.0:
			_storm_timer = randf_range(4.0, 9.0)
			_lightning()
	if _star_combo > 0 and running:
		_star_combo_time -= delta
		if _star_combo_time <= 0.0:
			_star_combo = 0
	_watch_mouse_capture()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit_game()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_pause_if_playing()


func _pause_if_playing() -> void:
	if not _in_menu and not _win_open and not _paused:
		_set_paused(true)


# En la web, Esc suelta el puntero y el navegador se queda la tecla: el
# juego no la ve. Si el raton deja de estar capturado mientras se juega, se
# pausa para que el jugador no pierda el control.
func _watch_mouse_capture() -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _was_captured and not captured:
		_pause_if_playing()
	_was_captured = captured and not _in_menu and not _win_open and not _paused


func _quit_game() -> void:
	_end_attempt(DbScript.RESULT_ABANDONED)
	_db.end_session(_session_id)
	_db.close()
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if _in_menu or _win_open:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		_set_paused(not _paused)
	elif event.is_action_pressed("restart_level") and not _busy:
		# Tras terminar el juego, R arranca de nuevo desde el primer nivel.
		_start_level(0 if _game_finished else _level_index)


# --- Carga de nivel ----------------------------------------------------------

func _start_level(index: int) -> void:
	# Reiniciar o cambiar de nivel a medias cuenta como intento abandonado.
	_end_attempt(DbScript.RESULT_ABANDONED)
	_run_id += 1
	_win_open = false
	_hud.hide_win()
	_level_index = clampi(index, 0, levels.size() - 1)

	_level_data = _read_level_data(_level_index)
	if _level_data.is_empty():
		return

	# El nombre visible lo pone el propio nivel ("Prado Verde"), no el archivo.
	_level_name = str(_level_data.get("name", levels[_level_index].get_file().get_basename()))

	var info: Dictionary = LevelBuilderScript.build(_level_root, _level_data)
	SceneryScript.apply_environment(self, _level_data)

	_trial = LevelDataScript.is_trial(_level_data)
	_time_limit = float(_level_data.get("time_limit", 0.0))
	_time_left = _time_limit
	_timed_out = false
	_last_tick = -1
	_tide_rise = 0.0
	if _surge_tween != null and _surge_tween.is_valid():
		_surge_tween.kill()
	_tide_node = _level_root.get_node_or_null("Scenery/Tide")
	var theme := SceneryScript.theme_of(_level_data)
	_storm = bool(theme.get("storm", false))
	_storm_timer = randf_range(2.0, 4.0)
	_storm_sun = float(theme["sun_energy"])
	_storm_ambient = float(theme["ambient_energy"])
	if _music_player != null:
		_music_player.pitch_scale = 1.0

	_spawn_point = info.get("spawn", Vector3(0, 2, 0))
	_fall_y = info.get("fall_y", -18.0)
	_star_total = info.get("star_total", 0)
	_gem_total = info.get("gem_total", 0)

	_player.fall_y = _fall_y
	var sea_y: float = _fall_y + SceneryScript.SEA_ABOVE_FALL_Y
	_player.sea_y = sea_y
	_base_sea_y = sea_y
	var camera := get_node_or_null("CameraYaw")
	if camera != null:
		camera.set("water_y", sea_y)
		camera.call("set_rain", _storm)
	_player.teleport(_spawn_point)
	# El brazo de camara resuelve su colision en el siguiente paso de fisica,
	# asi que no se fuerza aqui ninguna posicion.

	# Conecta los objetos interactivos del nivel recien construido.
	# Recursivo a proposito: la meta es un Area3D anidado dentro del nodo
	# "Goal" (que lleva el cartel colgando), asi que buscarla solo entre los
	# hijos directos dejaba la meta sin conectar y el nivel no avanzaba nunca.
	for node in _level_root.find_children("*", "", true, false):
		if node.has_signal("collected"):
			node.collected.connect(_on_pickup_collected)
		if node.has_signal("bounced"):
			node.bounced.connect(func(_n: Node) -> void:
				_camera_trauma(0.3)
				play_sfx("spring", -3.0, randf_range(0.95, 1.05)))
		if node.has_signal("boosted"):
			node.boosted.connect(func(_n: Node) -> void:
				_camera_trauma(0.25)
				play_sfx("boost", -2.0, randf_range(0.95, 1.05)))
		if node.has_signal("crumbled"):
			node.crumbled.connect(func(_n: Node) -> void:
				_camera_trauma(0.2)
				play_sfx("crumble", -6.0, randf_range(0.95, 1.05)))

	_lives = START_LIVES
	_stars = 0
	_star_combo = 0
	_star_combo_time = 0.0
	_deaths = 0
	_gem_found = false
	_hearts_taken = 0
	_powers_taken = 0
	_checkpoints_taken = 0
	_death_log.clear()
	_attempt_time = 0.0
	_attempt_active = not _in_menu
	_timer_running = _attempt_active
	_busy = false
	_game_finished = false
	# La celebracion congela al jugador; aqui se le devuelve el control.
	_player.set_physics_process(true)
	_set_paused(false)

	if _trial:
		var trial_number := _level_index - LevelDataScript.CAMPAIGN_LEVELS + 1
		_hud.set_level(trial_number, levels.size() - LevelDataScript.CAMPAIGN_LEVELS, _level_name, "Contrarreloj")
	else:
		_hud.set_level(_level_index + 1, LevelDataScript.CAMPAIGN_LEVELS, _level_name)
	_hud.set_trial_mode(_trial)
	_hud.set_countdown(_time_left, _time_limit)
	_hud.set_stars(_stars, _star_total)
	_hud.set_lives(_lives, START_LIVES)
	_hud.set_gem(false)
	_hud.set_time(0)
	_hud.set_underwater(false)
	_hud.set_hint("WASD mover  -  Espacio saltar  -  Raton camara  -  R reiniciar  -  P / Esc pausa")
	if _trial:
		if _attempt_active:
			_trial_intro()
	else:
		_hud.show_message("Nivel %d: %s" % [_level_index + 1, _level_name], 2.0)


# "3, 2, 1, YA": el jugador espera congelado y el reloj no corre hasta el YA.
func _trial_intro() -> void:
	var run := _run_id
	_timer_running = false
	_busy = true
	_player.set_physics_process(false)
	_hud.show_message("¡Llega a la meta antes de que suba la marea!", 2.4)
	await get_tree().create_timer(0.5, false).timeout
	for n in [3, 2, 1]:
		if run != _run_id:
			return
		_hud.show_banner(str(n), 0.25)
		play_sfx("count")
		await get_tree().create_timer(0.65, false).timeout
	if run != _run_id:
		return
	_hud.show_banner("¡YA!", 0.4)
	play_sfx("go")
	_player.set_physics_process(true)
	_busy = false
	_timer_running = true


# Lee los datos de un nivel sin construirlo. Vacio si algo falla.
func _read_level_data(index: int) -> Dictionary:
	var scene := load(levels[index]) as PackedScene
	if scene == null:
		push_error("No se pudo cargar el nivel: " + levels[index])
		return {}

	# Se instancia una copia solo para leer sus datos y se libera enseguida.
	var data: Dictionary = {}
	var probe: Node = scene.instantiate()
	for level_node in probe.get_children():
		if level_node.has_method("get_level_data"):
			data = level_node.get_level_data()
			break
	probe.free()

	if data.is_empty():
		push_error("El nivel no expone datos: " + levels[index])
	return data


# Botones del menu de inicio: nombre, dificultad y record de estrellas.
# Con la base de datos, el record es el del nickname actual; sin ella, el
# record de estrellas guardado en progreso.cfg.
func _refresh_level_choices() -> void:
	var records: Dictionary = _db.player_records(_nickname) if _db.is_available() and _nickname != "" else {}
	var choices: Array = []
	for i in levels.size():
		var data := _read_level_data(i)
		var total: int = data.get("stars", []).size()
		var record := "Sin completar"
		if records.has(i + 1):
			var r: Dictionary = records[i + 1]
			record = "%s  -  %d/%d%s" % [DbScript.format_time(int(r["tiempo_ms"])), int(r["estrellas"]), int(r["estrellas_total"]), "  +gema" if int(r["gema"]) == 1 else ""]
		elif not _db.is_available() and int(_best_stars.get(i, -1)) >= 0:
			record = "Estrellas %d / %d" % [int(_best_stars[i]), total]
		var trial := LevelDataScript.is_trial(data)
		if trial:
			record = record.replace("  +gema", "")
		choices.append({
			"name": data.get("name", "Nivel %d" % (i + 1)),
			"difficulty": "%d s de reloj" % int(data.get("time_limit", 0)) if trial else data.get("difficulty", ""),
			"record": record,
			"trial": trial,
		})
	_hud.set_level_choices(choices)
	_refresh_welcome()


func _refresh_welcome() -> void:
	if not _db.is_available():
		_hud.set_welcome("Sin base de datos: los records no se guardan.")
	elif _nickname == "":
		_hud.set_welcome("Escribe un nickname para registrar tus records.")
	else:
		var records: Dictionary = _db.player_records(_nickname)
		_hud.set_welcome("Hola, %s. Has completado %d de %d niveles." % [_nickname, records.size(), levels.size()])


# Pestanas de la tabla: N1..N3 para la aventura y R1, R2 para contrarreloj.
func _level_tabs() -> Array:
	var tabs: Array = []
	for i in levels.size():
		if i < LevelDataScript.CAMPAIGN_LEVELS:
			tabs.append([str(i + 1), "N%d" % (i + 1), "Nivel %d" % (i + 1)])
		else:
			var n := i - LevelDataScript.CAMPAIGN_LEVELS + 1
			tabs.append([str(i + 1), "R%d" % n, "Reloj %d" % n])
	return tabs


# --- Progreso guardado ---------------------------------------------------------

func _load_progress() -> void:
	_best_stars.clear()
	var config := ConfigFile.new()
	if config.load(PROGRESS_PATH) != OK:
		return
	_nickname = str(config.get_value("jugador", "nickname", ""))
	if _nickname != "":
		_player_id = _db.ensure_player(_nickname)
	for i in levels.size():
		var best := int(config.get_value("estrellas", "nivel_%d" % (i + 1), -1))
		if best >= 0:
			_best_stars[i] = best


func _save_best_stars(index: int, stars: int) -> void:
	_best_stars[index] = stars
	_save_progress()


func _save_progress() -> void:
	var config := ConfigFile.new()
	config.set_value("jugador", "nickname", _nickname)
	for i in _best_stars.keys():
		config.set_value("estrellas", "nivel_%d" % (int(i) + 1), _best_stars[i])
	var err := config.save(PROGRESS_PATH)
	if err != OK:
		push_warning("No se pudo guardar el progreso: %s" % error_string(err))


# --- Audio -------------------------------------------------------------------

# Un pool pequeno de reproductores no posicionales: dos sonidos pueden sonar a
# la vez sin cortarse, y no hace falta un nodo de audio por cada evento.
func _build_audio() -> void:
	for key in SOUND_PATHS.keys():
		var path := str(SOUND_PATHS[key])
		if not ResourceLoader.exists(path):
			push_warning("Sonido no encontrado: " + path)
			continue
		var raw: Variant = load(path)
		if raw is AudioStream:
			_sfx_streams[str(key)] = raw
		else:
			# Sin este aviso un fallo de importacion se saltaba en silencio y el
			# juego se quedaba mudo sin ninguna pista en el registro.
			push_warning("El sonido no es un AudioStream: " + path)
	for i in SFX_POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.name = "Sfx%d" % i
		add_child(player)
		_sfx_pool.append(player)


# Toma un reproductor libre y suena. Si todos estan ocupados el efecto se
# descarta: perder un sonido es mejor que cortar el que ya esta sonando.
func play_sfx(sound_name: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if not _sfx_streams.has(sound_name):
		return
	var raw: Variant = _sfx_streams[sound_name]
	if not (raw is AudioStream):
		return
	var stream: AudioStream = raw
	for player in _sfx_pool:
		if not player.playing:
			player.stream = stream
			player.volume_db = volume_db
			player.pitch_scale = pitch
			player.play()
			return


## Aplica trauma a la camara para screenshake en momentos clave
func _camera_trauma(amount: float) -> void:
	var camera := get_node_or_null("CameraYaw")
	if camera != null and camera.has_method("add_trauma"):
		camera.call("add_trauma", amount)


# La musica vive en su propio reproductor, aparte del pool de efectos: asi los
# efectos no la cortan y ella no corta a nadie. Cuelga de Main, que procesa
# siempre, asi que sigue sonando durante la pausa sin arrancar una copia nueva.
func _build_music() -> void:
	if _music_player != null:
		return
	if not ResourceLoader.exists(MUSIC_PATH):
		push_warning("Musica no encontrada: " + MUSIC_PATH)
		return
	var raw: Variant = load(MUSIC_PATH)
	if not (raw is AudioStream):
		push_warning("La musica no es un AudioStream: " + MUSIC_PATH)
		return
	var stream: AudioStream = raw
	_set_stream_loop(stream)
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "Music"
	_music_player.stream = stream
	_music_player.volume_db = MUSIC_VOLUME_DB
	add_child(_music_player)
	_music_player.play()


# Sin bucle explicito la pista suena una vez y el juego vuelve al silencio.
# MP3 y OGG usan una propiedad "loop"; el WAV usa "loop_mode".
static func _set_stream_loop(stream: AudioStream) -> void:
	var mp3 := stream as AudioStreamMP3
	if mp3 != null:
		mp3.loop = true
		return
	var ogg := stream as AudioStreamOggVorbis
	if ogg != null:
		ogg.loop = true
		return
	var wav := stream as AudioStreamWAV
	if wav != null:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD


# --- Progreso ----------------------------------------------------------------

func _on_pickup_collected(kind: String, node: Node) -> void:
	match kind:
		"star":
			_stars += 1
			_star_combo_time = 1.8
			var pitch := 1.0 + minf(_star_combo * 0.06, 0.48)
			play_sfx("star", 0.0, pitch)
			_star_combo += 1
			_hud.set_stars(_stars, _star_total)
			_hud.pulse_stars()
			if _star_total > 0 and _stars >= _star_total:
				_hud.show_banner("TODAS LAS ESTRELLAS", 2.0)
				_camera_trauma(0.4)
		"heart":
			_hearts_taken += 1
			play_sfx("heart", 0.0, 1.05)
			if _lives < MAX_LIVES:
				_lives += 1
				_hud.set_lives(_lives, maxi(START_LIVES, _lives))
				_hud.show_message("+1 vida  (%d)" % _lives, 1.4)
			else:
				_hud.show_message("Vidas al maximo", 1.2)
		"gem":
			_gem_found = true
			play_sfx("gem", 2.0, 1.1)
			_camera_trauma(0.35)
			_hud.set_gem(true)
			_hud.show_banner("GEMA SECRETA", 1.6)
		"power":
			_powers_taken += 1
			play_sfx("power", 0.0, 1.05)
			_camera_trauma(0.25)
			_player.apply_boost(POWER_SECONDS)
			_hud.show_message("¡Super salto!  Salta mucho mas alto", 1.8)
		"time":
			play_sfx("time", 0.0, 1.05)
			_add_time(float(_level_data.get("time_bonus", 3.0)), node.global_position)
		"checkpoint":
			play_sfx("checkpoint")
			_checkpoints_taken += 1
			_spawn_point = node.global_position + Vector3(0, 0.6, 0)
			_hud.show_message("Checkpoint", 1.0)
			if _trial and not _timed_out:
				_add_time(float(_level_data.get("checkpoint_bonus", 0.0)), node.global_position + Vector3(0, 2.5, 0))
		"goal":
			_on_goal_reached()


# La meta avanza de nivel SIEMPRE: las estrellas son bonus, no un candado.
# Antes exigia las 8 estrellas y, como ademas la senal nunca llegaba, el juego
# se quedaba clavado en el nivel 1 sin ninguna pista de por que.
#
# Al llegar: rotulo de celebracion y, tras un instante, el panel de
# felicitaciones con el mundo en pausa. El jugador decide cuando seguir.
func _on_goal_reached() -> void:
	if _busy:
		return
	_busy = true

	var es_ultimo := _level_index + 1 == LevelDataScript.CAMPAIGN_LEVELS
	_timer_running = false
	if _music_player != null:
		_music_player.pitch_scale = 1.0

	# Se congela al jugador durante la celebracion para que no se caiga.
	_player.set_physics_process(false)

	if _trial:
		_hud.show_banner("¡A TIEMPO!", 1.4)
	elif es_ultimo:
		_hud.show_banner("JUEGO COMPLETADO", 1.4)
	else:
		_hud.show_banner("NIVEL %d COMPLETADO" % (_level_index + 1), 1.4)
	play_sfx("level_complete")

	# El intento se guarda ya: si durante la celebracion se vuelve al menu, el
	# record no se pierde ni se cuenta como abandonado.
	var time_ms := int(_attempt_time * 1000.0)
	var medal := _medal_for(_attempt_time)
	var detalle := "Llegaste a la meta de %s\nTiempo %s  -  Medalla de %s" % [_level_name, DbScript.format_time(time_ms), medal]
	detalle += "\nEstrellas %d / %d" % [_stars, _star_total]
	if _stars >= _star_total:
		detalle += " (todas!)"
	if _gem_total > 0:
		detalle += "  -  " + ("Gema encontrada" if _gem_found else "Gema sin encontrar")
	if _trial:
		detalle += "  -  Te sobraron %.1f s" % _time_left
	detalle += "\nCaidas: %d" % _deaths

	var prev_best: Dictionary = _db.personal_best(_player_id, _level_index + 1) if _db.is_available() else {}
	var numero := _end_attempt(DbScript.RESULT_COMPLETED, medal)
	if numero > 0:
		detalle += "  -  Intento #%d" % numero
		if prev_best.is_empty() or time_ms < int(prev_best["tiempo_ms"]):
			detalle += "\n¡Nuevo record personal!"
		else:
			detalle += "\nTu record: %s (intento #%d)" % [DbScript.format_time(int(prev_best["tiempo_ms"])), int(prev_best["numero"])]
		var rank: Dictionary = _db.rank_of(_level_index + 1, _player_id)
		if not rank.is_empty():
			detalle += "  -  Puesto #%d de %d" % [int(rank["puesto"]), int(rank["total"])]
		# El siguiente objetivo: cuanto falta para pasar al de arriba.
		var rival: Dictionary = _db.rival_above(_level_index + 1, _player_id)
		if not rival.is_empty():
			var best_ms := mini(time_ms, int(prev_best.get("tiempo_ms", time_ms)))
			detalle += "\nFaltan %.2f s para superar a %s (#%d)" % [(best_ms - int(rival["tiempo_ms"])) / 1000.0, rival["nickname"], int(rival["puesto"])]

	var record := _stars > int(_best_stars.get(_level_index, -1))
	if record:
		_save_best_stars(_level_index, _stars)

	var run := _run_id
	await get_tree().create_timer(1.6).timeout
	if run != _run_id:
		return

	if _trial:
		_hud.show_win("¡A TIEMPO!", detalle, "Reintentar")
	elif es_ultimo:
		_game_finished = true
		_hud.show_win("¡FELICIDADES!", "Completaste el juego.\n" + detalle, "Jugar de nuevo")
	else:
		_hud.show_win("¡FELICIDADES!", detalle, "Siguiente nivel")

	_win_open = true
	get_tree().paused = true
	_set_camera_look(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_next_pressed() -> void:
	# En contrarreloj se reintenta el mismo. Tras el ultimo nivel de la
	# aventura se vuelve a empezar desde el primero.
	if _trial:
		_start_level(_level_index)
	else:
		_start_level(0 if _game_finished else _level_index + 1)


func _on_player_died() -> void:
	if _busy:
		return
	_busy = true
	# El sonido de muerte suena desde aqui y no desde player.gd: la caida emite
	# la senal, asi que sonaria dos veces si estuviera en los dos sitios.
	play_sfx("death", -4.0)
	play_sfx("hurt", -2.0, randf_range(0.85, 0.95))
	_camera_trauma(0.8)
	_hud.show_damage_flash(0.6)
	_log_death()

	if _trial:
		_on_trial_fall()
		return

	_lives -= 1
	_deaths += 1
	_hud.set_lives(_lives, maxi(START_LIVES, _lives + 1))

	var run := _run_id
	if _lives <= 0:
		_hud.show_banner("SIN VIDAS", 1.2)
		_hud.show_message("Reiniciando nivel...", 1.6)
		# El intento se cierra ya, aunque la espera se interrumpa.
		_end_attempt(DbScript.RESULT_NO_LIVES)
		await get_tree().create_timer(1.6).timeout
		if run != _run_id:
			return
		_start_level(_level_index)
		return

	await get_tree().create_timer(0.7).timeout
	if run != _run_id:
		return
	_player.respawn(_spawn_point)
	_hud.set_underwater(false)
	_hud.set_lives(_lives, maxi(START_LIVES, _lives))
	_hud.show_lives_card(_lives, maxi(START_LIVES, _lives))
	_busy = false


# En contrarreloj no hay vidas: caer cuesta segundos. Si la marea se lo
# trago porque el tiempo llego a 0, el intento termina.
func _on_trial_fall() -> void:
	_deaths += 1
	var run := _run_id
	if _timed_out:
		_hud.show_message("La marea te alcanzo. Reiniciando...", 1.6)
		_end_attempt(DbScript.RESULT_NO_TIME)
		await get_tree().create_timer(1.8).timeout
		if run != _run_id:
			return
		_start_level(_level_index)
		return
	var penalty := float(_level_data.get("fall_penalty", 3.0))
	_time_left = maxf(0.0, _time_left - penalty)
	_hud.show_time_delta(-penalty)
	await get_tree().create_timer(0.5).timeout
	if run != _run_id:
		return
	_player.respawn(_spawn_point)
	_hud.set_underwater(false)
	_busy = false


# --- Contrarreloj ------------------------------------------------------------

func _tick_countdown(delta: float) -> void:
	if _timed_out:
		return
	_time_left -= delta
	if _time_left <= 0.0:
		_time_left = 0.0
		_on_time_out()
	_hud.set_countdown(_time_left, _time_limit)
	# Tic-tac en los ultimos segundos, mas fuerte al final.
	var second := ceili(_time_left)
	if _time_left <= HURRY_SECONDS and second != _last_tick and second > 0:
		_last_tick = second
		play_sfx("tick", -8.0 if second > 5 else -2.0)
	# La musica se acelera con la prisa.
	if _music_player != null:
		var urgency := clampf(1.0 - _time_left / HURRY_SECONDS, 0.0, 1.0)
		var target := lerpf(1.0, HURRY_MUSIC_PITCH, urgency)
		_music_player.pitch_scale = lerpf(_music_player.pitch_scale, target, 1.0 - exp(-3.0 * delta))


# Gana segundos: aro de tiempo o checkpoint. Texto flotante en el sitio.
func _add_time(seconds: float, where: Vector3) -> void:
	if not _trial or _timed_out or seconds <= 0.0:
		return
	_time_left += seconds
	_last_tick = -1
	_hud.show_time_delta(seconds)
	var label := Label3D.new()
	label.text = "+%d s" % roundi(seconds)
	label.font_size = 96
	label.outline_size = 24
	label.modulate = Color(0.55, 1, 0.6)
	label.outline_modulate = Color(0.05, 0.2, 0.08)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.position = where
	_level_root.add_child(label)
	var tween := label.create_tween().set_parallel()
	tween.tween_property(label, "position:y", where.y + 2.0, 1.0)
	tween.tween_property(label, "modulate:a", 0.0, 1.0).set_delay(0.3)
	tween.chain().tween_callback(label.queue_free)


# Se acabo el tiempo: la marea sube de golpe por encima del jugador y el
# hundimiento normal hace el resto.
func _on_time_out() -> void:
	_timed_out = true
	_timer_running = false
	play_sfx("timeout")
	_camera_trauma(0.85)
	_hud.show_banner("¡SE ACABO EL TIEMPO!", 1.4)
	_hud.flash(0.3)
	var target: float = _player.global_position.y - _base_sea_y + 3.0
	_surge_tween = create_tween()
	# Main procesa siempre; la subida si debe respetar la pausa.
	_surge_tween.set_pause_mode(Tween.TWEEN_PAUSE_STOP)
	_surge_tween.tween_property(self, "_tide_rise", target, 1.3) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


# La marea sigue a la cuenta atras: sube mientras se gasta el tiempo y baja
# al ganar segundos. Mueve el mar, la espuma y la altura a la que el jugador
# se hunde, y la camara sigue sin entrar en el agua.
func _update_tide(delta: float) -> void:
	if not _timed_out and _time_limit > 0.0:
		var target := TIDE_MAX_RISE * clampf(1.0 - _time_left / _time_limit, 0.0, 1.0)
		_tide_rise = lerpf(_tide_rise, target, 1.0 - exp(-2.0 * delta))
	var sea_y := _base_sea_y + _tide_rise
	if _tide_node != null:
		_tide_node.position.y = _tide_rise
	_player.sea_y = sea_y
	var camera := get_node_or_null("CameraYaw")
	if camera != null:
		camera.set("water_y", sea_y)


# Relampago: el sol y el ambiente se disparan un instante, la pantalla
# destella y el trueno llega un poco despues.
func _lightning() -> void:
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	var env_node := get_node_or_null("WorldEnvironment") as WorldEnvironment
	_hud.flash(randf_range(0.25, 0.45))
	_camera_trauma(0.6)
	if sun != null:
		var tween := create_tween()
		tween.tween_property(sun, "light_energy", 3.5, 0.04)
		tween.tween_property(sun, "light_energy", _storm_sun, 0.12)
		tween.tween_property(sun, "light_energy", 2.6, 0.05)
		tween.tween_property(sun, "light_energy", _storm_sun, 0.4)
	if env_node != null and env_node.environment != null:
		var env := env_node.environment
		var tween := create_tween()
		tween.tween_property(env, "ambient_light_energy", 2.4, 0.05)
		tween.tween_property(env, "ambient_light_energy", _storm_ambient, 0.5)
	var run := _run_id
	await get_tree().create_timer(randf_range(0.3, 0.9), false).timeout
	if run == _run_id and _storm:
		play_sfx("thunder", -3.0)


# Toca el agua: chapoteo y la pantalla se tine mientras se hunde. La vida se
# descuenta despues, en _on_player_died, cuando termina de hundirse.
func _on_player_splashed(_surface: Vector3) -> void:
	play_sfx("splash")
	play_sfx("hurt", -3.0, randf_range(0.95, 1.05))
	_camera_trauma(0.7)
	_hud.show_damage_flash(0.45)
	_hud.set_underwater(true)


# --- Intentos y tabla de records ---------------------------------------------

# Cierra el intento en curso y lo guarda. Devuelve el numero de intento del
# jugador en ese nivel, o 0 si no habia intento o no se guardo.
func _end_attempt(result: String, medal: Variant = null) -> int:
	if not _attempt_active:
		return 0
	_attempt_active = false
	_timer_running = false
	if result == DbScript.RESULT_ABANDONED and _attempt_time < MIN_ATTEMPT_SECONDS:
		return 0
	return _db.record_attempt(_player_id, {
		"nivel": _level_index + 1,
		"nivel_nombre": _level_name,
		"resultado": result,
		"tiempo_ms": int(_attempt_time * 1000.0),
		"estrellas": _stars,
		"estrellas_total": _star_total,
		"gema": _gem_found,
		"corazones": _hearts_taken,
		"poderes": _powers_taken,
		"caidas": _deaths,
		"vidas_restantes": maxi(_lives, 0),
		"medalla": medal,
		"sesion_id": _session_id if _session_id >= 0 else null,
		"par_ms": int(float(_level_data.get("par_time", 0.0)) * 1000.0),
		"checkpoints": _checkpoints_taken,
		"fin": _player.global_position,
		"muertes": _death_log.duplicate(),
	})


# Donde y por que cae: hundirse en el agua (o la marea) o caer al vacio.
func _log_death() -> void:
	if not _attempt_active:
		return
	_death_log.append({
		"causa": "agua" if _player.is_sinking() else "vacio",
		"pos": _player.global_position,
		"tiempo_ms": int(_attempt_time * 1000.0),
	})


# Oro hasta el tiempo par del nivel, plata hasta 1.5 veces, bronce despues.
func _medal_for(seconds: float) -> String:
	var par := float(_level_data.get("par_time", 60.0))
	if seconds <= par:
		return "Oro"
	if seconds <= par * 1.5:
		return "Plata"
	return "Bronce"


func _on_board_query(target: String, tab: String, sort_by: String, filter: String, view: String) -> void:
	var rows: Array = []
	var goal: Dictionary = {}
	var limit := 5 if target == "preview" else 100
	var near := view == "cerca" and _player_id >= 0
	if _db.is_available():
		if tab == "general":
			rows = _db.general_board_around(_player_id) if near else _db.general_board(filter, limit)
			var me: Array = _db.general_board_around(_player_id, 0) if _player_id >= 0 else []
			if not me.is_empty():
				goal = {"puesto": me[0]["puesto"], "total": _db.player_count(), "puntos": me[0]["puntos"]}
			if target == "preview":
				rows = _append_me(rows, me)
		elif tab == "historial":
			rows = _db.history(_nickname, 100) if _nickname != "" else []
		else:
			var nivel := int(tab)
			rows = _db.level_board_around(nivel, _player_id, sort_by) if near else _db.level_board(nivel, sort_by, filter, limit)
			goal = _level_goal(nivel)
			if target == "preview":
				rows = _append_me(rows, _db.level_board_around(nivel, _player_id, sort_by, 0) if _player_id >= 0 else [])
	if target == "preview":
		_hud.set_board_preview(tab, rows, _db.is_available())
	else:
		_hud.set_board_rows(tab, rows, _db.is_available(), _db.file_path(), goal)


# El resumen muestra los primeros; si el jugador no esta, se anade su fila.
static func _append_me(rows: Array, me: Array) -> Array:
	if me.is_empty():
		return rows
	for r in rows:
		if int(r["puesto"]) == int(me[0]["puesto"]):
			return rows
	return rows + me


# Franja de objetivo de un nivel: puesto, rival de arriba y tiempo de oro.
func _level_goal(nivel: int) -> Dictionary:
	if _player_id < 0:
		return {}
	var best: Dictionary = _db.personal_best(_player_id, nivel)
	if best.is_empty():
		return {}
	var rank: Dictionary = _db.rank_of(nivel, _player_id)
	var goal := {
		"puesto": rank.get("puesto", 0),
		"total": rank.get("total", 0),
		"tiempo_ms": best["tiempo_ms"],
		"par_ms": _par_ms(nivel),
	}
	var rival: Dictionary = _db.rival_above(nivel, _player_id)
	if not rival.is_empty():
		goal["rival"] = rival["nickname"]
		goal["rival_ms"] = rival["tiempo_ms"]
		goal["rival_puesto"] = rival["puesto"]
	return goal


# Tiempo de oro (par) de un nivel 1..n en milisegundos.
func _par_ms(nivel: int) -> int:
	if nivel < 1 or nivel > levels.size():
		return 0
	return int(float(_read_level_data(nivel - 1).get("par_time", 0.0)) * 1000.0)


# Estadisticas de un jugador, con lo necesario para comparar: el perfil del
# jugador actual, el lider de cada nivel y el tiempo de oro de cada nivel.
func _on_profile_requested(nickname: String) -> void:
	if not _db.is_available() or nickname == "":
		return
	var profile: Dictionary = _db.player_profile(nickname)
	if profile.is_empty():
		return
	var mine: Dictionary = {}
	if _nickname != "" and _nickname.to_lower() != nickname.to_lower():
		mine = _db.player_profile(_nickname)
	var leaders := {}
	var pars := {}
	for i in levels.size():
		var top: Array = _db.level_board(i + 1, "tiempo", "", 1)
		if not top.is_empty():
			leaders[i + 1] = top[0]
		pars[i + 1] = _par_ms(i + 1)
	_hud.show_profile(profile, mine, leaders, pars)


# Valida el nickname escrito en el menu y registra al jugador.
func _confirm_nickname() -> bool:
	var cleaned: String = DbScript.clean_nickname(_hud.get_nickname())
	if not DbScript.is_valid_nickname(cleaned):
		_hud.show_nick_error("El nickname debe tener entre %d y %d letras o numeros." % [DbScript.NICK_MIN, DbScript.NICK_MAX])
		return false
	if cleaned != _nickname:
		_nickname = cleaned
		_save_progress()
	var player_id: int = _db.ensure_player(_nickname)
	# Una sesion por jugador desde que se abre el juego; cambiar de nickname
	# abre otra.
	if player_id != _player_id or _session_id < 0:
		_db.end_session(_session_id)
		_session_id = _db.begin_session(player_id)
	_player_id = player_id
	_hud.set_nickname(_nickname)
	return true


# --- Pausa -------------------------------------------------------------------

func _set_paused(value: bool) -> void:
	_paused = value
	get_tree().paused = value
	_hud.set_paused(value)

	_set_camera_look(not value)

	# Con el menu abierto (nivel de fondo) el raton sigue libre.
	if value or _in_menu:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_restart_pressed() -> void:
	# Tras terminar el juego, reiniciar arranca de nuevo desde el primer nivel.
	_start_level(0 if _game_finished else _level_index)


# --- Pantalla de inicio --------------------------------------------------------

# Congela el mundo detras del menu y suelta el raton para poder pulsar botones.
func _show_start_screen() -> void:
	_end_attempt(DbScript.RESULT_ABANDONED)
	if _music_player != null:
		_music_player.pitch_scale = 1.0
	_refresh_level_choices()
	_run_id += 1
	_in_menu = true
	_win_open = false
	_paused = false
	get_tree().paused = true
	_hud.set_paused(false)
	_hud.set_start_screen(true)
	_set_camera_look(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_start_pressed() -> void:
	_on_level_selected(0)


# Partida nueva desde el nivel elegido; _start_level quita la pausa y captura
# el raton.
func _on_level_selected(index: int) -> void:
	if not _confirm_nickname():
		return
	_in_menu = false
	_hud.set_start_screen(false)
	_start_level(index)


func _set_camera_look(enabled: bool) -> void:
	var camera := get_node_or_null("CameraYaw")
	if camera != null and camera.has_method("set_look_enabled"):
		camera.set_look_enabled(enabled)
