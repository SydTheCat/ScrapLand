extends Area3D
class_name Interactable
## SCRAPLAND -- Marks something as "the player can press E on this".
##
## This is a COMPONENT, not a base class. Add it as a child Area3D of whatever
## should be interactable, give it a CollisionShape3D, then have the parent
## connect to its `interacted` signal:
##
##     ChargingStation (StaticBody3D)
##     ├── Collision      CollisionShape3D
##     └── Interactable   Area3D  <- this script
##         └── Shape      CollisionShape3D
##
## Doing it this way means a solid StaticBody3D, a floating pickup and a
## RigidBody3D can all be interactable without sharing a base class.
##
## The player's Interactor finds these, draws a glow around the feet of the
## closest one you are looking at, and calls interact() when you press E.

## The player (or a helper robot) pressed the interact button on this.
signal interacted(who: Node)
## Fired when this becomes / stops being the player's current target.
signal focus_changed(focused: bool)

## Physics layer 4 ("interactable"). Bit value 8, not 4 -- layer N has value
## 2^(N-1). Forced in _ready() so a new interactable cannot be misconfigured.
const INTERACTABLE_LAYER: int = 8

@export_group("Prompt")
## Shown as "E — <verb> <label>", e.g. "E — Salvage Barrel".
@export var prompt_verb: String = "Use"
## Leave empty to use the parent node's name, prettified.
@export var prompt_label: String = ""
## For things that need the button held down rather than tapped (salvaging),
## so the prompt reads "Hold E — Salvage ..." instead of "E — Salvage ...".
@export var hold_to_use: bool = false
## Turn off to grey this out without deleting it (a depleted resource node, a
## machine that is still building).
@export var enabled: bool = true

@export_group("Highlight")
@export var highlight_enabled: bool = true
## Colour of the ground ring. Alpha is the peak brightness of the glow.
@export var highlight_color: Color = Color(0.45, 0.95, 1.0, 0.9)
## Object whose footprint the ring sits under. Defaults to the parent node.
@export var highlight_root: Node3D
## How far outside the object's footprint the ring sits.
@export var glow_padding: float = 1.28
@export var glow_min_radius: float = 0.42
@export var glow_height: float = 0.03

var _glow: MeshInstance3D
var _glow_material: StandardMaterial3D
var _focused: bool = false
var _pulse_time: float = 0.0


func _ready() -> void:
	# The Interactor detects these areas, so they must be detectable (layer 4)
	# but do not need to detect anything themselves.
	collision_layer = INTERACTABLE_LAYER
	collision_mask = 0
	monitorable = true
	monitoring = false

	if highlight_root == null:
		highlight_root = get_parent() as Node3D
	set_process(false)


# --- Prompt -----------------------------------------------------------------

## The full line the HUD displays. Reads the real key from the InputMap, so
## remapping "interact" updates the prompt automatically.
func get_prompt() -> String:
	var key := get_interact_key()
	if hold_to_use:
		key = "Hold " + key
	return "%s — %s %s" % [key, prompt_verb, get_label()]


func get_label() -> String:
	if not prompt_label.is_empty():
		return prompt_label
	var parent := get_parent()
	# "charging_station" / "ChargingStation" -> "Charging Station"
	return String(parent.name).capitalize() if parent else ""


## Looks up whichever key is currently bound to the "interact" action.
static func get_interact_key() -> String:
	for event in InputMap.action_get_events(&"interact"):
		var key := event as InputEventKey
		if key:
			return key.as_text_physical_keycode()
	return "E"


# --- Interaction ------------------------------------------------------------

## Called by the player's Interactor. The parent object does the actual work in
## its `interacted` handler.
func interact(who: Node) -> void:
	if not enabled:
		return
	interacted.emit(who)


# --- Highlight --------------------------------------------------------------

## Called by the Interactor as the player's target changes.
func set_focused(focused: bool) -> void:
	if _focused == focused:
		return
	_focused = focused
	if highlight_enabled:
		_apply_highlight(focused)
	set_process(highlight_enabled and focused)
	focus_changed.emit(focused)


func is_focused() -> bool:
	return _focused


func _process(delta: float) -> void:
	if _glow_material == null:
		return
	_pulse_time += delta * 2.8
	var pulse := 0.72 + 0.28 * (0.5 + 0.5 * sin(_pulse_time))
	var colour := highlight_color
	colour.a = clampf(highlight_color.a, 0.2, 1.0) * pulse
	_glow_material.albedo_color = colour


## Draws a soft ring on the ground under the object instead of tinting its mesh.
func _apply_highlight(on: bool) -> void:
	if not on:
		if _glow:
			_glow.visible = false
		return
	if _glow == null:
		_glow = _make_ground_glow()
	_fit_ground_glow()
	_glow.visible = true
	_pulse_time = 0.0


func _make_ground_glow() -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "FocusGlow"
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh_instance.mesh = quad
	_glow_material = _build_glow_material()
	mesh_instance.material_override = _glow_material
	if highlight_root:
		highlight_root.add_child(mesh_instance)
	else:
		add_child(mesh_instance)
	return mesh_instance


func _fit_ground_glow() -> void:
	if _glow == null:
		return
	var bounds := _footprint_aabb()
	var radius := maxf(maxf(bounds.size.x, bounds.size.z) * 0.5 * glow_padding, glow_min_radius)
	var center := bounds.get_center()
	_glow.position = Vector3(center.x, bounds.position.y + glow_height, center.z)
	_glow.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_glow.scale = Vector3(radius, radius, 1.0)


func _build_glow_material() -> StandardMaterial3D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.4, 0.58, 0.78, 1.0])
	gradient.colors = PackedColorArray([
		Color(1, 1, 1, 0.0),
		Color(1, 1, 1, 0.0),
		Color(1, 1, 1, 1.0),
		Color(1, 1, 1, 0.35),
		Color(1, 1, 1, 0.0),
	])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(0.5, 0.0)
	texture.width = 256
	texture.height = 256

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = highlight_color
	material.albedo_texture = texture
	material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	return material


## Local-space box around the object's meshes, used to sit the ring on its feet.
func _footprint_aabb() -> AABB:
	var meshes := _collect_meshes(highlight_root)
	var combined := AABB()
	var started := false
	var space := highlight_root if highlight_root else self
	for mesh in meshes:
		if mesh == _glow or mesh.mesh == null:
			continue
		var local_box := mesh.get_aabb()
		var to_root := space.global_transform.affine_inverse() * mesh.global_transform
		var box := to_root * local_box
		if not started:
			combined = box
			started = true
		else:
			combined = combined.merge(box)
	if started:
		return combined
	return AABB(Vector3(-0.4, 0.0, -0.4), Vector3(0.8, 0.2, 0.8))


## Depth-first search for every MeshInstance3D under `root`.
func _collect_meshes(root: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if root == null:
		return found
	var mesh := root as MeshInstance3D
	if mesh:
		found.append(mesh)
	for child in root.get_children():
		found.append_array(_collect_meshes(child))
	return found
