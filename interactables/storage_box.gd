extends Structure
class_name StorageBox
## SCRAPLAND -- A crate that holds things. Press E to open it, E again to close.
##
## The box does not implement storage: it owns an Inventory node, the same script
## the robot uses. Stacking, capacity, overflow and saving are therefore already
## solved, and a bigger crate later is a matter of raising slot_count.
##
## Expected node layout:
##
##     StorageBox (StaticBody3D)     <- this script
##     ├── Model         Node3D
##     │   └── LidHinge  Node3D      (pivot at the back edge of the lid)
##     ├── Collision     CollisionShape3D
##     ├── Inventory     Node  (inventory.gd)
##     ├── Interactable  Area3D (interactable.gd)
##     └── Sfx           AudioStreamPlayer3D (crate_sfx.gd)
##
## It finds the container screen through the "container_ui" group, so neither one
## needs a reference to the other. The lid follows GameEvents.container_opened /
## container_closed, which is how it stays in sync if Tab or a load closes the
## panel instead of Esc.

@export_group("Lid")
## Negative: the hinge is at the back, so the lid lifts away from the latch.
@export var open_degrees: float = -112.0
@export var open_seconds: float = 0.38
@export var close_seconds: float = 0.22

@onready var inventory: Inventory = $Inventory
@onready var _interactable: Interactable = $Interactable
@onready var _hinge: Node3D = $Model/LidHinge
@onready var _sfx: Node = $Sfx

var _lid_open: bool = false
var _lid_tween: Tween


func _ready() -> void:
	# Joins the persist group. The Inventory child saves itself separately.
	super()
	_interactable.interacted.connect(_on_interacted)
	# The prompt reports how full the box is, so you can tell at a glance which
	# crate you left the copper in.
	inventory.changed.connect(_refresh_prompt)
	_refresh_prompt()
	GameEvents.container_opened.connect(_on_container_opened)
	GameEvents.container_closed.connect(_on_container_closed)


func _refresh_prompt() -> void:
	_interactable.prompt_verb = "Close" if _lid_open else "Open"
	var used := inventory.get_used_slot_count()
	if used <= 0:
		_interactable.prompt_label = "%s (empty)" % display_name
	else:
		_interactable.prompt_label = "%s (%d/%d)" % [
			display_name, used, inventory.get_slots().size()]


func _on_interacted(_who: Node) -> void:
	var ui := get_tree().get_first_node_in_group(&"container_ui")
	if ui == null:
		push_warning("storage_box.gd: no node in the 'container_ui' group to open.")
		return
	if ui.has_method("is_showing") and bool(ui.call("is_showing", inventory)):
		if ui.has_method("close"):
			ui.call("close")
		return
	if ui.has_method("open_container"):
		ui.call("open_container", inventory, display_name)


func _on_container_opened(inv: Inventory) -> void:
	if inv == inventory:
		_set_lid_open(true)


func _on_container_closed(inv: Inventory) -> void:
	if inv == inventory:
		_set_lid_open(false)


func _set_lid_open(open: bool) -> void:
	if _lid_open == open:
		return
	_lid_open = open
	_refresh_prompt()
	if _lid_tween:
		_lid_tween.kill()
	_lid_tween = create_tween()
	if open:
		_play("play_creak")
		_lid_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_lid_tween.tween_property(_hinge, "rotation:x", deg_to_rad(open_degrees), open_seconds)
	else:
		_lid_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_lid_tween.tween_property(_hinge, "rotation:x", 0.0, close_seconds)
		# The thud is the moment of impact, not the start of the swing.
		_lid_tween.tween_callback(_play.bind("play_thud"))


func _play(method: String) -> void:
	if _sfx and _sfx.has_method(method):
		_sfx.call(method)
