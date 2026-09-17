extends StaticBody3D
class_name SalvageObject
## SCRAPLAND -- A broken machine the robot can dismantle for parts.
##
## It has an integrity pool instead of health. The player's equipped tool grinds
## it down while the button is held; the machine shakes, throws sparks, and sheds
## visible parts as it comes apart. At zero it drops resource pickups.
##
## Rock works the same way as scrap metal, so an ore deposit is this same script
## with different meshes, different drops and a required_tool_id set.
##
## Expected node layout:
##
##     SalvageObject (StaticBody3D)   <- this script
##     ├── Model  Node3D
##     │   ├── ...fixed meshes...
##     │   └── Detachable  Node3D     <- children vanish one by one as it breaks
##     ├── Collision     CollisionShape3D
##     ├── Sparks        GPUParticles3D  (continuous emitter, starts off)
##     └── Interactable  Area3D         (interactable.gd, hold_to_use = true)

## Fired on every hit, with how much integrity is left (1 = untouched).
signal salvaged(integrity_ratio: float)
signal destroyed

@export_group("Identity")
## Shown in the prompt and on the salvage progress bar.
@export var display_name: String = "Broken Machine"

@export_group("Durability")
## Total salvage damage needed. With the tool's default 34/sec, 100 is ~3 seconds.
@export var max_integrity: float = 100.0
## Item id of the tool this needs, matched against PlayerTool.item_id. Empty means
## anything will do, including the robot's built-in beam. Set it to "scrap_pick"
## and the beam will only scorch the surface.
@export var required_tool_id: String = ""
## Verb for the interaction prompt: "Salvage" for machines, "Mine" for rock.
@export var prompt_verb: String = "Salvage"
## Verb for the progress bar. It belongs to the job rather than the tool, so a
## pick swung at a generator still reads as salvaging.
@export var work_verb: String = "SALVAGING"

@export_group("Drops")
## Spawned when destroyed. Each entry is a pickup scene (scrap.tscn, copper.tscn)
## and carries its own amount, so list a scene twice to drop two piles of it.
@export var drops: Array[PackedScene] = []
## Each of these is rolled separately against `bonus_chance` -- this is how
## "rarely an energy cell" is expressed.
@export var bonus_drops: Array[PackedScene] = []
@export_range(0.0, 1.0) var bonus_chance: float = 0.25
## How far from the centre the drops scatter.
@export var drop_scatter: float = 0.8

@export_group("Feel")
@export var shake_strength: float = 0.015
@export var shake_speed: float = 42.0
## How long sparks and shaking continue after the last hit. Stops the effects
## from stuttering on and off between frames.
@export var active_linger: float = 0.12

# --- Internal ---------------------------------------------------------------

var _integrity: float = 0.0
var _active_timer: float = 0.0
var _model_rest: Vector3 = Vector3.ZERO

@onready var _model: Node3D = $Model
@onready var _detachable: Node3D = get_node_or_null("Model/Detachable") as Node3D
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _interactable: Interactable = $Interactable


func _ready() -> void:
	_integrity = max_integrity
	_model_rest = _model.position

	# Keep the prompt in step with display_name so there is one place to rename.
	_interactable.prompt_verb = prompt_verb
	_interactable.prompt_label = display_name
	_interactable.hold_to_use = true

	# See systems/save_manager.gd for the group contract.
	add_to_group(&"persist")


func _process(delta: float) -> void:
	_active_timer -= delta
	var active := _active_timer > 0.0
	_sparks.emitting = active

	if active:
		# Vibrate while the tool is biting into it.
		var t := Time.get_ticks_msec() / 1000.0 * shake_speed
		_model.position = _model_rest + Vector3(sin(t), 0.0, cos(t * 1.3)) * shake_strength
	elif not _model.position.is_equal_approx(_model_rest):
		_model.position = _model.position.lerp(_model_rest, clampf(12.0 * delta, 0.0, 1.0))


# --- Salvaging --------------------------------------------------------------

## Whether a tool with this item id is up to the job. Built-in tools pass an
## empty id, which only satisfies targets with no requirement of their own.
func accepts_tool(tool_id: String) -> bool:
	return required_tool_id.is_empty() or required_tool_id == tool_id


## The message shown when the player tries the wrong tool. Naming the item is the
## whole point: it tells them what to go and craft.
func get_tool_hint() -> String:
	var item := ItemDB.get_item(required_tool_id)
	var tool_name := item.display_name if item else required_tool_id
	return "%s is too hard for this tool. Needs a %s." % [display_name, tool_name]


## Called by the player's equipped PlayerTool once per frame while it is working.
func apply_salvage(amount: float) -> void:
	if _integrity <= 0.0 or amount <= 0.0:
		return

	_integrity = maxf(_integrity - amount, 0.0)
	_active_timer = active_linger
	_update_detachable_parts()
	salvaged.emit(get_integrity_ratio())

	if _integrity <= 0.0:
		_break_apart()


## Hides the children of Model/Detachable one at a time as integrity falls, so
## the machine visibly loses its pipes and panels before it collapses.
func _update_detachable_parts() -> void:
	if _detachable == null:
		return
	var parts := _detachable.get_children()
	var ratio := get_integrity_ratio()
	for i in parts.size():
		var part := parts[i] as Node3D
		if part == null:
			continue
		# With 4 parts the thresholds land at 0.8, 0.6, 0.4 and 0.2.
		part.visible = ratio > 1.0 - float(i + 1) / float(parts.size() + 1)


func _break_apart() -> void:
	_interactable.enabled = false
	GameEvents.clear_salvage_progress()
	GameEvents.notify("%s dismantled." % display_name, Color(0.95, 0.85, 0.55))
	_spawn_drops()
	destroyed.emit()
	queue_free()


## Drops are parented to whatever contains this machine, so they survive it
## being freed.
func _spawn_drops() -> void:
	var container := get_parent()
	if container == null:
		return

	var to_spawn: Array[PackedScene] = []
	to_spawn.append_array(drops)
	for scene in bonus_drops:
		if randf() <= bonus_chance:
			to_spawn.append(scene)

	for i in to_spawn.size():
		var scene := to_spawn[i]
		if scene == null:
			continue
		var pickup := scene.instantiate() as Node3D
		container.add_child(pickup)
		# Fan the piles out in a ring so they never spawn inside each other.
		var angle := TAU * float(i) / maxf(1.0, float(to_spawn.size())) + randf_range(-0.4, 0.4)
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * drop_scatter * randf_range(0.6, 1.0)
		pickup.global_position = global_position + offset


# --- Queries ----------------------------------------------------------------

## 1.0 = untouched, 0.0 = destroyed.
func get_integrity_ratio() -> float:
	return _integrity / maxf(max_integrity, 0.001)


func is_being_salvaged() -> bool:
	return _active_timer > 0.0


# --- Saving -----------------------------------------------------------------

## Half-dismantled machines stay half-dismantled. Fully destroyed ones are not
## in the tree at save time, so the save manager knows to leave them out.
func save_data() -> Dictionary:
	return {"integrity": _integrity}


func load_data(data: Dictionary) -> void:
	_integrity = clampf(float(data.get("integrity", max_integrity)), 0.0, max_integrity)
	_active_timer = 0.0
	_model.position = _model_rest
	_update_detachable_parts()
	_interactable.enabled = _integrity > 0.0
