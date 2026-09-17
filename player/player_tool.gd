extends Node
class_name PlayerTool
## SCRAPLAND -- One tool the robot can have equipped. Attach as a child of the
## player's Tools node (see equipment.gd), one node per tool.
##
## Every tool works the same way: hold the button while pointing at something
## harvestable and it grinds the thing down, costing energy and animating the
## arm. What separates a salvage beam from a pick is entirely the numbers and the
## work it is allowed to do, so this one script covers both and the differences
## live in the Inspector.
##
## It reuses the Interactor's existing targeting rather than raycasting on its
## own, so "what am I pointing at" is decided in exactly one place.

signal work_started(target: Node)
signal work_stopped

@export_group("Identity")
@export var display_name: String = "Salvage Beam"
## Inventory item that grants this tool, matched against a target's
## required_tool_id. Leave empty for a tool built into the robot, which is always
## available and can work anything that has no requirement of its own.
@export var item_id: String = ""
## Always selectable from the hotbar, even if the matching item is not in the
## cargo hold. The salvage beam uses this.
@export var always_owned: bool = false

@export_group("Power")
## Damage per second. At 34, a 100-integrity machine takes about three seconds.
@export var damage_per_second: float = 34.0
## Energy drained per second while running.
@export var energy_per_second: float = 1.2

@export_group("Work")
## Salvage grinds things down. Repair welds hull and broken machines back up.
@export_enum("Salvage", "Repair") var work_kind: int = 0
## Hull restored per second while welding yourself. World wrecks use this as
## weld progress per second.
@export var repair_per_second: float = 16.0
## Spent from cargo or the hotbar while patching your own chassis. World
## wrecks bill their own materials when the weld finishes.
@export var repair_item_id: String = "scrap_metal"
## How much hull one piece of scrap is worth.
@export var repair_per_item: float = 22.0

@export_group("Arm Animation")
## Positive angles swing the arm forward and down.
@export var arm_aim_degrees: float = 62.0
@export var arm_speed: float = 12.0
## Tools that chop rather than hold steady. The pick uses this; the beam does not.
@export var swing_enabled: bool = false
@export var swing_degrees: float = 30.0
@export var swing_speed: float = 8.0

@export_group("Sound")
## Seconds between blips. Short values blur into a continuous buzz; long ones
## read as separate impacts.
@export var buzz_interval: float = 0.07
@export var buzz_frequency_min: float = 120.0
@export var buzz_frequency_max: float = 190.0
@export var buzz_length_scale: float = 1.6

@export_group("Model")
## The mesh on the robot's arm for this tool, shown only while equipped. Path is
## relative to this node, e.g. "../../RobotModel/ArmRight/ToolAttachment/PickHead".
@export var attachment_path: NodePath

# --- Internal ---------------------------------------------------------------

var _equipped: bool = false
## Non-null while actually working, used to know when to clear the HUD bar.
## A SalvageObject or a Structure -- both answer the same salvage methods.
var _target: Node
## The target we have already complained about, so the wrong-tool message does
## not repeat every frame.
var _warned_target: Node
var _buzz_timer: float = 0.0
var _swing_time: float = 0.0
var _arm_rest_x: float = 0.0
var _warned_about_power: bool = false
var _warned_about_parts: bool = false
var _warned_idle: bool = false
## Scrap already paid for but not yet welded into the chassis.
var _repair_credit: float = 0.0

@onready var _robot: Player = get_parent().get_parent() as Player
@onready var _interactor: Interactor = _robot.get_node_or_null("Interactor") as Interactor
@onready var _battery: RobotBattery = _robot.get_node_or_null("Battery") as RobotBattery
@onready var _inventory: Inventory = _robot.get_node_or_null("Inventory") as Inventory
@onready var _hotbar: Hotbar = _robot.get_node_or_null("Hotbar") as Hotbar
@onready var _hull: Node = _robot.get_node_or_null("Hull")
@onready var _arm: Node3D = _robot.get_node_or_null("RobotModel/ArmRight") as Node3D
@onready var _beeper: Node = _robot.get_node_or_null("Beeper")
@onready var _attachment: Node3D = get_node_or_null(attachment_path) as Node3D


func _ready() -> void:
	# Equipment switches exactly one tool on straight after this.
	set_process(false)
	if _attachment:
		_attachment.visible = false

	if _robot == null:
		push_error("player_tool.gd (%s): expected to be a child of the player's Tools node." % name)
		return
	if _arm:
		_arm_rest_x = _arm.rotation.x
	if _interactor == null:
		push_warning("player_tool.gd (%s): no Interactor on the player; cannot aim." % name)


func _process(delta: float) -> void:
	var target := _get_target()
	# Build mode clears actions_enabled, so left mouse places a structure instead
	# of firing whatever is in the robot's hand.
	var holding := _is_button_held() and _robot.can_move and _robot.actions_enabled
	var working := false

	if target and holding:
		if work_kind == 1 or target.accepts_tool(item_id):
			working = _work(target, delta)
		else:
			_warn_wrong_tool(target)
	elif holding and work_kind == 1:
		_warn_nothing_to_repair()

	if not holding:
		_warned_target = null
		_warned_about_parts = false
		_warned_idle = false
	if not working:
		_stop()

	_animate_arm(delta, working)


# --- Equipping --------------------------------------------------------------

## Called by equipment.gd. An unequipped tool does nothing at all and its mesh
## comes off the arm.
func set_equipped(on: bool) -> void:
	if _equipped == on:
		return
	_equipped = on
	set_process(on)
	if _attachment:
		_attachment.visible = on
	if not on:
		_repair_credit = 0.0
		_stop()
		# The lerp in _animate_arm stops with _process, so put the arm back by hand.
		if _arm:
			_arm.rotation.x = _arm_rest_x


func is_equipped() -> bool:
	return _equipped


## True for tools built into the robot, which need no inventory item.
func is_built_in() -> bool:
	return always_owned or item_id.is_empty()


# --- Working ----------------------------------------------------------------

## Only ever works on whatever the Interactor has already picked out, so the
## highlight the player sees and the thing being cut are always the same object.
func _get_target() -> Node:
	if work_kind == 1:
		return _get_repair_target()
	if _interactor == null:
		return null
	var focused := _interactor.get_focused()
	if focused == null or not focused.enabled:
		return null
	var parent := focused.get_parent()
	if parent is SalvageObject:
		return parent
	var structure := parent as Structure
	if structure and structure.is_deconstructible():
		return structure
	return null


func _get_repair_target() -> Node:
	if _interactor:
		var focused := _interactor.get_focused()
		if focused and focused.enabled:
			var parent := focused.get_parent()
			if parent and parent.has_method("needs_repair") and bool(parent.call("needs_repair")):
				return parent
	if _hull and _hull.has_method("needs_repair") and bool(_hull.call("needs_repair")):
		return _hull
	return null


func _is_button_held() -> bool:
	if Input.is_action_pressed(&"tool_primary"):
		return true
	# E is also "interact". Wrecks use Hold E to salvage; boxes and benches use
	# a tap of E to open, so the beam must not start packing them on that press.
	if Input.is_action_pressed(&"interact") and _interactor:
		var focused := _interactor.get_focused()
		return focused != null and focused.hold_to_use
	return false


## Returns false if the work could not happen (flat battery, or the target died).
func _work(target: Node, delta: float) -> bool:
	# Powered tools cost energy. consume() refuses when there is not enough,
	# which is what stops a dead robot from mining its way back to life.
	if _battery and not _battery.consume(energy_per_second * delta):
		if not _warned_about_power:
			_warned_about_power = true
			GameEvents.notify("Not enough power to run the %s." % display_name, Color(1, 0.45, 0.35))
		return false

	_warned_about_power = false
	if _target != target:
		_target = target
		work_started.emit(target)

	if work_kind == 1:
		return _work_repair(target, delta)

	target.apply_salvage(damage_per_second * delta)

	# That hit may have finished it off, in which case it has already cleared the
	# progress bar and is queued for deletion. Updating the bar now would flash
	# it back to full for one frame.
	if target.get_integrity_ratio() <= 0.0:
		_target = null
		return false

	GameEvents.set_salvage_progress(
		target.get_integrity_ratio(), "%s — %s" % [target.work_verb, _target_name(target)])
	_buzz(delta)
	return true


func _work_repair(target: Node, delta: float) -> bool:
	var amount := repair_per_second * delta
	if target == _hull:
		if not _pay_for_hull(amount):
			return false
		_hull.call("repair", amount)
		var ratio := float(_hull.call("get_ratio"))
		if ratio >= 0.999:
			GameEvents.notify("CHASSIS: patched. Try not to fall off anything.", Color(0.6, 0.9, 1.0))
			GameEvents.clear_salvage_progress()
			_target = null
			return false
		# HUD bar fills as work completes: passing remaining damage makes it grow.
		GameEvents.set_salvage_progress(1.0 - ratio, "REPAIRING — Chassis")
	else:
		target.call("apply_repair", amount)
		if target.has_method("needs_repair") and not bool(target.call("needs_repair")):
			GameEvents.clear_salvage_progress()
			_target = null
			return false
		var left := 1.0
		if target.has_method("get_integrity_ratio"):
			left = float(target.call("get_integrity_ratio"))
		GameEvents.set_salvage_progress(left, "REPAIRING — %s" % _target_name(target))
	_buzz(delta)
	return true


func _pay_for_hull(amount: float) -> bool:
	if repair_item_id.is_empty() or repair_per_item <= 0.0:
		return true
	if _repair_credit + 0.0001 < amount:
		if _parts_count() <= 0:
			if not _warned_about_parts:
				_warned_about_parts = true
				GameEvents.notify("Need scrap metal to weld the chassis.", Color(1, 0.7, 0.35))
			return false
		_spend_one_part()
		_repair_credit += repair_per_item
	_repair_credit = maxf(0.0, _repair_credit - amount)
	return true


func _parts_count() -> int:
	var total := 0
	if _inventory:
		total += _inventory.count(repair_item_id)
	if _hotbar:
		total += _hotbar.count(repair_item_id)
	return total


func _spend_one_part() -> void:
	if _inventory and _inventory.count(repair_item_id) > 0:
		_inventory.remove_item(repair_item_id, 1)
		return
	if _hotbar:
		_hotbar.remove_item(repair_item_id, 1)


func _warn_nothing_to_repair() -> void:
	if _warned_idle:
		return
	_warned_idle = true
	GameEvents.notify("Nothing here needs a weld.", Color(0.75, 0.85, 0.95))


func _stop() -> void:
	if _target == null:
		return
	_target = null
	_buzz_timer = 0.0
	_swing_time = 0.0
	GameEvents.clear_salvage_progress()
	work_stopped.emit()


## Tells the player which tool the job actually needs, once per target rather
## than once per frame.
func _warn_wrong_tool(target: Node) -> void:
	if _warned_target == target:
		return
	_warned_target = target
	GameEvents.notify(target.get_tool_hint(), Color(1, 0.7, 0.35))


func _target_name(target: Node) -> String:
	if target.has_method("get_display_name"):
		return String(target.call("get_display_name"))
	return String(target.get("display_name"))


# --- Presentation -----------------------------------------------------------

## Holds the arm forward while working, or chops with it for swinging tools, and
## lets it fall back afterwards.
func _animate_arm(delta: float, working: bool) -> void:
	if _arm == null:
		return

	var target_angle := _arm_rest_x
	if working:
		target_angle = deg_to_rad(arm_aim_degrees)
		if swing_enabled:
			_swing_time += delta * swing_speed
			target_angle += deg_to_rad(sin(_swing_time) * swing_degrees)

	_arm.rotation.x = lerpf(_arm.rotation.x, target_angle, clampf(arm_speed * delta, 0.0, 1.0))


## Rapid low blips at slightly random pitches read as a grinder; slow ones read
## as a pick hitting rock.
func _buzz(delta: float) -> void:
	if _beeper == null or not _beeper.has_method("beep"):
		return
	_buzz_timer -= delta
	if _buzz_timer > 0.0:
		return
	_buzz_timer = buzz_interval
	_beeper.call("beep",
		randf_range(buzz_frequency_min, buzz_frequency_max),
		buzz_interval * buzz_length_scale)
