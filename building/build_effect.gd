extends Node
## SCRAPLAND -- Bottom-up construction wipe for a just-placed structure.
##
## Builder attaches this after the node is in the world. A reveal shader hides
## everything above a rising scan line so the object prints in from the ground.
## When the wipe finishes the original materials come back and this node frees
## itself.

const REVEAL_SHADER := preload("res://building/build_reveal.gdshader")
const GROW_SOUND := preload("res://audio/electronic_grow_sound.mp3")

@export var duration: float = 1.15
@export var scan_color: Color = Color(0.45, 0.98, 1.0)

var _host: Node3D
var _model: Node3D
var _scan: MeshInstance3D
var _light: OmniLight3D
var _sparks: GPUParticles3D
var _sfx: AudioStreamPlayer3D
var _meshes: Array[MeshInstance3D] = []
var _shader_mats: Array[ShaderMaterial] = []
var _elapsed: float = 0.0
var _min_y: float = 0.0
var _height: float = 1.0
var _width: float = 1.0
var _depth: float = 1.0
var _center_x: float = 0.0
var _center_z: float = 0.0


func start() -> void:
	_host = get_parent() as Node3D
	if _host == null:
		queue_free()
		return
	_model = _host.get_node_or_null("Model") as Node3D
	if _model == null:
		queue_free()
		return
	_measure()
	_apply_reveal_materials()
	_build_scan()
	_build_light()
	_build_sparks()
	_play_grow_sound()
	_set_reveal(0.0)
	set_process(true)


func _process(delta: float) -> void:
	_elapsed += delta
	var raw := clampf(_elapsed / maxf(duration, 0.05), 0.0, 1.0)
	var t := 1.0 - (1.0 - raw) * (1.0 - raw)
	_set_reveal(t)
	if raw < 1.0:
		return
	_finish()


func _measure() -> void:
	var bounds := _aabb_in(_host, _model)
	if bounds.size == Vector3.ZERO:
		bounds = AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.0, 1.0))
	var pad := 0.18
	_min_y = bounds.position.y
	_height = maxf(bounds.size.y, 0.2)
	_width = maxf(bounds.size.x, 0.4) + pad
	_depth = maxf(bounds.size.z, 0.4) + pad
	var centre := bounds.get_center()
	_center_x = centre.x
	_center_z = centre.z
	duration = clampf(duration * (0.7 + _height * 0.2), 0.75, 1.8)


func _apply_reveal_materials() -> void:
	_meshes.clear()
	_shader_mats.clear()
	_collect_meshes(_model, _meshes)
	for mesh in _meshes:
		mesh.set_meta(&"build_old_override", mesh.material_override)
		var mat := ShaderMaterial.new()
		mat.shader = REVEAL_SHADER
		var src := mesh.get_active_material(0)
		if src != null and "albedo_texture" in src and src.albedo_texture:
			mat.set_shader_parameter("albedo_tex", src.albedo_texture)
		if src != null and "albedo_color" in src:
			mat.set_shader_parameter("albedo_color", src.albedo_color)
		mat.set_shader_parameter("scan_color", Vector3(scan_color.r, scan_color.g, scan_color.b))
		mesh.material_override = mat
		_shader_mats.append(mat)


func _build_scan() -> void:
	_scan = MeshInstance3D.new()
	_scan.name = "BuildScan"
	_scan.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.045
	disc.radial_segments = 28
	disc.rings = 1
	_scan.mesh = disc
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(scan_color.r, scan_color.g, scan_color.b, 0.85)
	mat.emission_enabled = true
	mat.emission = scan_color
	mat.emission_energy_multiplier = 3.4
	_scan.material_override = mat
	_host.add_child(_scan)


func _build_light() -> void:
	_light = OmniLight3D.new()
	_light.name = "BuildLight"
	_light.light_color = scan_color
	_light.omni_range = maxf(maxf(_width, _depth) * 2.2, 3.5)
	_light.shadow_enabled = false
	_host.add_child(_light)


func _build_sparks() -> void:
	_sparks = GPUParticles3D.new()
	_sparks.name = "BuildSparks"
	_sparks.amount = 28
	_sparks.lifetime = 0.45
	_sparks.randomness = 0.4
	_sparks.visibility_aabb = AABB(Vector3(-2, -0.4, -2), Vector3(4, 3, 4))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = maxf(_width, _depth) * 0.38
	process.direction = Vector3(0, 1, 0)
	process.spread = 18.0
	process.initial_velocity_min = 0.4
	process.initial_velocity_max = 1.6
	process.gravity = Vector3(0, 1.2, 0)
	process.scale_min = 0.04
	process.scale_max = 0.09
	process.color = scan_color
	_sparks.process_material = process
	var draw := QuadMesh.new()
	draw.size = Vector2(0.07, 0.07)
	var spark_mat := StandardMaterial3D.new()
	spark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	spark_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	spark_mat.albedo_color = scan_color
	draw.material = spark_mat
	_sparks.draw_pass_1 = draw
	_host.add_child(_sparks)


func _play_grow_sound() -> void:
	_sfx = AudioStreamPlayer3D.new()
	_sfx.name = "BuildSfx"
	_sfx.stream = GROW_SOUND
	_sfx.volume_db = -8.0
	_sfx.max_distance = 18.0
	_sfx.unit_size = 8.0
	add_child(_sfx)
	_sfx.play()


func _set_reveal(t: float) -> void:
	var h := maxf(_height * t, 0.04)
	var top_y := _min_y + h
	for mat in _shader_mats:
		mat.set_shader_parameter("reveal_y", top_y)

	_scan.position = Vector3(_center_x, top_y, _center_z)
	var radius := maxf(_width, _depth) * 0.5
	_scan.scale = Vector3(radius, 1.0, radius)
	var pulse := 0.7 + 0.3 * (0.5 + 0.5 * sin(_elapsed * 18.0))
	var scan_mat := _scan.material_override as StandardMaterial3D
	if scan_mat:
		scan_mat.albedo_color = Color(scan_color.r, scan_color.g, scan_color.b, 0.55 + 0.4 * pulse)
		scan_mat.emission_energy_multiplier = 2.4 + 2.2 * pulse

	if _light:
		_light.position = Vector3(_center_x, top_y, _center_z)
		_light.light_energy = (2.2 + 2.8 * pulse) * (0.35 + 0.65 * (1.0 - t))

	if _sparks:
		_sparks.position = Vector3(_center_x, top_y, _center_z)
		_sparks.emitting = t < 0.98


func _finish() -> void:
	set_process(false)
	for mesh in _meshes:
		if not is_instance_valid(mesh):
			continue
		var previous: Variant = mesh.get_meta(&"build_old_override", null)
		mesh.material_override = previous as Material
		mesh.remove_meta(&"build_old_override")
	if is_instance_valid(_scan):
		_scan.queue_free()
	if is_instance_valid(_light):
		_light.queue_free()
	if is_instance_valid(_sparks):
		_sparks.queue_free()
	if is_instance_valid(_sfx):
		_sfx.stop()
	queue_free()


func _aabb_in(space: Node3D, root: Node) -> AABB:
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(root, meshes)
	var combined := AABB()
	var started := false
	for mesh in meshes:
		if mesh.mesh == null:
			continue
		var box := (space.global_transform.affine_inverse() * mesh.global_transform) * mesh.get_aabb()
		if not started:
			combined = box
			started = true
		else:
			combined = combined.merge(box)
	return combined if started else AABB()


func _collect_meshes(root: Node, into: Array[MeshInstance3D]) -> void:
	var mesh := root as MeshInstance3D
	if mesh:
		into.append(mesh)
	for child in root.get_children():
		_collect_meshes(child, into)
