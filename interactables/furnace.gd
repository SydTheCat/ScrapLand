extends Structure
class_name Furnace
## SCRAPLAND -- A placed furnace. Feed it scrap, wait, take plates out.
##
## Two Inventory children hold the work: Input at the top, Output at the bottom.
## Recipes live as SmeltRecipe resources on this node, so a new conversion is a
## data file, not a script change.
##
## Expected node layout:
##
##     Furnace (StaticBody3D)     <- this script
##     ├── Model         Node3D (mesh, FireLight, Charge scrap, Smoke)
##     ├── Collision     CollisionShape3D
##     ├── Input         Node  (inventory.gd)
##     ├── Output        Node  (inventory.gd)
##     ├── Interactable  Area3D
##     └── Sfx           AudioStreamPlayer3D (burning furnace loop)

signal progress_changed

@export var recipes: Array[Resource] = []

@onready var input: Inventory = $Input
@onready var output: Inventory = $Output
@onready var _interactable: Interactable = $Interactable
@onready var _glow: MeshInstance3D = get_node_or_null("Model/Mouth") as MeshInstance3D
@onready var _light: OmniLight3D = get_node_or_null("Model/FireLight") as OmniLight3D
@onready var _charge: Node3D = get_node_or_null("Model/Charge") as Node3D
@onready var _smoke: GPUParticles3D = get_node_or_null("Model/Smoke") as GPUParticles3D
@onready var _sfx: AudioStreamPlayer3D = get_node_or_null("Sfx") as AudioStreamPlayer3D

var _job_output: ItemData
var _job_output_amount: int = 0
var _job_input_id: String = ""
var _job_input_amount: int = 0
var _job_seconds: float = 1.0
var _elapsed: float = 0.0
var _glow_material: StandardMaterial3D


func _ready() -> void:
	super()
	_interactable.interacted.connect(_on_interacted)
	input.changed.connect(_refresh_prompt)
	output.changed.connect(_refresh_prompt)
	_refresh_prompt()
	if _glow:
		_glow_material = _clone_material(_glow)
	if _sfx and _sfx.stream:
		var stream := _sfx.stream.duplicate()
		if stream is AudioStreamMP3:
			(stream as AudioStreamMP3).loop = true
		_sfx.stream = stream
	_update_visuals()


func _process(delta: float) -> void:
	if _job_output:
		_elapsed += delta
		if _elapsed >= _job_seconds:
			_try_finish()
		progress_changed.emit()
	else:
		_try_start()
	_update_visuals()


func get_progress() -> float:
	if _job_output == null:
		return 0.0
	return clampf(_elapsed / maxf(_job_seconds, 0.01), 0.0, 1.0)


func is_working() -> bool:
	return _job_output != null and _elapsed < _job_seconds


func get_status_text() -> String:
	if _job_output and _elapsed >= _job_seconds:
		return "Done — take the %s." % _job_output.display_name
	if _job_output:
		return "Smelting %s..." % _job_output.display_name
	if _find_recipe() == null:
		return "Feed it scrap."
	if not output.can_accept(_find_recipe().output, _find_recipe().output_amount):
		return "Output is full."
	return "Ready."


func accepts_item(item_id: String) -> bool:
	return _recipe_for(item_id) != null


## Refund an unfinished job so packing up cannot eat the scrap.
func prepare_to_pack() -> void:
	if _job_output == null or _job_input_id.is_empty():
		return
	var refund := ItemDB.get_item(_job_input_id)
	if refund:
		input.add_item(refund, _job_input_amount)
	_clear_job()


# --- Work -------------------------------------------------------------------

func _try_start() -> void:
	var recipe := _find_recipe()
	if recipe == null:
		return
	if not output.can_accept(recipe.output, recipe.output_amount):
		return
	input.remove_item(recipe.input_id, recipe.input_amount)
	_job_output = recipe.output
	_job_output_amount = recipe.output_amount
	_job_input_id = recipe.input_id
	_job_input_amount = recipe.input_amount
	_job_seconds = recipe.seconds
	_elapsed = 0.0
	progress_changed.emit()


func _try_finish() -> void:
	if _job_output == null:
		return
	var leftover := output.add_item(_job_output, _job_output_amount)
	if leftover > 0:
		# Keep the job parked at "done" until there is room.
		_job_output_amount = leftover
		_elapsed = _job_seconds
		progress_changed.emit()
		return
	_clear_job()
	progress_changed.emit()


func _clear_job() -> void:
	_job_output = null
	_job_output_amount = 0
	_job_input_id = ""
	_job_input_amount = 0
	_elapsed = 0.0


func _find_recipe() -> SmeltRecipe:
	for entry in recipes:
		var recipe := entry as SmeltRecipe
		if recipe == null or not recipe.is_valid():
			continue
		if input.count(recipe.input_id) >= recipe.input_amount:
			return recipe
	return null


func _recipe_for(item_id: String) -> SmeltRecipe:
	for entry in recipes:
		var recipe := entry as SmeltRecipe
		if recipe and recipe.is_valid() and recipe.input_id == item_id:
			return recipe
	return null


# --- Interaction ------------------------------------------------------------

func _on_interacted(_who: Node) -> void:
	var ui := get_tree().get_first_node_in_group(&"furnace_ui")
	if ui == null:
		push_warning("furnace.gd: no node in the 'furnace_ui' group to open.")
		return
	if ui.has_method("is_showing") and bool(ui.call("is_showing", self)):
		if ui.has_method("close"):
			ui.call("close")
		return
	if ui.has_method("open_furnace"):
		ui.call("open_furnace", self)


func _refresh_prompt() -> void:
	var ui := get_tree().get_first_node_in_group(&"furnace_ui")
	var showing := ui != null and ui.has_method("is_showing") and bool(ui.call("is_showing", self))
	_interactable.prompt_verb = "Close" if showing else "Use"
	if is_working():
		_interactable.prompt_label = "%s (smelting)" % get_display_name()
	elif output.get_used_slot_count() > 0:
		_interactable.prompt_label = "%s (ready)" % get_display_name()
	else:
		_interactable.prompt_label = get_display_name()


func _update_visuals() -> void:
	if _charge:
		_charge.visible = is_working() or input.count("scrap_metal") > 0
	if _smoke:
		_smoke.emitting = is_working()
	_update_fire_sound()
	var heat := 1.0 if is_working() else (0.35 if _job_output else 0.0)
	if _glow_material:
		_glow_material.emission_energy_multiplier = lerpf(
			_glow_material.emission_energy_multiplier, heat * 3.2, 0.12)
	if _light:
		if is_working():
			var t := Time.get_ticks_msec() * 0.001
			var flicker := 0.62 + 0.22 * sin(t * 16.4) + 0.16 * sin(t * 29.7) + 0.1 * sin(t * 47.0)
			_light.visible = true
			_light.light_energy = clampf(flicker * 2.8, 0.55, 3.4)
			_light.light_color = Color(
				1.0,
				0.34 + 0.2 * (0.5 + 0.5 * sin(t * 11.2)),
				0.06 + 0.08 * absf(sin(t * 7.4)))
		else:
			_light.light_energy = lerpf(_light.light_energy, heat * 1.1, 0.14)
			_light.light_color = Color(1.0, 0.45, 0.15)
			_light.visible = _light.light_energy > 0.06
	_refresh_prompt()


func _update_fire_sound() -> void:
	if _sfx == null:
		return
	if is_working():
		if not _sfx.playing:
			_sfx.play()
	elif _sfx.playing:
		_sfx.stop()


func _clone_material(instance: MeshInstance3D) -> StandardMaterial3D:
	var primitive := instance.mesh as PrimitiveMesh
	if primitive == null:
		return null
	var source := primitive.material as StandardMaterial3D
	if source == null:
		return null
	var copy := source.duplicate() as StandardMaterial3D
	instance.set_surface_override_material(0, copy)
	return copy


# --- Saving -----------------------------------------------------------------

func save_data() -> Dictionary:
	var data := super.save_data()
	data["elapsed"] = _elapsed
	data["job_seconds"] = _job_seconds
	data["job_input_id"] = _job_input_id
	data["job_input_amount"] = _job_input_amount
	data["job_output_id"] = _job_output.id if _job_output else ""
	data["job_output_amount"] = _job_output_amount
	return data


func load_data(data: Dictionary) -> void:
	super.load_data(data)
	_job_input_id = String(data.get("job_input_id", ""))
	_job_input_amount = int(data.get("job_input_amount", 0))
	_job_seconds = maxf(float(data.get("job_seconds", 1.0)), 0.01)
	_elapsed = float(data.get("elapsed", 0.0))
	_job_output_amount = int(data.get("job_output_amount", 0))
	var out_id := String(data.get("job_output_id", ""))
	_job_output = ItemDB.get_item(out_id) if not out_id.is_empty() else null
	if _job_output == null:
		_clear_job()
	progress_changed.emit()
