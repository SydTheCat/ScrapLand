extends Node3D
class_name ResourcePickup
## SCRAPLAND -- A pile of resources lying in the world, collectible with E.
##
## Expected node layout (see scrap.tscn / copper.tscn / energy_cell.tscn):
##
##     ScrapPile (Node3D)        <- this script
##     ├── Model  Node3D         <- everything visual; gets bobbed and spun
##     └── Interactable  Area3D  <- interactable.gd
##         └── Shape  CollisionShape3D
##
## Set `item` to one of the .tres files in resources/items/ and `amount` to how
## much this pile is worth. The prompt text and the pickup notification both
## come from the item data, so nothing here needs editing per resource type.
##
## Collecting a pile does not delete it on the spot: it arcs across into the
## robot's chest and shrinks away. The items land in the inventory immediately --
## only the visual is delayed -- and the pile takes itself out of play the instant
## it is collected. See _begin_flight().

## Emitted after a successful pickup, with what is left (0 if fully collected).
signal collected(item: ItemData, amount: int, remaining: int)

@export_group("Contents")
@export var item: ItemData
@export var amount: int = 3

@export_group("Idle Motion")
## A slow spin and bob is what separates "collectible" from "scenery".
@export var spin_degrees_per_second: float = 25.0
@export var bob_height: float = 0.05
@export var bob_speed: float = 1.6

@export_group("Collection")
## Seconds the pile spends flying into the robot. Short on purpose: this should
## read as magnetic, not as a cutscene.
@export var flight_time: float = 0.3
## How high the pile arcs on the way in. Zero flies dead straight.
@export var flight_arc: float = 0.4
## Where on the robot the pile lands, measured from its feet. Chest height.
@export var flight_target_offset: Vector3 = Vector3(0.0, 0.65, 0.0)
## Multiplies the idle spin while flying, so it visibly tumbles in.
@export var flight_spin_multiplier: float = 9.0

@onready var model: Node3D = $Model
@onready var _interactable: Interactable = $Interactable

var _model_rest_y: float = 0.0
var _model_rest_scale: Vector3 = Vector3.ONE
## Randomised so a field of pickups does not bob in unison.
var _bob_offset: float = 0.0

## The robot this pile is flying towards. Non-null means it has already been
## collected and is only still here to finish the animation.
var _flying_to: Node3D
var _flight_elapsed: float = 0.0
var _flight_from: Vector3 = Vector3.ZERO


func _ready() -> void:
	_model_rest_y = model.position.y
	_model_rest_scale = model.scale
	_bob_offset = randf() * TAU

	_interactable.interacted.connect(_on_interacted)
	_refresh_prompt()

	# Piles dropped by a dismantled machine get an engine-generated name like
	# "@ResourcePickup@31". Those contain characters Godot will not let us set by
	# hand, which would break the save manager's ability to put the pile back
	# under the same node path. Give ourselves a plain unique name instead.
	if String(name).begins_with("@"):
		name = "Pickup_%d" % get_instance_id()

	# See systems/save_manager.gd for the group contract.
	add_to_group(&"persist")


func _process(delta: float) -> void:
	if _flying_to != null:
		_advance_flight(delta)
		return

	model.rotate_y(deg_to_rad(spin_degrees_per_second) * delta)
	var bob := sin(Time.get_ticks_msec() / 1000.0 * bob_speed + _bob_offset)
	model.position.y = _model_rest_y + bob * bob_height


## Keeps the "E — Collect Scrap Metal" text in sync with the item and amount.
func _refresh_prompt() -> void:
	if item == null:
		_interactable.enabled = false
		return
	_interactable.enabled = true
	_interactable.prompt_verb = "Collect"
	_interactable.prompt_label = "%s (%d)" % [item.display_name, amount]


func _on_interacted(who: Node) -> void:
	var inventory := who.get_node_or_null("Inventory") as Inventory
	if inventory == null:
		return

	var leftover := inventory.add_item(item, amount)
	var picked_up := amount - leftover

	if picked_up <= 0:
		GameEvents.notify("Inventory full. Some things must be left behind.", Color(1, 0.6, 0.3))
		return

	GameEvents.notify("+%d %s" % [picked_up, item.display_name], item.color)
	amount = leftover
	collected.emit(item, picked_up, leftover)

	if amount <= 0:
		var collector := who as Node3D
		if collector:
			_begin_flight(collector)
		else:
			queue_free()
	else:
		# Partially collected: the pile shrinks but stays put.
		_refresh_prompt()


# --- Collection animation ---------------------------------------------------

## Hands the pile over to the fly-in animation.
##
## Everything that makes this pile part of the world stops here rather than when
## the animation ends. It cannot be collected twice, the Interactor drops it, and
## it leaves the persist group -- otherwise saving during the half second it is in
## the air would record an empty pile hanging in mid-air, and loading would put it
## back.
func _begin_flight(collector: Node3D) -> void:
	_flying_to = collector
	_flight_from = global_position
	_flight_elapsed = 0.0

	remove_from_group(&"persist")
	_interactable.enabled = false
	# Takes it out of the Interactor's overlap list now, instead of leaving a dead
	# candidate there until the node is freed.
	_interactable.monitorable = false
	# Gives the name back, in case a load respawns this same pile before the
	# animation has run out.
	name = "Collected_%d" % get_instance_id()

	# Start from the rest pose rather than wherever the bob happened to be.
	model.position.y = _model_rest_y


func _advance_flight(delta: float) -> void:
	if not is_instance_valid(_flying_to):
		queue_free()
		return

	_flight_elapsed += delta
	var t := clampf(_flight_elapsed / maxf(flight_time, 0.01), 0.0, 1.0)
	# Squared, so the pile peels off the ground slowly and then snaps in.
	var eased := t * t

	# Aimed at where the robot is now, not where it was, so walking away while a
	# pile is in the air does not leave it flying at empty ground.
	var destination := _flying_to.global_position + flight_target_offset
	global_position = _flight_from.lerp(destination, eased)
	# A half sine adds height that is back to zero exactly on arrival.
	global_position.y += sin(t * PI) * flight_arc

	model.rotate_y(deg_to_rad(spin_degrees_per_second) * flight_spin_multiplier * delta)
	model.scale = _model_rest_scale * lerpf(1.0, 0.1, eased)

	if t >= 1.0:
		queue_free()


# --- Saving -----------------------------------------------------------------

## Piles dropped by salvaging do not exist in world.tscn, so the save has to
## carry enough to rebuild them from scratch: what they hold and where they lie.
func save_data() -> Dictionary:
	return {
		"item": item.id if item else "",
		"amount": amount,
		"position": global_position,
	}


func load_data(data: Dictionary) -> void:
	var id := String(data.get("item", ""))
	if not id.is_empty():
		var found := ItemDB.get_item(id)
		if found:
			item = found
		else:
			push_warning("resource_pickup: save file mentions unknown item '%s'." % id)
	amount = int(data.get("amount", amount))
	global_position = data.get("position", global_position)
	_refresh_prompt()
