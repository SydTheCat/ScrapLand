extends Structure
class_name Workbench
## SCRAPLAND -- A workbench. Standing near it unlocks the recipes that need one,
## and pressing E on it opens the fabrication screen.
##
## Extends Structure because the player can craft and place these, so one has to
## be able to come back from a save file knowing where it stood.
##
## Expected node layout:
##
##     Workbench (StaticBody3D)     <- this script
##     ├── Model         Node3D
##     ├── Collision     CollisionShape3D
##     ├── BenchZone     Area3D  (mask 2, detects the player)
##     └── Interactable  Area3D  (interactable.gd)
##
## It finds the crafting screen through the "crafting_ui" group, so the bench
## needs no reference to the UI and the UI needs none to the bench.

## Crafting nodes this bench has counted itself towards, so the count can be
## handed back if the bench disappears while the robot is still standing at it.
var _counted: Array[Crafting] = []

@onready var _interactable: Interactable = $Interactable
@onready var _bench_zone: Area3D = $BenchZone


func _ready() -> void:
	# Joins the persist group.
	super()
	_interactable.interacted.connect(_on_interacted)
	_bench_zone.body_entered.connect(_on_body_entered)
	_bench_zone.body_exited.connect(_on_body_exited)
	GameEvents.menu_opened.connect(_on_menu_changed)
	GameEvents.menu_closed.connect(_on_menu_changed)
	# The crafting panel is later in the tree, so its Root does not exist yet.
	_refresh_prompt.call_deferred()


## The Crafting node counts how many benches it is standing in, so overlapping
## benches cannot leave it stuck thinking there is none.
func _on_body_entered(body: Node3D) -> void:
	var crafting := body.get_node_or_null("Crafting") as Crafting
	if crafting and not _counted.has(crafting):
		_counted.append(crafting)
		crafting.add_workbench()


func _on_body_exited(body: Node3D) -> void:
	var crafting := body.get_node_or_null("Crafting") as Crafting
	if crafting and _counted.has(crafting):
		_counted.erase(crafting)
		crafting.remove_workbench()


## A bench that vanishes while the robot is standing at it has to give the count
## back by hand. body_exited does not arrive for an area that is being retired by
## a load, which would otherwise leave the player permanently believing there is
## a workbench nearby.
func _exit_tree() -> void:
	for crafting in _counted:
		if is_instance_valid(crafting):
			crafting.remove_workbench()
	_counted.clear()


func _on_interacted(_who: Node) -> void:
	var ui := get_tree().get_first_node_in_group(&"crafting_ui")
	if ui == null:
		return
	if ui.has_method("is_open") and bool(ui.call("is_open")):
		if ui.has_method("close"):
			ui.call("close")
	elif ui.has_method("open"):
		ui.call("open")
	_refresh_prompt()


func _on_menu_changed(_menu: Node) -> void:
	_refresh_prompt()


func _refresh_prompt() -> void:
	var ui := get_tree().get_first_node_in_group(&"crafting_ui")
	var open := ui != null and ui.has_method("is_open") and bool(ui.call("is_open"))
	_interactable.prompt_verb = "Close" if open else "Use"
