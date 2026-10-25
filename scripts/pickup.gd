# Objetos interactivos del nivel: estrella, corazon, gema, Super salto, aro
# de tiempo, checkpoint y meta.
#
# Todos son Area3D que detectan al jugador (grupo "player") y avisan al
# nivel mediante la senal "collected". El nodo raiz del nivel conecta esas
# senales para llevar el progreso.
extends Area3D

signal collected(kind: String, node: Node)

# Se recogen una vez y desaparecen con una pequena animacion.
const COLLECTIBLE_KINDS := ["star", "heart", "gem", "power", "time"]

const FLAG_GREEN := "res://assets/KayKit_Platformer_Pack_1.0_FREE/Assets/gltf/green/flag_B_green.gltf"

var kind := "star"
var spin_speed := 2.2

var _taken := false
var _t := 0.0
var _visual: Node3D = null
var _flag: Node3D = null
var _visual_base_y := 0.0
var _halo: Node3D = null


func _ready() -> void:
	add_to_group("pickup")
	add_to_group("pickup_" + kind)
	body_entered.connect(_on_body_entered)
	_visual = get_node_or_null("Visual")
	_flag = get_node_or_null("Flag")
	if _visual != null:
		_visual_base_y = _visual.position.y
		_halo = _visual.get_node_or_null("Halo")


func _process(delta: float) -> void:
	_t += delta
	if _visual != null and spin_speed > 0.0:
		_visual.rotate_y(delta * spin_speed)
		_visual.position.y = _visual_base_y + sin(_t * 2.2) * 0.12
	# El halo late despacio; va a destiempo del rebote para que se vea vivo.
	if _halo != null:
		_halo.scale = Vector3.ONE * (1.0 + sin(_t * 3.1) * 0.12)


func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("player"):
		return

	if kind in COLLECTIBLE_KINDS:
		_collect()
		return

	match kind:
		"checkpoint":
			if _taken:
				return
			_taken = true
			_swap_flag_green()
			collected.emit(kind, self)
		"goal":
			if _taken:
				return
			_taken = true
			collected.emit(kind, self)


func _collect() -> void:
	if _taken:
		return
	_taken = true
	# No se puede cambiar la monitorizacion dentro del propio evento de
	# colision: el motor lo bloquea y lanza error. Se difiere un paso.
	set_deferred("monitoring", false)
	_spawn_collect_particles()
	_spawn_popup_label()
	collected.emit(kind, self)
	if _visual != null:
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(_visual, "scale", Vector3.ZERO, 0.18)
		tween.tween_property(_visual, "position:y", _visual.position.y + 0.6, 0.18)
		tween.chain().tween_callback(queue_free)
	else:
		queue_free()


func _spawn_collect_particles() -> void:
	var color := Color(1.0, 0.88, 0.25, 1.0)
	match kind:
		"heart":
			color = Color(1.0, 0.28, 0.45, 1.0)
		"gem":
			color = Color(0.25, 0.9, 1.0, 1.0)
		"power":
			color = Color(0.75, 1.0, 0.3, 1.0)
		"time":
			color = Color(0.35, 1.0, 0.65, 1.0)

	var p := CPUParticles3D.new()
	p.name = "CollectBurst"
	p.emitting = false
	p.one_shot = true
	p.amount = 26
	p.lifetime = 0.65
	p.explosiveness = 0.96
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.25
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 2.5
	p.initial_velocity_max = 5.5
	p.gravity = Vector3(0.0, -4.0, 0.0)
	p.damping_min = 2.0
	p.damping_max = 4.0
	p.scale_amount_min = 0.8
	p.scale_amount_max = 1.4

	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.0))
	p.scale_amount_curve = shrink

	var fade := Gradient.new()
	fade.set_color(0, color)
	fade.add_point(0.7, color)
	fade.set_color(fade.get_point_count() - 1, Color(color.r, color.g, color.b, 0.0))
	p.color_ramp = fade

	var mesh := SphereMesh.new()
	mesh.radius = 0.08
	mesh.height = 0.16
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	p.mesh = mesh

	var parent := get_parent()
	if parent != null:
		p.global_position = global_position
		parent.add_child(p)
		p.restart()
		get_tree().create_timer(p.lifetime + 0.1).timeout.connect(p.queue_free)


func _spawn_popup_label() -> void:
	if kind == "time":
		return
	var text := ""
	var color := Color(1, 1, 1)
	match kind:
		"star":
			text = "+1"
			color = Color(1.0, 0.92, 0.3)
		"heart":
			text = "+1 Vida"
			color = Color(1.0, 0.4, 0.5)
		"gem":
			text = "¡GEMA!"
			color = Color(0.4, 0.9, 1.0)
		"power":
			text = "¡SUPER SALTO!"
			color = Color(0.8, 1.0, 0.35)

	if text == "":
		return

	var label := Label3D.new()
	label.text = text
	label.font_size = 72
	label.outline_size = 18
	label.modulate = color
	label.outline_modulate = Color(0.06, 0.06, 0.12)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.global_position = global_position + Vector3(0, 0.8, 0)

	var parent := get_parent()
	if parent != null:
		parent.add_child(label)
		var tween := label.create_tween().set_parallel()
		tween.tween_property(label, "position:y", label.position.y + 1.8, 0.85) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(label, "scale", Vector3(1.2, 1.2, 1.2), 0.2)
		tween.tween_property(label, "scale", Vector3.ONE, 0.65).set_delay(0.2)
		tween.tween_property(label, "modulate:a", 0.0, 0.85).set_delay(0.25)
		tween.chain().tween_callback(label.queue_free)


# El checkpoint cambia de bandera roja a verde para que se lea a distancia.
func _swap_flag_green() -> void:
	if _flag == null:
		return
	var parent := _flag.get_parent()
	var pos := _flag.position
	_flag.queue_free()
	_flag = null

	var packed := load(FLAG_GREEN) as PackedScene
	if packed != null:
		var node: Node3D = packed.instantiate()
		node.name = "Flag"
		node.position = pos
		parent.add_child(node)
		_flag = node
