# Persistencia en SQLite: jugadores, intentos por nivel y la tabla de records.
#
# Usa la extension godot-sqlite (res://addons/godot-sqlite). La clase SQLite
# se crea con ClassDB y se llama de forma dinamica: si la extension no carga
# (otra plataforma, binario ausente), el juego sigue funcionando y la tabla
# de records se muestra como no disponible en lugar de romper el script.
#
# Modelo de datos:
#   jugadores  - un nickname por fila (sin distinguir mayusculas).
#   intentos   - cada partida de un nivel, termine como termine: completado,
#                sin vidas, sin tiempo (contrarreloj) o abandonado. "numero" es el n-esimo intento del
#                jugador en ese nivel, asi el record sabe cuantos intentos
#                costo conseguirlo.
#   v_records  - vista con el mejor intento completado (el mas rapido) de cada
#                jugador en cada nivel.
#   sesiones   - cada vez que se juega con un nickname desde que se abre el
#                juego. Agrupa los intentos para medir cuanto se reintenta.
#   muertes    - cada caida: donde fue, por que (agua o vacio) y en que
#                segundo del intento. Sirve para ver que zonas matan mas.
#
# Sesiones, muertes, checkpoints, tiempo par y punto final de cada intento no
# se muestran en el juego: los usan tools/leaderboard.py (orden "analisis") y
# el panel de tools/dashboard.py.
extends RefCounted

const DB_PATH := "user://aventura.db"
const SCHEMA_VERSION := 3

## Puntos de medalla por nivel; la liga sale de la fraccion del maximo.
const MEDAL_POINTS := {"Oro": 3, "Plata": 2, "Bronce": 1}
## [liga, fraccion minima del maximo de puntos], de mayor a menor.
const LEAGUES := [["Diamante", 1.0], ["Oro", 0.7], ["Plata", 0.4], ["Bronce", 0.01], ["Sin liga", 0.0]]

const RESULT_COMPLETED := "completado"
const RESULT_NO_LIVES := "sin_vidas"
const RESULT_ABANDONED := "abandonado"
const RESULT_NO_TIME := "sin_tiempo"

const NICK_MIN := 2
const NICK_MAX := 16

const SCHEMA := [
	"""CREATE TABLE IF NOT EXISTS jugadores (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		nickname TEXT NOT NULL UNIQUE COLLATE NOCASE,
		creado TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
	)""",
	"""CREATE TABLE IF NOT EXISTS intentos (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		jugador_id INTEGER NOT NULL REFERENCES jugadores(id) ON DELETE CASCADE,
		nivel INTEGER NOT NULL,
		nivel_nombre TEXT NOT NULL,
		numero INTEGER NOT NULL,
		resultado TEXT NOT NULL CHECK (resultado IN ('completado', 'sin_vidas', 'sin_tiempo', 'abandonado')),
		tiempo_ms INTEGER NOT NULL,
		estrellas INTEGER NOT NULL DEFAULT 0,
		estrellas_total INTEGER NOT NULL DEFAULT 0,
		gema INTEGER NOT NULL DEFAULT 0,
		corazones INTEGER NOT NULL DEFAULT 0,
		poderes INTEGER NOT NULL DEFAULT 0,
		caidas INTEGER NOT NULL DEFAULT 0,
		vidas_restantes INTEGER NOT NULL DEFAULT 0,
		medalla TEXT,
		fecha TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
	)""",
	"""CREATE TABLE IF NOT EXISTS sesiones (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		jugador_id INTEGER NOT NULL REFERENCES jugadores(id) ON DELETE CASCADE,
		inicio TEXT NOT NULL DEFAULT (datetime('now', 'localtime')),
		fin TEXT
	)""",
	"""CREATE TABLE IF NOT EXISTS muertes (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		intento_id INTEGER NOT NULL REFERENCES intentos(id) ON DELETE CASCADE,
		nivel INTEGER NOT NULL,
		causa TEXT NOT NULL,
		x REAL NOT NULL,
		y REAL NOT NULL,
		z REAL NOT NULL,
		tiempo_ms INTEGER NOT NULL
	)""",
	"CREATE INDEX IF NOT EXISTS idx_muertes_nivel ON muertes(nivel)",
	"CREATE INDEX IF NOT EXISTS idx_intentos_jugador ON intentos(jugador_id, nivel)",
	"CREATE INDEX IF NOT EXISTS idx_intentos_record ON intentos(nivel, resultado, tiempo_ms)",
	"""CREATE VIEW IF NOT EXISTS v_records AS
		SELECT * FROM (
			SELECT i.*, j.nickname,
				ROW_NUMBER() OVER (
					PARTITION BY i.jugador_id, i.nivel
					ORDER BY i.tiempo_ms ASC, i.estrellas DESC, i.id ASC
				) AS orden,
				(SELECT COUNT(*) FROM intentos x
					WHERE x.jugador_id = i.jugador_id AND x.nivel = i.nivel) AS intentos_totales
			FROM intentos i
			JOIN jugadores j ON j.id = i.jugador_id
			WHERE i.resultado = 'completado'
		) WHERE orden = 1""",
]

# Columnas de intentos anadidas en la v3. Se crean con ALTER TABLE si faltan:
# los records ya guardados se conservan.
const INTENTOS_EXTRA := {
	"sesion_id": "INTEGER",
	"par_ms": "INTEGER",
	"checkpoints": "INTEGER NOT NULL DEFAULT 0",
	"fin_x": "REAL",
	"fin_y": "REAL",
	"fin_z": "REAL",
}

var _db: Object = null
var _available := false


# `path` solo cambia en las pruebas; el juego usa siempre DB_PATH.
func open(path: String = DB_PATH) -> bool:
	if _available:
		return true
	if not ClassDB.class_exists("SQLite"):
		push_warning("Extension SQLite no disponible: la tabla de records queda desactivada.")
		return false
	_db = ClassDB.instantiate("SQLite")
	_db.set("path", path)
	# 0 = QUIET: sin volcar cada consulta a la consola.
	_db.set("verbosity_level", 0)
	_db.set("foreign_keys", true)
	if not _db.call("open_db"):
		push_warning("No se pudo abrir la base de datos: " + path)
		_db = null
		return false
	_available = true
	_migrate()
	for statement in SCHEMA:
		_exec(statement)
	_add_columns()
	_exec("PRAGMA user_version = %d" % SCHEMA_VERSION)
	return true


# v1 -> v2: el CHECK de "resultado" no admitia 'sin_tiempo'. SQLite no deja
# cambiar un CHECK, asi que se rehace la tabla copiando los datos. La vista
# depende de la tabla: se borra y SCHEMA la vuelve a crear.
func _migrate() -> void:
	var rows := _query("PRAGMA user_version")
	var version := int(rows[0].values()[0]) if not rows.is_empty() else 0
	var has_table := not _query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'intentos'").is_empty()
	if not has_table or version >= 2:
		return
	_exec("BEGIN")
	_exec("DROP VIEW IF EXISTS v_records")
	_exec("ALTER TABLE intentos RENAME TO intentos_v1")
	_exec(SCHEMA[1])
	_exec("INSERT INTO intentos SELECT * FROM intentos_v1")
	_exec("DROP TABLE intentos_v1")
	_exec("COMMIT")


# v2 -> v3: columnas nuevas de intentos. Se mira la tabla y no user_version,
# porque es lo unico fiable si la base la toco otra copia del juego.
func _add_columns() -> void:
	var have := {}
	for col in _query("PRAGMA table_info(intentos)"):
		have[str(col["name"])] = true
	for column in INTENTOS_EXTRA.keys():
		if not have.has(column):
			_exec("ALTER TABLE intentos ADD COLUMN %s %s" % [column, INTENTOS_EXTRA[column]])


func close() -> void:
	if _db != null:
		_db.call("close_db")
	_db = null
	_available = false


func is_available() -> bool:
	return _available


func file_path() -> String:
	return ProjectSettings.globalize_path(DB_PATH)


# --- Jugadores ---------------------------------------------------------------

# Quita espacios sobrantes y deja solo letras, numeros, espacio, _ y -.
static func clean_nickname(raw: String) -> String:
	var allowed := RegEx.new()
	allowed.compile("[^\\p{L}\\p{N} _\\-]")
	var text := allowed.sub(raw.strip_edges(), "", true)
	while text.contains("  "):
		text = text.replace("  ", " ")
	return text.substr(0, NICK_MAX)


static func is_valid_nickname(nickname: String) -> bool:
	return nickname.length() >= NICK_MIN and nickname.length() <= NICK_MAX


# Devuelve el id del jugador, creandolo si es nuevo. -1 si no hay base.
func ensure_player(nickname: String) -> int:
	if not _available:
		return -1
	_query("INSERT OR IGNORE INTO jugadores (nickname) VALUES (?)", [nickname])
	_flush()
	var rows := _query("SELECT id FROM jugadores WHERE nickname = ?", [nickname])
	if rows.is_empty():
		return -1
	return int(rows[0]["id"])


# --- Sesiones ----------------------------------------------------------------

# Abre una sesion para el jugador. Devuelve su id, o -1 sin base.
func begin_session(player_id: int) -> int:
	if not _available or player_id < 0:
		return -1
	if not _exec_bound("INSERT INTO sesiones (jugador_id) VALUES (?)", [player_id]):
		return -1
	var id := int(_db.get("last_insert_rowid"))
	_flush()
	return id


func end_session(session_id: int) -> void:
	if _available and session_id >= 0:
		_exec_bound("UPDATE sesiones SET fin = datetime('now', 'localtime') WHERE id = ?", [session_id])
		_flush()


# --- Intentos ----------------------------------------------------------------

# Guarda un intento terminado. `run` lleva las claves de la tabla intentos
# (nivel, nivel_nombre, resultado, tiempo_ms, estrellas, ...), "fin"
# (Vector3 donde acabo) y "muertes": lista de {causa, pos, tiempo_ms}.
# Devuelve el numero de intento asignado, o 0 si no se pudo guardar.
func record_attempt(player_id: int, run: Dictionary) -> int:
	if not _available or player_id < 0:
		return 0
	var nivel := int(run.get("nivel", 1))
	var prev := _query("SELECT COUNT(*) AS n FROM intentos WHERE jugador_id = ? AND nivel = ?", [player_id, nivel])
	var numero := (int(prev[0]["n"]) if not prev.is_empty() else 0) + 1
	var end_pos: Vector3 = run.get("fin", Vector3.ZERO)
	var ok := _exec_bound(
		"""INSERT INTO intentos (jugador_id, nivel, nivel_nombre, numero, resultado,
			tiempo_ms, estrellas, estrellas_total, gema, corazones, poderes, caidas,
			vidas_restantes, medalla, sesion_id, par_ms, checkpoints, fin_x, fin_y, fin_z)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
		[
			player_id, nivel, str(run.get("nivel_nombre", "")), numero,
			str(run.get("resultado", RESULT_ABANDONED)), int(run.get("tiempo_ms", 0)),
			int(run.get("estrellas", 0)), int(run.get("estrellas_total", 0)),
			1 if run.get("gema", false) else 0, int(run.get("corazones", 0)),
			int(run.get("poderes", 0)), int(run.get("caidas", 0)),
			int(run.get("vidas_restantes", 0)), run.get("medalla", null),
			run.get("sesion_id", null), run.get("par_ms", null), int(run.get("checkpoints", 0)),
			end_pos.x, end_pos.y, end_pos.z,
		])
	if ok:
		var attempt_id := int(_db.get("last_insert_rowid"))
		for death in run.get("muertes", []):
			var pos: Vector3 = death.get("pos", Vector3.ZERO)
			_exec_bound("INSERT INTO muertes (intento_id, nivel, causa, x, y, z, tiempo_ms) VALUES (?, ?, ?, ?, ?, ?, ?)",
				[attempt_id, nivel, str(death.get("causa", "")), pos.x, pos.y, pos.z, int(death.get("tiempo_ms", 0))])
	_flush()
	return numero if ok else 0


# En la version web, user:// vive en memoria y Godot lo copia a IndexedDB
# solo despues de cerrar un archivo escrito con FileAccess. SQLite escribe por
# su cuenta y eso no dispara la copia: sin esto, al recargar la pagina se
# perdian los intentos. Tras cada guardado se escribe un archivo minimo; al
# cerrarlo, Godot programa la copia de todo user://, base incluida.
const SYNC_PATH := "user://.sync"


func _flush() -> void:
	if _db == null or not OS.has_feature("web"):
		return
	var marker := FileAccess.open(SYNC_PATH, FileAccess.WRITE)
	if marker != null:
		marker.store_string(str(Time.get_unix_time_from_system()))
		marker.close()


# Mejor intento completado de un jugador en un nivel. Vacio si no hay.
func personal_best(player_id: int, nivel: int) -> Dictionary:
	var rows := _query("SELECT * FROM v_records WHERE jugador_id = ? AND nivel = ?", [player_id, nivel])
	return rows[0] if not rows.is_empty() else {}


# Puesto (1 = primero) del record del jugador en el nivel, y cuantos records hay.
func rank_of(nivel: int, player_id: int) -> Dictionary:
	var rows := _query(
		"""SELECT puesto, (SELECT COUNT(*) FROM v_records WHERE nivel = ?1) AS total
		FROM (%s) WHERE jugador_id = ?2""" % _ranked_sql("tiempo"),
		[nivel, player_id])
	return rows[0] if not rows.is_empty() else {}


# El record justo por encima del jugador en el nivel: el siguiente a batir.
# Vacio si es el primero o aun no tiene record.
func rival_above(nivel: int, player_id: int) -> Dictionary:
	var rows := _query(
		"""WITH r AS (%s)
		SELECT r.nickname, r.tiempo_ms, r.puesto FROM r
		JOIN r me ON me.jugador_id = ?2 AND r.puesto = me.puesto - 1""" % _ranked_sql("tiempo"),
		[nivel, player_id])
	return rows[0] if not rows.is_empty() else {}


# --- Consultas de la tabla ---------------------------------------------------

# Records de un nivel con su puesto real. sort_by: "tiempo" (por defecto) o
# "estrellas". Al buscar un nickname cada fila conserva el puesto de la tabla
# entera, no el de la busqueda.
func level_board(nivel: int, sort_by: String = "tiempo", filter: String = "", limit: int = 50) -> Array:
	return _query(
		"SELECT * FROM (%s) WHERE nickname LIKE ?2 ORDER BY puesto LIMIT ?3" % _ranked_sql(sort_by),
		[nivel, "%" + filter + "%", limit])


# Vista de proximidad: el jugador en el centro y `radius` rivales por encima y
# por debajo. Vacio si el jugador no tiene record en el nivel.
func level_board_around(nivel: int, player_id: int, sort_by: String = "tiempo", radius: int = 4) -> Array:
	return _query(
		"""WITH r AS (%s)
		SELECT r.* FROM r JOIN r me ON me.jugador_id = ?2
		WHERE r.puesto BETWEEN me.puesto - ?3 AND me.puesto + ?3
		ORDER BY r.puesto""" % _ranked_sql(sort_by),
		[nivel, player_id, radius])


func _ranked_sql(sort_by: String) -> String:
	var order := "tiempo_ms ASC, estrellas DESC, id ASC"
	if sort_by == "estrellas":
		order = "estrellas DESC, gema DESC, tiempo_ms ASC, id ASC"
	return """SELECT jugador_id, nickname, tiempo_ms, numero, intentos_totales, estrellas,
			estrellas_total, gema, corazones, poderes, caidas, vidas_restantes, medalla, fecha,
			ROW_NUMBER() OVER (ORDER BY %s) AS puesto
		FROM v_records WHERE nivel = ?1""" % order


# Resumen por jugador de todos los niveles: niveles completados, suma de sus
# mejores tiempos, estrellas, gemas, intentos y puntos de medalla (la liga).
func general_board(filter: String = "", limit: int = 50) -> Array:
	return _query(
		"SELECT * FROM (%s) WHERE nickname LIKE ? ORDER BY puesto LIMIT ?" % _general_sql(),
		["%" + filter + "%", limit])


func general_board_around(player_id: int, radius: int = 4) -> Array:
	return _query(
		"""WITH r AS (%s)
		SELECT r.* FROM r JOIN r me ON me.jugador_id = ?
		WHERE r.puesto BETWEEN me.puesto - ? AND me.puesto + ?
		ORDER BY r.puesto""" % _general_sql(),
		[player_id, radius, radius])


func player_count() -> int:
	var rows := _query("SELECT COUNT(DISTINCT jugador_id) AS n FROM intentos")
	return int(rows[0]["n"]) if not rows.is_empty() else 0


func _general_sql() -> String:
	return """WITH mejor AS (
			SELECT jugador_id, nivel, MIN(tiempo_ms) AS t, MAX(estrellas) AS e, MAX(gema) AS g
			FROM intentos WHERE resultado = 'completado'
			GROUP BY jugador_id, nivel
		), medallas AS (
			SELECT jugador_id, SUM(CASE medalla WHEN 'Oro' THEN 3 WHEN 'Plata' THEN 2
				WHEN 'Bronce' THEN 1 ELSE 0 END) AS puntos
			FROM v_records GROUP BY jugador_id
		), total AS (
			SELECT jugador_id, COUNT(*) AS n, SUM(caidas) AS c, SUM(tiempo_ms) AS jugado
			FROM intentos GROUP BY jugador_id
		), base AS (
			SELECT j.id AS jugador_id, j.nickname,
				COUNT(m.nivel) AS niveles,
				COALESCE(SUM(m.t), 0) AS tiempo_ms,
				COALESCE(SUM(m.e), 0) AS estrellas,
				COALESCE(SUM(m.g), 0) AS gemas,
				COALESCE(md.puntos, 0) AS puntos,
				t.n AS intentos, t.c AS caidas, t.jugado AS jugado_ms
			FROM jugadores j
			JOIN total t ON t.jugador_id = j.id
			LEFT JOIN mejor m ON m.jugador_id = j.id
			LEFT JOIN medallas md ON md.jugador_id = j.id
			GROUP BY j.id
		)
		SELECT *, ROW_NUMBER() OVER (
			ORDER BY puntos DESC, niveles DESC, estrellas DESC, gemas DESC, tiempo_ms ASC
		) AS puesto FROM base"""


# --- Estadisticas de un jugador ----------------------------------------------

# Todo lo que muestra la pantalla de estadisticas de un jugador:
#   id, nickname, creado
#   intentos, completados, caidas, jugado_ms, sesiones   (totales)
#   puesto, puntos, jugadores                            (tabla general)
#   records: {nivel: fila de v_records + puesto y de}    (su mejor marca)
#   niveles: {nivel: {intentos, completados, caidas, primera_victoria}}
#   series:  {nivel: [{numero, resultado, tiempo_ms, estrellas, caidas, medalla}]}
# Vacio si el nickname no existe.
func player_profile(nickname: String) -> Dictionary:
	var found := _query("SELECT id, nickname, creado FROM jugadores WHERE nickname = ?", [nickname])
	if found.is_empty():
		return {}
	var profile: Dictionary = found[0]
	var player_id := int(profile["id"])
	var totals := _query(
		"""SELECT COUNT(*) AS intentos,
			COALESCE(SUM(resultado = 'completado'), 0) AS completados,
			COALESCE(SUM(caidas), 0) AS caidas,
			COALESCE(SUM(tiempo_ms), 0) AS jugado_ms,
			(SELECT COUNT(*) FROM sesiones s WHERE s.jugador_id = ?1) AS sesiones
		FROM intentos WHERE jugador_id = ?1""", [player_id])
	if not totals.is_empty():
		profile.merge(totals[0])
	var general := _query("SELECT puesto, puntos FROM (%s) WHERE jugador_id = ?" % _general_sql(), [player_id])
	profile["puesto"] = general[0]["puesto"] if not general.is_empty() else 0
	profile["puntos"] = general[0]["puntos"] if not general.is_empty() else 0
	profile["jugadores"] = player_count()

	var records := {}
	for row in _query("SELECT * FROM v_records WHERE jugador_id = ?", [player_id]):
		var rank := rank_of(int(row["nivel"]), player_id)
		row["puesto"] = rank.get("puesto", 0)
		row["de"] = rank.get("total", 0)
		records[int(row["nivel"])] = row
	profile["records"] = records

	var levels := {}
	for row in _query(
			"""SELECT nivel, COUNT(*) AS intentos,
				SUM(resultado = 'completado') AS completados,
				SUM(caidas) AS caidas,
				MIN(CASE WHEN resultado = 'completado' THEN numero END) AS primera_victoria
			FROM intentos WHERE jugador_id = ? GROUP BY nivel""", [player_id]):
		levels[int(row["nivel"])] = row
	profile["niveles"] = levels

	var series := {}
	for row in _query(
			"""SELECT nivel, numero, resultado, tiempo_ms, estrellas, caidas, medalla
			FROM intentos WHERE jugador_id = ? ORDER BY nivel, numero""", [player_id]):
		var nivel := int(row["nivel"])
		if not series.has(nivel):
			series[nivel] = []
		series[nivel].append(row)
	profile["series"] = series
	return profile


# Liga segun los puntos de medalla sobre el maximo posible (3 por nivel).
static func league_for(points: int, max_points: int) -> String:
	if points <= 0 or max_points <= 0:
		return "Sin liga"
	var ratio := float(points) / float(max_points)
	for league in LEAGUES:
		if ratio >= float(league[1]):
			return league[0]
	return "Sin liga"


# Siguiente liga por encima: [nombre, puntos que hacen falta]. Vacio en la maxima.
static func next_league(points: int, max_points: int) -> Array:
	var next: Array = []
	for league in LEAGUES:
		var needed := maxi(1, ceili(float(league[1]) * max_points))
		if float(league[1]) > 0.0 and needed > points:
			next = [league[0], needed]
	return next


# Ultimos intentos de un jugador, de cualquier resultado.
func history(nickname: String, limit: int = 40) -> Array:
	return _query(
		"""SELECT i.nivel, i.nivel_nombre, i.numero, i.resultado, i.tiempo_ms, i.estrellas,
			i.estrellas_total, i.gema, i.corazones, i.caidas, i.medalla, i.fecha
		FROM intentos i JOIN jugadores j ON j.id = i.jugador_id
		WHERE j.nickname = ?
		ORDER BY i.id DESC LIMIT ?""",
		[nickname, limit])


# Mejor marca del jugador en cada nivel, indexada por nivel (1..n).
func player_records(nickname: String) -> Dictionary:
	var out := {}
	for row in _query("SELECT * FROM v_records WHERE nickname = ?", [nickname]):
		out[int(row["nivel"])] = row
	return out


# --- Utilidades --------------------------------------------------------------

# 83456 ms -> "1:23.45"
static func format_time(ms: int) -> String:
	var total := maxi(ms, 0)
	var minutes := total / 60000
	var seconds := (total / 1000) % 60
	var hundredths := (total % 1000) / 10
	return "%d:%02d.%02d" % [minutes, seconds, hundredths]


func _exec(sql: String) -> bool:
	if _db == null:
		return false
	var ok: bool = _db.call("query", sql)
	if not ok:
		push_warning("SQLite: " + str(_db.get("error_message")))
	return ok


func _exec_bound(sql: String, bindings: Array) -> bool:
	if _db == null:
		return false
	var ok: bool = _db.call("query_with_bindings", sql, bindings)
	if not ok:
		push_warning("SQLite: " + str(_db.get("error_message")))
	return ok


func _query(sql: String, bindings: Array = []) -> Array:
	if not _exec_bound(sql, bindings):
		return []
	var result: Variant = _db.get("query_result")
	return (result as Array).duplicate() if result is Array else []
