# Jugador: movimiento relativo a la camara, salto con coyote time y buffer,
# animacion del caballero de KayKit, Super salto temporal, resortes y la
# caida al mar (chapoteo y hundimiento antes de perder la vida).
#
# El movimiento va sobre el CharacterBody3D; el modelo va dentro de un nodo
# "MeshRoot" con un giro extra para que mire hacia el -Z del cuerpo (el
# "adelante" de Godot).
extends CharacterBody3D

signal died
## Ha tocado el agua: empieza a hundirse. `surface` es el punto del chapoteo.
signal splashed(surface: Vector3)

const MESH_PATH := "res://assets/KayKit_Adventurers_2.0_FREE/Characters/gltf/Knight.glb"
const ANIM_LIBS := [
	"res://assets/KayKit_Adventurers_2.0_FREE/Animations/gltf/Rig_Medium/Rig_Medium_MovementBasic.glb",
	"res://assets/KayKit_Adventurers_2.0_FREE/Animations/gltf/Rig_Medium/Rig_Medium_General.glb",
]

# Pisadas: intervalo en segundos entre pasos, y velocidad minima para sonar.
const STEP_INTERVAL := 0.34
const STEP_MIN_SPEED := 1.5

@export var speed := 7.0
## Arranque, frenada y control en el aire por separado: con una sola
## aceleracion el personaje arranca y para en seco.
@export var ground_acceleration := 30.0
@export var ground_deceleration := 40.0
@export var air_acceleration := 14.0
@export var jump_velocity := 10.0
@export var gravity := 20.0
@export var turn_speed := 14.0
@export var coyote_time := 0.18
@export var jump_buffer_time := 0.18
@export var fall_y := -18.0
## Altura del mar. Al cruzarla el jugador se hunde en vez de morir en seco.
@export var sea_y := -INF
## Segundos que tarda en hundirse antes de perder la vida.
@export var sink_duration := 1.6
## Velocidad final de hundimiento (m/s).
@export var sink_speed := 1.3
## Salto con el Super salto activo: ~4.5 m de altura en lugar de ~2.5 m.
@export var boost_jump_velocity := 13.5
## Velocidad maxima con Turbo (plataformas flecha del contrarreloj).
@export var turbo_speed := 12.5
## El modelo se gira para mirar hacia -Z, el "adelante" de un Node3D en Godot.
@export var mesh_yaw_offset_deg := 180.0

@export_group("Animacion")
## Velocidad (m/s) a la que los clips de andar y correr se ven a ritmo 1.0.
## Si los pies patinan, ajustar estos valores.
@export var walk_anim_speed := 3.0
@export var run_anim_speed := 6.5
## Inclinacion hacia dentro de la curva al girar, y hacia delante al acelerar.
@export var lean_amount := 0.05
@export var max_lean_deg := 14.0
@export var tilt_amount := 0.004
@export var max_tilt_deg := 7.0
## Estiramiento al saltar y aplastamiento maximo al aterrizar.
@export var jump_stretch := 1.18
@export var max_land_squash := 0.28

var spawn_point := Vector3.ZERO

var _yaw: Node3D = null
var _mesh_root: Node3D = null
var _mesh: Node3D = null
var _anim: AnimationPlayer = null
var _current_clip := ""
# Clips resueltos por nombre al arrancar (vacio = no existe en el pack).
var _clip_idle := ""
var _clip_walk := ""
var _clip_run := ""
var _clip_jump := ""
var _clip_jump_start := ""
var _clip_jump_air := ""
var _clip_jump_land := ""
var _clip_spawn := ""
var _coyote := 0.0
var _buffer := 0.0
var _dead := false
var _step_timer := 0.0
var _was_on_floor := true
var _running := false
# Un clip de una sola pasada (aterrizar, reaparecer) que la locomocion no
# debe pisar mientras dure, salvo que el jugador se mueva.
var _lock_time := 0.0
var _lean := 0.0
var _tilt := 0.0
var _squash := 1.0
var _last_horizontal := 0.0
var _dust: CPUParticles3D = null
var _clip_death := ""
var _sinking := false
var _sink_time := 0.0
var _splash: CPUParticles3D = null
var _bubbles: CPUParticles3D = null
## Segundos que le quedan al Super salto.
var _boost_time := 0.0
var _aura: CPUParticles3D = null
## Lanzado por un resorte: soltar el salto no corta el impulso.
var _launched := false
## Segundos que le quedan al Turbo.
var _turbo_time := 0.0
var _turbo_trail: CPUParticles3D = null


func _ready() -> void:
	add_to_group("player")
	# La camara cuelga de la raiz del nivel, no del jugador: si fuera hija,
	# cada giro del personaje arrastraria la camara.
	_yaw = get_node_or_null("../CameraYaw")
	spawn_point = global_position
	_build_visual()


func _physics_process(delta: float) -> void:
	if _dead:
		return
	if _sinking:
		_update_sink(delta)
		return

	if _boost_time > 0.0:
		_boost_time = maxf(0.0, _boost_time - delta)
		if _boost_time <= 0.0 and _aura != null:
			_aura.emitting = false
	if _turbo_time > 0.0:
		_turbo_time = maxf(0.0, _turbo_time - delta)
		if _turbo_time <= 0.0 and _turbo_trail != null:
			_turbo_trail.emitting = false

	var on_floor := is_on_floor()

	if on_floor:
		_coyote = coyote_time
	else:
		_coyote = maxf(0.0, _coyote - delta)

	var jump_just_pressed := Input.is_action_just_pressed("jump_primary") or Input.is_action_just_pressed("jump")
	if jump_just_pressed:
		_buffer = jump_buffer_time
	else:
		_buffer = maxf(0.0, _buffer - delta)

	# Direccion deseada, relativa al yaw de la camara (plano XZ).
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var basis := _yaw.global_transform.basis if _yaw != null else global_transform.basis
	var forward := -basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := basis.x
	right.y = 0.0
	right = right.normalized()

	var wish := right * input.x + forward * (-input.y)
	if wish.length() > 1.0:
		wish = wish.normalized()

	# Se acelera el vector XZ entero, no cada eje por separado: por ejes, las
	# diagonales se corrigen antes en un eje que en otro y el giro se ve a tirones.
	var top_speed := turbo_speed if _turbo_time > 0.0 else speed
	var target := Vector2(wish.x, wish.z) * top_speed
	var rate := air_acceleration
	if on_floor:
		rate = ground_acceleration if wish.length_squared() > 0.01 else ground_deceleration
	var flat := Vector2(velocity.x, velocity.z).move_toward(target, rate * delta)
	velocity.x = flat.x
	velocity.z = flat.y

	if not on_floor:
		velocity.y -= gravity * delta

	if _buffer > 0.0 and _coyote > 0.0:
		velocity.y = boost_jump_velocity if _boost_time > 0.0 else jump_velocity
		_launched = false
		_buffer = 0.0
		_coyote = 0.0
		_play_sfx("jump", -6.0, randf_range(0.95, 1.05))
		_on_jump()

	# Salto variable: soltar el boton subiendo corta el impulso.
	var jump_just_released := Input.is_action_just_released("jump_primary") or Input.is_action_just_released("jump")
	if jump_just_released and velocity.y > 0.0 and not _launched:
		velocity.y *= 0.45

	# move_and_slide pone velocity.y a 0 al tocar suelo; la fuerza del impacto
	# se lee antes.
	var fall_speed := -velocity.y
	move_and_slide()

	on_floor = is_on_floor()
	if on_floor and not _was_on_floor:
		_launched = false
		_on_land(fall_speed)
		# Input buffering: ejecucion inmediata al hacer contacto con el suelo
		if _buffer > 0.0:
			velocity.y = boost_jump_velocity if _boost_time > 0.0 else jump_velocity
			_buffer = 0.0
			_coyote = 0.0
			_play_sfx("jump", -6.0, randf_range(0.95, 1.05))
			_on_jump()
	_was_on_floor = on_floor

	_face_movement(delta)
	_update_animation(delta, on_floor)
	_update_body_motion(delta, on_floor)
	_update_footsteps(delta)

	if global_position.y < sea_y:
		_start_sink()
	elif global_position.y < fall_y:
		_die()


func _face_movement(delta: float) -> void:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if flat.length() < 0.5:
		return
	var target_yaw := atan2(-flat.x, -flat.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, 1.0 - exp(-turn_speed * delta))


# --- Super salto y resortes -------------------------------------------------

## Activa el Super salto durante `seconds`. Si ya estaba activo, se renueva.
func apply_boost(seconds: float) -> void:
	_boost_time = maxf(_boost_time, seconds)
	if _aura != null:
		_aura.emitting = true


func get_boost_time() -> float:
	return _boost_time


## Lo llama una plataforma Turbo: impulso inmediato en `direction` y mas
## velocidad maxima durante `seconds`.
func apply_turbo(seconds: float, direction: Vector3) -> bool:
	if _dead or _sinking:
		return false
	_turbo_time = seconds
	if direction.length_squared() > 0.01:
		var push := direction.normalized() * turbo_speed
		velocity.x = push.x
		velocity.z = push.z
	if _turbo_trail != null:
		_turbo_trail.emitting = true
	_squash = 0.85
	return true


func get_turbo_time() -> float:
	return _turbo_time


## Lo llama un resorte. Devuelve false si el jugador no puede salir lanzado.
func launch(speed_up: float) -> bool:
	if _dead or _sinking:
		return false
	velocity.y = speed_up
	_launched = true
	_coyote = 0.0
	_buffer = 0.0
	_was_on_floor = false
	_squash = jump_stretch * 1.1
	_burst_dust()
	if _clip_jump_start != "":
		_play_clip(_clip_jump_start, 0.05)
	return true


# --- Peso del cuerpo ---------------------------------------------------------

func _on_jump() -> void:
	_squash = jump_stretch
	_burst_dust()
	if _clip_jump_start != "":
		_play_clip(_clip_jump_start, 0.08)


func _on_land(fall_speed: float) -> void:
	if fall_speed < 3.0:
		return
	var strength := clampf(fall_speed / 30.0, 0.0, 1.0)
	_squash = 1.0 - lerpf(0.06, max_land_squash, strength)
	_burst_dust()
	_play_sfx("land", lerpf(-14.0, -3.0, strength), randf_range(0.9, 1.1))
	if _yaw != null and _yaw.has_method("add_impact"):
		_yaw.call("add_impact", fall_speed)
	# Parado, se ve el clip de aterrizaje; en carrera se pasa directo a correr
	# y el aplastamiento basta para dar el peso.
	var horizontal := Vector2(velocity.x, velocity.z).length()
	if _clip_jump_land != "" and horizontal < 1.5:
		_play_clip(_clip_jump_land, 0.05)
		_lock_time = 0.3


# Inclinacion hacia la curva, cabeceo al acelerar y frenar, y el squash &
# stretch. Todo se aplica al MeshRoot, asi la colision no cambia.
func _update_body_motion(delta: float, on_floor: bool) -> void:
	if _mesh_root == null:
		return

	var horizontal := Vector2(velocity.x, velocity.z).length()
	var speed_factor := clampf(horizontal / speed, 0.0, 1.0)

	# Velocidad de giro real del cuerpo en este paso.
	var yaw_rate := 0.0
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if flat.length() >= 0.5:
		var target_yaw := atan2(-flat.x, -flat.z)
		yaw_rate = wrapf(target_yaw - rotation.y, -PI, PI) * turn_speed
	var max_lean := deg_to_rad(max_lean_deg)
	var lean_target := clampf(-yaw_rate * lean_amount * speed_factor, -max_lean, max_lean)

	var accel := (horizontal - _last_horizontal) / maxf(delta, 0.0001)
	_last_horizontal = horizontal
	var max_tilt := deg_to_rad(max_tilt_deg)
	var tilt_target := 0.0
	if on_floor:
		tilt_target = clampf(accel * tilt_amount, -max_tilt, max_tilt)

	var k := 1.0 - exp(-10.0 * delta)
	_lean = lerpf(_lean, lean_target, k)
	_tilt = lerpf(_tilt, tilt_target, 1.0 - exp(-8.0 * delta))
	_squash = lerpf(_squash, 1.0, 1.0 - exp(-12.0 * delta))

	# El MeshRoot esta girado 180 grados: su +Z es el "adelante" del cuerpo,
	# asi que rotation.z negativa inclina hacia la izquierda y rotation.x
	# positiva hacia delante.
	_mesh_root.rotation.x = _tilt
	_mesh_root.rotation.z = _lean
	var side := 1.0 / sqrt(_squash)
	_mesh_root.scale = Vector3(side, _squash, side)


func _reset_body_motion() -> void:
	_lean = 0.0
	_tilt = 0.0
	_squash = 1.0
	_last_horizontal = 0.0
	if _mesh_root != null:
		_mesh_root.rotation.x = 0.0
		_mesh_root.rotation.z = 0.0
		_mesh_root.scale = Vector3.ONE


# Nube de polvo a los pies, al saltar y al aterrizar.
func _build_dust() -> void:
	_dust = CPUParticles3D.new()
	_dust.name = "Dust"
	_dust.emitting = false
	_dust.one_shot = true
	_dust.amount = 14
	_dust.lifetime = 0.55
	_dust.explosiveness = 0.95
	# En coordenadas globales: el polvo se queda donde salio.
	_dust.local_coords = false
	_dust.position.y = 0.05
	_dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_dust.emission_ring_axis = Vector3.UP
	_dust.emission_ring_radius = 0.4
	_dust.emission_ring_inner_radius = 0.2
	_dust.emission_ring_height = 0.05
	_dust.direction = Vector3.UP
	_dust.spread = 75.0
	_dust.initial_velocity_min = 0.8
	_dust.initial_velocity_max = 2.2
	_dust.gravity = Vector3(0.0, -1.5, 0.0)
	_dust.damping_min = 2.0
	_dust.damping_max = 3.0
	_dust.scale_amount_min = 0.6
	_dust.scale_amount_max = 1.1

	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.0))
	_dust.scale_amount_curve = shrink

	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.8))
	fade.set_color(1, Color(1, 1, 1, 0.0))
	_dust.color_ramp = fade

	var puff := SphereMesh.new()
	puff.radius = 0.12
	puff.height = 0.24
	puff.radial_segments = 8
	puff.rings = 4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.95, 0.92, 0.85)
	puff.material = mat
	_dust.mesh = puff

	add_child(_dust)


func _burst_dust() -> void:
	if _dust != null:
		_dust.restart()


# Particulas de agua y del Super salto. Todas en coordenadas globales: el
# chapoteo se queda en la superficie aunque el jugador siga bajando.
func _build_water_fx() -> void:
	_splash = _make_particles("Splash", 42, 0.9, 0.09, Color(0.92, 0.97, 1.0, 0.95))
	_splash.one_shot = true
	_splash.explosiveness = 0.95
	_splash.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_splash.emission_ring_axis = Vector3.UP
	_splash.emission_ring_radius = 0.6
	_splash.emission_ring_inner_radius = 0.25
	_splash.emission_ring_height = 0.05
	_splash.direction = Vector3.UP
	_splash.spread = 32.0
	_splash.initial_velocity_min = 4.0
	_splash.initial_velocity_max = 8.5
	_splash.gravity = Vector3(0.0, -16.0, 0.0)

	_bubbles = _make_particles("Bubbles", 18, 0.8, 0.06, Color(0.75, 0.92, 1.0, 0.75))
	_bubbles.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_bubbles.emission_sphere_radius = 0.35
	_bubbles.position.y = 1.2
	_bubbles.direction = Vector3.UP
	_bubbles.spread = 20.0
	_bubbles.initial_velocity_min = 0.4
	_bubbles.initial_velocity_max = 1.0
	_bubbles.gravity = Vector3(0.0, 2.5, 0.0)

	_turbo_trail = _make_particles("TurboTrail", 40, 0.45, 0.1, Color(1, 0.62, 0.2, 0.9))
	_turbo_trail.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_turbo_trail.emission_sphere_radius = 0.3
	_turbo_trail.position.y = 0.5
	_turbo_trail.direction = Vector3.UP
	_turbo_trail.spread = 25.0
	_turbo_trail.initial_velocity_min = 0.2
	_turbo_trail.initial_velocity_max = 0.8
	_turbo_trail.gravity = Vector3.ZERO

	_aura = _make_particles("BoostAura", 24, 0.7, 0.07, Color(0.75, 1.0, 0.4, 0.9))
	_aura.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_aura.emission_sphere_radius = 0.55
	_aura.position.y = 0.8
	_aura.direction = Vector3.UP
	_aura.spread = 60.0
	_aura.initial_velocity_min = 0.3
	_aura.initial_velocity_max = 1.0
	_aura.gravity = Vector3(0.0, 1.2, 0.0)


func _make_particles(node_name: String, amount: int, life: float, radius: float, color: Color) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = node_name
	p.emitting = false
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.2))
	p.scale_amount_curve = shrink
	var fade := Gradient.new()
	fade.set_color(0, color)
	fade.set_color(1, Color(color.r, color.g, color.b, 0.0))
	p.color_ramp = fade

	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	p.mesh = mesh
	add_child(p)
	return p


# --- Sonido ------------------------------------------------------------------

# El Main es dueno del pool de audio; el jugador solo se lo pide.
func _play_sfx(sound_name: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	var main := get_parent()
	if main != null and main.has_method("play_sfx"):
		main.call("play_sfx", sound_name, volume_db, pitch)


# Pisadas ritmicas: solo en el suelo y con velocidad suficiente. Al parar se
# reinicia, asi que la primera pisada suena enseguida y no se acumula el ritmo.
func _update_footsteps(delta: float) -> void:
	var horizontal := Vector2(velocity.x, velocity.z).length()
	if not is_on_floor() or horizontal < STEP_MIN_SPEED or _dead:
		_step_timer = 0.0
		return
	_step_timer -= delta
	if _step_timer <= 0.0:
		_step_timer = STEP_INTERVAL
		_play_sfx("step", -13.0, randf_range(0.92, 1.08))


# --- Muerte y reaparicion ----------------------------------------------------

# Toca el agua: chapoteo en la superficie y empieza a hundirse. El control se
# pierde, pero la vida no se descuenta hasta que termina de hundirse.
func _start_sink() -> void:
	if _sinking or _dead:
		return
	_sinking = true
	_sink_time = 0.0
	_boost_time = 0.0
	_turbo_time = 0.0
	if _turbo_trail != null:
		_turbo_trail.emitting = false
	if _aura != null:
		_aura.emitting = false
	# El agua frena en seco la caida; queda solo un poco de la inercia.
	velocity = Vector3(velocity.x * 0.25, clampf(velocity.y * 0.12, -4.0, -1.0), velocity.z * 0.25)
	var surface := Vector3(global_position.x, sea_y, global_position.z)
	if _splash != null:
		_splash.global_position = surface
		_splash.restart()
	if _bubbles != null:
		_bubbles.emitting = true
	if _clip_death != "":
		_play_clip(_clip_death, 0.12)
		_anim.speed_scale = 0.75
	splashed.emit(surface)


# Baja despacio, se frena en horizontal y se balancea como si flotara.
func _update_sink(delta: float) -> void:
	_sink_time += delta
	var k := 1.0 - exp(-3.0 * delta)
	velocity.x = lerpf(velocity.x, 0.0, k)
	velocity.z = lerpf(velocity.z, 0.0, k)
	velocity.y = move_toward(velocity.y, -sink_speed, 6.0 * delta)
	global_position += velocity * delta
	if _mesh_root != null:
		_mesh_root.rotation.z = sin(_sink_time * 2.6) * 0.2
		_mesh_root.rotation.x = lerpf(_mesh_root.rotation.x, 0.4, k)
		_mesh_root.scale = _mesh_root.scale.lerp(Vector3.ONE, k)
	if _sink_time >= sink_duration:
		if _bubbles != null:
			_bubbles.emitting = false
		_die()


func is_sinking() -> bool:
	return _sinking


func _die() -> void:
	if _dead:
		return
	_dead = true
	velocity = Vector3.ZERO
	died.emit()


func respawn(pos: Vector3) -> void:
	teleport(pos)
	if _clip_spawn != "":
		_play_clip(_clip_spawn, 0.05)
		_lock_time = 0.6
	elif _clip_idle != "":
		_play_clip(_clip_idle, 0.1)


func teleport(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	_dead = false
	_sinking = false
	_launched = false
	_boost_time = 0.0
	_turbo_time = 0.0
	if _aura != null:
		_aura.emitting = false
	if _turbo_trail != null:
		_turbo_trail.emitting = false
	if _bubbles != null:
		_bubbles.emitting = false
	_was_on_floor = true
	_running = false
	_lock_time = 0.0
	_reset_body_motion()
	# La camara sigue al jugador con retardo: tras un salto de posicion se
	# coloca de golpe para no cruzar el nivel volando.
	if _yaw != null and _yaw.has_method("snap_to_target"):
		_yaw.call("snap_to_target")


# --- Modelo y animacion ------------------------------------------------------

func _build_visual() -> void:
	_mesh_root = Node3D.new()
	_mesh_root.name = "MeshRoot"
	_mesh_root.rotation.y = deg_to_rad(mesh_yaw_offset_deg)
	add_child(_mesh_root)

	var scene := load(MESH_PATH)
	if scene is PackedScene:
		_mesh = scene.instantiate()
		_mesh.name = "Character"
		_mesh_root.add_child(_mesh)
	else:
		push_warning("No se pudo cargar el personaje: " + MESH_PATH)
		_add_placeholder()

	_anim = _find_animation_player(_mesh_root)
	if _anim == null:
		_anim = AnimationPlayer.new()
		_anim.name = "AnimationPlayer"
		_mesh_root.add_child(_anim)
		if _mesh != null:
			_anim.root_node = _anim.get_path_to(_mesh)

	for path in ANIM_LIBS:
		_add_animation_library(path)

	_resolve_clips()
	_build_dust()
	_build_water_fx()


func _add_placeholder() -> void:
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.7
	body.mesh = capsule
	body.position.y = 0.85
	_mesh_root.add_child(body)


static func _find_animation_player(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	if root is AnimationPlayer:
		return root
	for child in root.find_children("*", "AnimationPlayer", true, false):
		return child
	return null


# Los GLB que solo contienen animaciones se importan como AnimationLibrary y
# se pueden enganchar directamente al AnimationPlayer del personaje.
func _add_animation_library(path: String) -> void:
	if _anim == null or not ResourceLoader.exists(path):
		push_warning("No se pudo cargar animaciones: " + path)
		return

	var res: Resource = load(path)
	var source := _animation_library_from(res)
	if source == null:
		push_warning("Formato de animacion no soportado: " + path)
		return

	# Los clips se duplican en una libreria nueva: el recurso importado esta en
	# cache y lo comparten otros nodos, asi que no se modifica en sitio.
	# La locomocion va en bucle; saltos, aterrizajes y demas, de una pasada.
	var library := AnimationLibrary.new()
	for anim_name in source.get_animation_list():
		var clip: Animation = source.get_animation(anim_name).duplicate()
		clip.loop_mode = Animation.LOOP_LINEAR if _is_loop_clip(anim_name) else Animation.LOOP_NONE
		library.add_animation(anim_name, clip)

	if library.get_animation_list().is_empty():
		return

	_fix_track_paths(library)
	_anim.add_animation_library(path.get_file().get_basename(), library)


# Acepta tanto una AnimationLibrary importada como una escena temporal.
static func _animation_library_from(res: Resource) -> AnimationLibrary:
	if res == null:
		return null
	if res is AnimationLibrary:
		return res
	if res is PackedScene:
		var temp: Node = res.instantiate()
		var temp_player := _find_animation_player(temp)
		if temp_player == null:
			temp.queue_free()
			return null
		var library := AnimationLibrary.new()
		for anim_name in temp_player.get_animation_list():
			library.add_animation(anim_name, temp_player.get_animation(anim_name))
		temp.queue_free()
		return library
	return null


# Si las pistas empiezan por un nodo que no existe bajo el personaje, se quita
# ese primer segmento para que las animaciones apunten al esqueleto real.
func _fix_track_paths(library: AnimationLibrary) -> void:
	if _anim == null:
		return
	var root := _anim.get_node_or_null(_anim.root_node)
	if root == null:
		root = _mesh_root

	for anim_name in library.get_animation_list():
		var animation := library.get_animation(anim_name)
		if animation == null:
			continue
		for i in animation.get_track_count():
			var track_path := String(animation.track_get_path(i))
			var head := track_path.split(":")[0]
			if root.get_node_or_null(NodePath(head)) != null:
				continue
			var dot := head.find("/")
			if dot < 0:
				continue
			var stripped := track_path.substr(dot + 1)
			if root.get_node_or_null(NodePath(stripped.split(":")[0])) != null:
				animation.track_set_path(i, NodePath(stripped))


func _resolve_clips() -> void:
	if _anim == null:
		return
	var names := _anim.get_animation_list()
	_clip_idle = _pick_clip(names, ["idle", "idle_a", "idle_alt"])
	_clip_walk = _pick_clip(names, ["walking_a", "walking", "walk", "walk_a"])
	_clip_run = _pick_clip(names, ["running_a", "running", "run", "run_a"])
	_clip_jump = _pick_clip(names, ["jump_full_short", "jump_full", "jumping", "jump", "jump_a"])
	_clip_jump_start = _pick_clip(names, ["jump_start"])
	_clip_jump_air = _pick_clip(names, ["jump_idle"])
	_clip_jump_land = _pick_clip(names, ["jump_land"])
	_clip_spawn = _pick_clip(names, ["spawn_ground"])
	_clip_death = _pick_clip(names, ["death_a"])
	# Sin el trio inicio / aire / aterrizaje se usa el salto completo.
	if _clip_jump_air == "":
		_clip_jump_air = _clip_jump

	if _clip_idle != "":
		_play_clip(_clip_idle, 0.0)


static func _is_loop_clip(anim_name: String) -> bool:
	var lower := anim_name.to_lower()
	return lower.contains("idle") or lower.contains("walking") or lower.contains("running")


# Busca por nombre exacto, luego por prefijo, luego por contenido. Se compara
# solo el nombre del clip, sin el prefijo "Libreria/" del AnimationPlayer.
static func _pick_clip(names: PackedStringArray, wanted: Array) -> String:
	for want in wanted:
		for clip_name in names:
			if clip_name.get_file().to_lower() == want:
				return clip_name
	for want in wanted:
		for clip_name in names:
			if clip_name.get_file().to_lower().begins_with(str(want)):
				return clip_name
	for want in wanted:
		for clip_name in names:
			if clip_name.get_file().to_lower().contains(str(want)):
				return clip_name
	return ""


func _play_clip(clip: String, blend: float) -> void:
	if _anim == null or clip == "" or not _anim.has_animation(clip):
		return
	var same := _anim.current_animation == clip
	_current_clip = clip
	_anim.speed_scale = 1.0
	_anim.play(clip, blend)
	# play() no reinicia un clip que ya suena; un segundo salto o aterrizaje
	# seguido tiene que empezar desde el principio.
	if same:
		_anim.seek(0.0, true)


func _update_animation(delta: float, on_floor: bool) -> void:
	if _anim == null or _current_clip == "":
		return

	var horizontal := Vector2(velocity.x, velocity.z).length()

	# Clip de una pasada en curso: se respeta salvo que el jugador eche a
	# andar o se caiga.
	if _lock_time > 0.0:
		_lock_time -= delta
		if on_floor and horizontal < 1.5 and _anim.is_playing():
			return
		_lock_time = 0.0

	if not on_floor:
		# El impulso del salto se ve hasta que termina o empieza la caida;
		# despues, la pose en el aire en bucle.
		var starting := _current_clip == _clip_jump_start and _anim.is_playing()
		if starting and velocity.y > 0.0:
			return
		if _clip_jump_air != "" and _current_clip != _clip_jump_air:
			_play_clip(_clip_jump_air, 0.15)
		return

	# Histeresis entre andar y correr: sin ella, a velocidades intermedias el
	# clip salta de uno a otro cada pocos frames.
	if _running:
		_running = horizontal > speed * 0.5
	else:
		_running = horizontal > speed * 0.62

	var want := _clip_idle
	var rate := 1.0
	if _running and _clip_run != "":
		want = _clip_run
		rate = clampf(horizontal / run_anim_speed, 0.8, 1.3)
	elif horizontal > 0.6 and _clip_walk != "":
		want = _clip_walk
		rate = clampf(horizontal / walk_anim_speed, 0.6, 1.5)

	if want != "" and want != _current_clip:
		var blend := 0.2
		# Al venir del aire la mezcla es corta para que se note el apoyo.
		if _current_clip == _clip_jump_air or _current_clip == _clip_jump_start:
			blend = 0.1
		_play_clip(want, blend)

	# Ritmo de pasos ajustado a la velocidad real: los pies no patinan.
	_anim.speed_scale = rate
