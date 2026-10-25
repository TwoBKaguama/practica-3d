# Camara en tercera persona.
#
# Jerarquia obligatoria: CameraYaw > CameraPitch > SpringArm3D > Camera3D.
#
# El rig NO cuelga del jugador: cuelga de la raiz y sigue su POSICION en cada
# paso de fisica. Asi el giro del personaje (que mira hacia donde se mueve)
# nunca arrastra la camara, que era lo que la volvia incontrolable.
# Solo el yaw gira con el raton; el pitch es fijo y el roll siempre es 0.
#
# Tambien adapta el campo de vision al tamano de la ventana (en ventanas
# altas como 1080x920 se abre para no ver el mundo "con zoom") y lleva los
# efectos de camara: lineas de velocidad con Turbo y la lluvia de tormenta.
extends Node3D

## Campo de vision vertical en pantallas panoramicas.
const BASE_FOV := 72.0
## Campo de vision horizontal minimo: en ventanas estrechas se sube el
## vertical hasta conseguirlo.
const MIN_HFOV := 92.0
## Apertura extra con Turbo: da sensacion de velocidad.
const TURBO_FOV_KICK := 12.0

@export var target_path: NodePath = ^"../Player"
@export var yaw_sensitivity := 0.0026
@export var pitch_degrees := -22.0
@export var spring_length := 7.0
## Altura del pivote sobre la posicion del jugador, a la altura del pecho.
@export var pivot_height := 1.55
## Seguimiento suave: en horizontal casi pegado, en vertical con mas retardo
## para que cada salto no sacuda el encuadre.
@export var follow_speed_xz := 18.0
@export var follow_speed_y := 7.0
## Distancia vertical maxima que la camara puede quedarse atras.
@export var max_lag_y := 1.5
## Hundimiento de la camara al aterrizar de una caida fuerte.
@export var impact_strength := 0.22

## Altura del mar. El pivote nunca baja de aqui: cuando el jugador se hunde,
## la camara se queda en la superficie mirando como desaparece.
var water_y := -INF
## Margen del pivote sobre el agua.
const WATER_MARGIN := 0.8

## Lo controla el nivel: en pausa se apaga para que el raton no gire la camara.
## El modo del raton (capturado / visible) lo gestiona un solo script, main.gd,
## que es tambien el que libera el cursor con Escape.
var look_enabled := true

@onready var _pitch: Node3D = $CameraPitch
@onready var _arm: SpringArm3D = $CameraPitch/SpringArm3D

var _target: CollisionObject3D = null
var _camera: Camera3D = null
var _base_fov := BASE_FOV
var _fov_kick := 0.0
var _fov_kick_target := 0.0
var _speed_lines: CPUParticles3D = null
var _rain: CPUParticles3D = null
# Muelle del golpe de aterrizaje, aplicado al pivote de pitch.
var _dip := 0.0
var _dip_velocity := 0.0

@export_group("Screenshake")
## Desvanecimiento del trauma por segundo.
@export var trauma_decay := 1.6
## Maximo desplazamiento local de la camara con trauma maximo (m).
@export var max_shake_offset := Vector3(0.25, 0.22, 0.15)
## Maxima rotacion local de la camara con trauma maximo (grados: pitch, yaw, roll).
@export var max_shake_rot_deg := Vector3(2.0, 2.0, 3.5)
## Frecuencia de oscilacion de la vibracion.
@export var shake_frequency := 36.0

var _trauma := 0.0
var _shake_time := 0.0


func set_look_enabled(value: bool) -> void:
	look_enabled = value


func _ready() -> void:
	if _pitch != null:
		_pitch.rotation = Vector3(deg_to_rad(pitch_degrees), 0.0, 0.0)
	if _arm != null:
		_arm.spring_length = spring_length
		_arm.collision_mask = 1
		_arm.margin = 0.35

	_resolve_target()
	snap_to_target()

	_camera = get_node_or_null("CameraPitch/SpringArm3D/Camera3D")
	get_viewport().size_changed.connect(_update_base_fov)
	_update_base_fov()
	_build_speed_lines()
	_build_rain()


# Campo de vision segun la proporcion de la ventana.
func _update_base_fov() -> void:
	var view := get_viewport().get_visible_rect().size
	if view.y <= 0.0:
		return
	var aspect := view.x / view.y
	var needed := rad_to_deg(2.0 * atan(tan(deg_to_rad(MIN_HFOV) * 0.5) / aspect))
	_base_fov = maxf(BASE_FOV, needed)


func set_speed_fx(on: bool) -> void:
	_fov_kick_target = TURBO_FOV_KICK if on else 0.0
	if _speed_lines != null and _speed_lines.emitting != on:
		_speed_lines.emitting = on


func set_rain(on: bool) -> void:
	if _rain != null:
		_rain.emitting = on
		_rain.visible = on


func _process(delta: float) -> void:
	_fov_kick = lerpf(_fov_kick, _fov_kick_target, 1.0 - exp(-6.0 * delta))
	if _camera != null:
		_camera.fov = _base_fov + _fov_kick


# Rayas que pasan junto a la camara, en un anillo para no tapar al jugador.
func _build_speed_lines() -> void:
	if _camera == null:
		return
	_speed_lines = CPUParticles3D.new()
	_speed_lines.name = "SpeedLines"
	_speed_lines.emitting = false
	_speed_lines.amount = 36
	_speed_lines.lifetime = 0.35
	_speed_lines.position = Vector3(0, 0, -9)
	_speed_lines.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	_speed_lines.emission_ring_axis = Vector3(0, 0, 1)
	_speed_lines.emission_ring_radius = 4.5
	_speed_lines.emission_ring_inner_radius = 2.6
	_speed_lines.emission_ring_height = 1.0
	_speed_lines.direction = Vector3(0, 0, 1)
	_speed_lines.spread = 0.0
	_speed_lines.gravity = Vector3.ZERO
	_speed_lines.initial_velocity_min = 28.0
	_speed_lines.initial_velocity_max = 36.0
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.0))
	fade.add_point(0.3, Color(1, 1, 1, 0.55))
	fade.set_color(fade.get_point_count() - 1, Color(1, 1, 1, 0.0))
	_speed_lines.color_ramp = fade
	_speed_lines.mesh = _streak_mesh(Vector3(0.025, 0.025, 1.6), Color(1, 0.95, 0.85))
	_camera.add_child(_speed_lines)


# Lluvia alrededor del jugador: cae en coordenadas del mundo y el emisor
# viaja con el rig.
func _build_rain() -> void:
	_rain = CPUParticles3D.new()
	_rain.name = "Rain"
	_rain.emitting = false
	_rain.visible = false
	_rain.amount = 420
	_rain.lifetime = 0.8
	_rain.local_coords = false
	_rain.position = Vector3(0, 9, 0)
	_rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_rain.emission_box_extents = Vector3(14, 0.5, 14)
	_rain.direction = Vector3(0.15, -1, 0)
	_rain.spread = 2.0
	_rain.gravity = Vector3(0, -30, 0)
	_rain.initial_velocity_min = 16.0
	_rain.initial_velocity_max = 20.0
	_rain.mesh = _streak_mesh(Vector3(0.02, 0.55, 0.02), Color(0.75, 0.85, 1, 0.45))
	add_child(_rain)


static func _streak_mesh(box_size: Vector3, color: Color) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = box_size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = color
	mesh.material = mat
	return mesh


func _physics_process(delta: float) -> void:
	if _target == null:
		return
	var goal := _target.global_position + Vector3(0.0, pivot_height, 0.0)
	var pos := global_position
	var k_xz := 1.0 - exp(-follow_speed_xz * delta)
	var k_y := 1.0 - exp(-follow_speed_y * delta)
	pos.x = lerpf(pos.x, goal.x, k_xz)
	pos.z = lerpf(pos.z, goal.z, k_xz)
	pos.y = clampf(lerpf(pos.y, goal.y, k_y), goal.y - max_lag_y, goal.y + max_lag_y)
	pos.y = maxf(pos.y, water_y + WATER_MARGIN)
	global_position = pos
	_update_dip(delta)
	_update_screenshake(delta)


# Colocacion instantanea: al empezar un nivel y al reaparecer.
func snap_to_target() -> void:
	_dip = 0.0
	_dip_velocity = 0.0
	_trauma = 0.0
	if _camera != null:
		_camera.position = Vector3.ZERO
		_camera.rotation = Vector3.ZERO
	if _pitch != null:
		_pitch.position = Vector3.ZERO
	if _target == null:
		return
	global_position = _target.global_position + Vector3(0.0, pivot_height, 0.0)


## Anade trauma de screenshake (0.0 a 1.0). El efecto real escala cuadraticamente.
func add_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


## Atajo por compatibilidad.
func shake(amount: float) -> void:
	add_trauma(amount)


func get_trauma() -> float:
	return _trauma


# El jugador lo llama al aterrizar con la velocidad de caida (m/s).
func add_impact(fall_speed: float) -> void:
	var strength := clampf((fall_speed - 8.0) / 12.0, 0.0, 1.0)
	_dip_velocity -= strength * impact_strength * 20.0
	# Si el aterrizaje es fuerte, aplicamos screenshake proporcional
	if fall_speed > 5.5:
		var hard_strength := clampf((fall_speed - 5.5) / 16.0, 0.0, 1.0)
		add_trauma(hard_strength * 0.65)


# Muelle algo menos que amortiguado: baja, rebota un poco y se asienta.
func _update_dip(delta: float) -> void:
	if _pitch == null:
		return
	_dip_velocity += (-_dip * 120.0 - _dip_velocity * 15.0) * delta
	_dip += _dip_velocity * delta
	_pitch.position = Vector3(0.0, _dip, 0.0)


## Vibracion no lineal de camara (screenshake)
func _update_screenshake(delta: float) -> void:
	if _camera == null:
		return
	if _trauma <= 0.0:
		_camera.position = Vector3.ZERO
		_camera.rotation = Vector3.ZERO
		return

	_trauma = maxf(0.0, _trauma - trauma_decay * delta)
	var intensity := _trauma * _trauma
	_shake_time += delta * shake_frequency

	var ox := (sin(_shake_time * 1.0) + sin(_shake_time * 2.37) * 0.45) * max_shake_offset.x * intensity
	var oy := (cos(_shake_time * 1.25) + sin(_shake_time * 2.81) * 0.45) * max_shake_offset.y * intensity
	var oz := sin(_shake_time * 1.83) * max_shake_offset.z * intensity
	_camera.position = Vector3(ox, oy, oz)

	var rx := deg_to_rad(max_shake_rot_deg.x) * sin(_shake_time * 1.41) * intensity
	var ry := deg_to_rad(max_shake_rot_deg.y) * cos(_shake_time * 1.13) * intensity
	var rz := deg_to_rad(max_shake_rot_deg.z) * sin(_shake_time * 2.19) * intensity
	_camera.rotation = Vector3(rx, ry, rz)


# El brazo de la camara no debe chocar con el propio jugador: si lo hace, se
# acorta hasta cero y la camara termina dentro del personaje.
func _resolve_target() -> void:
	var node := get_node_or_null(target_path)
	if node is CollisionObject3D:
		_target = node as CollisionObject3D
	if _target == null or _arm == null:
		return
	_arm.add_excluded_object(_target.get_rid())


func _unhandled_input(event: InputEvent) -> void:
	if not look_enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= event.relative.x * yaw_sensitivity
		# El horizonte se mantiene recto: nunca hay roll.
		rotation.x = 0.0
		rotation.z = 0.0
