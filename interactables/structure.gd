extends StaticBody3D
class_name Structure
## SCRAPLAND -- Base for anything that stands in the world because the player put
## it there, and for the pre-placed props that behave the same way.
##
## Its first job is remembering where it is. Structures are created at runtime,
## so the save manager can only bring one back by instancing its scene file and
## then telling it where to stand -- which means the structure has to report its
## own transform. Everything else about saving is handled by the group contract
## in systems/save_manager.gd.
##
## Its second job is coming back apart. The salvage beam treats a structure the
## same way it treats a wreck: hold the button and the thing packs itself into
## the matching inventory item. That item is found by asking ItemDB which
## placeable points at this scene, so a new building needs no extra list here.
##
## Subclasses with state of their own override save_data() and load_data() and
## call super() first, so the position handling is never duplicated.

@export_group("Identity")
## Shown on the progress bar while packing up. Leave empty to use the node name.
@export var display_name: String = ""

@export_group("Packing Up")
## Off for scenery that should stay put (none yet; the charger is not a Structure).
@export var deconstructible: bool = true
## Damage needed to pack it. At the beam's 34/sec, 40 is a little over a second.
@export var max_integrity: float = 40.0
## Empty: the built-in salvage beam. Set it and only that tool can pack this up.
@export var required_tool_id: String = ""
@export var work_verb: String = "PACKING UP"

@export_group("Feel")
@export var shake_strength: float = 0.01
@export var shake_speed: float = 38.0
@export var active_linger: float = 0.12

var _integrity: float = 0.0
var _active_timer: float = 0.0
var _model_rest: Vector3 = Vector3.ZERO

@onready var _model: Node3D = get_node_or_null("Model") as Node3D


func _ready() -> void:
	_integrity = max_integrity
	if _model:
		_model_rest = _model.position
	add_to_group(&"persist")


func _process(delta: float) -> void:
	if _model == null:
		return
	_active_timer -= delta
	if _active_timer > 0.0:
		var t := Time.get_ticks_msec() / 1000.0 * shake_speed
		_model.position = _model_rest + Vector3(sin(t), 0.0, cos(t * 1.3)) * shake_strength
	elif not _model.position.is_equal_approx(_model_rest):
		_model.position = _model.position.lerp(_model_rest, clampf(12.0 * delta, 0.0, 1.0))


# --- What the salvage beam calls --------------------------------------------

## Same contract as SalvageObject, so PlayerTool can aim at either without a
## second code path.
func accepts_tool(tool_id: String) -> bool:
	# Default: the salvage beam, whether it still has a blank id or the item id.
	if required_tool_id.is_empty():
		return tool_id.is_empty() or tool_id == "salvage_beam"
	return required_tool_id == tool_id


func get_tool_hint() -> String:
	if required_tool_id.is_empty():
		return "%s is packed up with the salvage beam." % get_display_name()
	var item := ItemDB.get_item(required_tool_id)
	var tool_name := item.display_name if item else required_tool_id
	return "%s cannot be packed with this tool. Needs a %s." % [get_display_name(), tool_name]


func apply_salvage(amount: float) -> void:
	if _integrity <= 0.0 or amount <= 0.0:
		return
	if not is_deconstructible():
		return

	_integrity = maxf(_integrity - amount, 0.0)
	_active_timer = active_linger

	if _integrity <= 0.0:
		_pack_up()


func get_integrity_ratio() -> float:
	return _integrity / maxf(max_integrity, 0.001)


func get_display_name() -> String:
	if not display_name.is_empty():
		return display_name
	return String(name).capitalize()


## True when this scene is a placed item and packing it back up is allowed.
func is_deconstructible() -> bool:
	return deconstructible and get_place_item() != null


func get_place_item() -> ItemData:
	return ItemDB.get_item_for_scene(scene_file_path)


# --- Packing ----------------------------------------------------------------

## Turns the structure back into its item. Contents of a storage box go into the
## cargo hold first; if anything will not fit, the structure stays and packing
## stops, so nothing is lost.
func _pack_up() -> void:
	var item := get_place_item()
	var robot := _find_robot()
	var cargo := robot.get_node_or_null("Inventory") as Inventory if robot else null
	if item == null or cargo == null:
		_abort_pack("Cannot pack this up right now.")
		return

	if has_method("prepare_to_pack"):
		call("prepare_to_pack")
	for child in get_children():
		var box := child as Inventory
		if box == null:
			continue
		box.transfer_all(cargo)
		if box.get_used_slot_count() > 0:
			_abort_pack("No room for what is inside. Empty it first.")
			return

	if not cargo.can_accept(item, 1):
		_abort_pack("Your cargo hold is full.")
		return

	cargo.add_item(item, 1)
	GameEvents.clear_salvage_progress()
	GameEvents.notify("%s packed up." % item.display_name, Color(0.6, 1, 0.7))
	queue_free()


func _abort_pack(message: String) -> void:
	# Leave a little work so the next hold is a deliberate try, not an instant
	# fail-loop the moment integrity hits zero.
	_integrity = maxf(max_integrity * 0.25, 8.0)
	GameEvents.notify(message, Color(1, 0.7, 0.35))


func _find_robot() -> Player:
	return get_tree().get_first_node_in_group(&"player") as Player


# --- Saving -----------------------------------------------------------------

func save_data() -> Dictionary:
	return {
		"position": global_position,
		"facing": rotation.y,
		"integrity": _integrity,
	}


func load_data(data: Dictionary) -> void:
	global_position = data.get("position", global_position)
	rotation.y = float(data.get("facing", rotation.y))
	_integrity = clampf(float(data.get("integrity", max_integrity)), 0.0, max_integrity)
	_active_timer = 0.0
	if _model:
		_model.position = _model_rest
