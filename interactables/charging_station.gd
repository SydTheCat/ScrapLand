extends StaticBody3D
class_name ChargingStation
## SCRAPLAND -- The charging station. Repairing this one is the game's first objective.
##
## Two states:
##   BROKEN  lamp off, coughs sparks, does not charge.
##   ONLINE  lamp on, refills your battery while you stand on the pad, and
##           becomes your respawn point.
##
## Standing on the pad charges the battery and restores hull and installed
## upgrades. Pressing E on a working station opens the upgrade menu.

signal repaired

enum Status { BROKEN, ONLINE }

@export_group("State")
## Tick this in the Inspector to test the working station before the inventory
## system exists.
@export var starts_repaired: bool = false

@export_group("Repair Cost")
## Resource id -> amount. Paid when the weld finishes, or instantly on E.
@export var repair_cost: Dictionary = {"scrap_metal": 10, "copper": 3}
## Weld progress needed if you fix it with the repair tool instead of a tap.
@export var weld_needed: float = 70.0

@export_group("Objectives")
@export var objective_while_broken: String = "Find enough scrap to repair the charging station."
@export var objective_when_repaired: String = "Stay powered. Fabricate a workbench (press C)."
## Blueprint granted by getting this station working. Leave empty for none.
@export var unlocks_recipe: String = "basic_workbench"
@export var extra_unlocks: PackedStringArray = PackedStringArray(["cargo_rack", "hull_plating"])

@export_group("Pad service")
## Integrity restored per second to the robot's hull while standing on the pad.
@export var hull_repair_rate: float = 22.0
## Integrity restored per second to each installed upgrade.
@export var upgrade_repair_rate: float = 18.0

@export_group("Appearance")
@export var lamp_energy_online: float = 4.0
## How much the lamp breathes in and out while online and idle.
@export var lamp_pulse_amount: float = 0.35
@export var lamp_pulse_speed: float = 1.6

@export_group("Service glow")
## Interior column that pulses while the pad is charging or repairing.
@export var service_color: Color = Color(0.4, 0.95, 1.0)
@export var service_repair_color: Color = Color(1.0, 0.7, 0.35)
@export var service_light_energy: float = 7.5
@export var service_pulse_speed: float = 5.0
@export var service_field_alpha: float = 0.18

@export_group("Broken Behaviour")
@export var spark_interval_min: float = 2.0
@export var spark_interval_max: float = 5.0

@export_group("Saving")
## Getting the charger working is a milestone worth keeping, so it writes a
## quiet save the moment it comes online.
@export var autosave_on_repair: bool = true

# --- Internal ---------------------------------------------------------------

var _status: Status = Status.BROKEN
var _spark_timer: float = 0.0
var _pulse_time: float = 0.0
var _service_pulse: float = 0.0
## Smooth 0-1 mix for the interior glow.
var _service_amount: float = 0.0
## Stays hot for a moment after the repair tool stops welding.
var _weld_glow_timer: float = 0.0
var _service_field_mat: StandardMaterial3D
## The battery currently standing on the pad, if any.
var _occupant: RobotBattery
## Progress toward a tool-welded repair. Instant E repair ignores this.
var _weld: float = 0.0

@onready var _lamp: OmniLight3D = $Model/Lamp
@onready var _service_light: OmniLight3D = get_node_or_null("Model/ServiceGlow")
@onready var _service_field: MeshInstance3D = get_node_or_null("Model/ServiceField")
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _interactable: Interactable = $Interactable
@onready var _charge_zone: Area3D = $ChargeZone
@onready var _sfx: AudioStreamPlayer3D = get_node_or_null("Sfx") as AudioStreamPlayer3D


func _ready() -> void:
	_interactable.interacted.connect(_on_interacted)
	_charge_zone.body_entered.connect(_on_body_entered)
	_charge_zone.body_exited.connect(_on_body_exited)

	_apply_status(Status.ONLINE if starts_repaired else Status.BROKEN)
	_spark_timer = randf_range(spark_interval_min, spark_interval_max)
	_prepare_service_field()
	_prepare_service_sound()
	GameEvents.menu_opened.connect(_on_menu_changed)
	GameEvents.menu_closed.connect(_on_menu_changed)
	SaveManager.loaded.connect(_on_save_loaded)

	# See systems/save_manager.gd for the group contract.
	add_to_group(&"persist")


func _process(delta: float) -> void:
	if _status == Status.BROKEN:
		_process_broken_sparks(delta)
		_weld_glow_timer = maxf(_weld_glow_timer - delta, 0.0)
		_process_service_glow(delta, _weld_glow_timer > 0.0)
	else:
		_process_lamp_pulse(delta)
		_service_pad(delta)
		_process_service_glow(delta, _is_servicing_robot())


## A dying machine that occasionally spits sparks reads as "this needs fixing"
## without any tutorial text.
func _process_broken_sparks(delta: float) -> void:
	_spark_timer -= delta
	if _spark_timer > 0.0:
		return
	_spark_timer = randf_range(spark_interval_min, spark_interval_max)
	burst_sparks()


func _process_lamp_pulse(delta: float) -> void:
	if _lamp == null:
		return
	_pulse_time += delta * lamp_pulse_speed
	_lamp.light_energy = lamp_energy_online * (1.0 - lamp_pulse_amount * 0.5 * (1.0 - cos(_pulse_time)))


func _prepare_service_field() -> void:
	if _service_field == null:
		return
	var mat := _service_field.get_active_material(0) as StandardMaterial3D
	if mat == null:
		return
	_service_field_mat = mat.duplicate() as StandardMaterial3D
	_service_field.material_override = _service_field_mat
	_service_field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_service_field.visible = false


func _is_servicing_robot() -> bool:
	if _occupant == null:
		return false
	if _occupant.get_ratio() < 0.995:
		return true
	var robot := _occupant.get_parent()
	if robot == null:
		return false
	var hull := robot.get_node_or_null("Hull") as RobotHull
	if hull and hull.needs_repair():
		return true
	var upgrades := robot.get_node_or_null("Upgrades")
	return upgrades != null and upgrades.has_method("needs_repair") and bool(upgrades.call("needs_repair"))


func _process_service_glow(delta: float, active: bool) -> void:
	var target := 1.0 if active else 0.0
	var rate := 7.0 if active else 5.0
	_service_amount = move_toward(_service_amount, target, delta * rate)
	if _service_amount <= 0.001 and not active:
		if _service_light:
			_service_light.light_energy = 0.0
			_service_light.visible = false
		if _service_field:
			_service_field.visible = false
		_update_service_sound(false)
		return

	_service_pulse += delta * service_pulse_speed
	var pulse := 0.55 + 0.45 * (0.5 + 0.5 * sin(_service_pulse))
	var strength := _service_amount * pulse
	var colour := service_repair_color if _status == Status.BROKEN else service_color

	if _service_light:
		_service_light.visible = true
		_service_light.light_color = colour
		_service_light.light_energy = service_light_energy * strength

	if _service_field_mat:
		_service_field_mat.albedo_color = Color(colour.r, colour.g, colour.b, service_field_alpha * strength)
	if _service_field:
		_service_field.visible = true

	if _lamp and _status == Status.ONLINE:
		_lamp.light_energy += 3.2 * strength
	_update_service_sound(active)


# --- Status -----------------------------------------------------------------

func _apply_status(status: Status) -> void:
	_status = status
	var online := status == Status.ONLINE

	if _lamp:
		_lamp.visible = online
		_lamp.light_energy = lamp_energy_online

	_refresh_prompt()

	GameEvents.set_objective(objective_when_repaired if online else objective_while_broken)


func needs_repair() -> bool:
	return _status == Status.BROKEN


func get_display_name() -> String:
	return "Regeneration Station"


## Remaining work, 1 at the start of a weld and 0 when it is about to finish.
## The salvage bar treats this the same way it treats a wreck's integrity.
func get_integrity_ratio() -> float:
	return 1.0 - clampf(_weld / maxf(weld_needed, 0.01), 0.0, 1.0)


func apply_repair(amount: float) -> void:
	if not needs_repair():
		return
	_weld += maxf(amount, 0.0)
	_weld_glow_timer = 0.28
	if _weld < weld_needed:
		return
	var who := get_tree().get_first_node_in_group(&"player")
	if not try_repair(who):
		_weld = weld_needed * 0.98


func try_repair(who: Node) -> bool:
	if _status == Status.ONLINE:
		return false
	if who == null:
		GameEvents.notify("NEEDS: %s" % format_repair_cost(), Color(1.0, 0.7, 0.3))
		return false
	var missing := _missing_from(who)
	if not missing.is_empty():
		GameEvents.notify("STILL NEEDS: %s" % _format_amounts(missing, " more "), Color(1.0, 0.7, 0.3))
		return false
	_spend_from(who)
	repair()
	return true


func repair() -> void:
	if _status == Status.ONLINE:
		return

	_weld = 0.0
	_apply_status(Status.ONLINE)
	burst_sparks()
	GameEvents.notify("REGENERATION STATION ONLINE", Color(0.4, 1.0, 0.8))
	_grant_unlocks()
	repaired.emit()

	# If the player is already standing on the pad, start charging immediately.
	if _occupant:
		_claim_respawn_point(_occupant)
		_occupant.set_charging(true)

	if autosave_on_repair:
		SaveManager.save_game(true)


func burst_sparks() -> void:
	if _sparks == null:
		return
	_sparks.emitting = true
	_sparks.restart()


func is_online() -> bool:
	return _status == Status.ONLINE


func _on_save_loaded() -> void:
	if is_online():
		_grant_unlocks()


func _grant_unlocks() -> void:
	if not unlocks_recipe.is_empty():
		GameEvents.unlock_recipe(unlocks_recipe)
	for extra_id in extra_unlocks:
		if not String(extra_id).is_empty():
			GameEvents.unlock_recipe(String(extra_id))


# --- Saving -----------------------------------------------------------------

func save_data() -> Dictionary:
	return {"online": is_online(), "weld": _weld}


func load_data(data: Dictionary) -> void:
	# _apply_status also resets the prompt verb and the objective text, so a
	# loaded game shows the right instruction with no extra work.
	_apply_status(Status.ONLINE if bool(data.get("online", false)) else Status.BROKEN)
	_weld = float(data.get("weld", 0.0))
	if is_online():
		_weld = 0.0


# --- Interaction ------------------------------------------------------------

func _on_interacted(who: Node) -> void:
	if _status == Status.ONLINE:
		_open_upgrade_menu()
		return
	try_repair(who)


func _open_upgrade_menu() -> void:
	var ui := get_tree().get_first_node_in_group(&"upgrade_ui")
	if ui == null:
		GameEvents.notify("No upgrade bay connected.", Color(1.0, 0.7, 0.35))
		return
	if ui.has_method("is_showing") and bool(ui.call("is_showing", self)):
		if ui.has_method("close"):
			ui.call("close")
		return
	if ui.has_method("open_for"):
		ui.call("open_for", self)
	_refresh_prompt()


func _on_menu_changed(_menu: Node) -> void:
	_refresh_prompt()


func _refresh_prompt() -> void:
	if _interactable == null:
		return
	if _status == Status.BROKEN:
		_interactable.prompt_verb = "Repair"
		_interactable.prompt_label = get_display_name()
		return
	var ui := get_tree().get_first_node_in_group(&"upgrade_ui")
	var showing := ui != null and ui.has_method("is_showing") and bool(ui.call("is_showing", self))
	_interactable.prompt_verb = "Close" if showing else "Upgrade"
	_interactable.prompt_label = get_display_name()


## "10 Scrap Metal, 3 Copper" -- built from repair_cost so editing the Inspector
## changes the message too.
func format_repair_cost() -> String:
	return _format_amounts(repair_cost, " ")


func _count_from(who: Node, item_id: String) -> int:
	var total := 0
	var inventory := who.get_node_or_null("Inventory") as Inventory
	if inventory:
		total += inventory.count(item_id)
	var hotbar := who.get_node_or_null("Hotbar") as Hotbar
	if hotbar:
		total += hotbar.count(item_id)
	return total


func _missing_from(who: Node) -> Dictionary:
	var missing := {}
	for id in repair_cost:
		var need := int(repair_cost[id])
		var have := _count_from(who, String(id))
		if have < need:
			missing[id] = need - have
	return missing


func _spend_from(who: Node) -> void:
	for id in repair_cost:
		var left := int(repair_cost[id])
		var inventory := who.get_node_or_null("Inventory") as Inventory
		if inventory:
			left -= inventory.remove_item(String(id), left)
		var hotbar := who.get_node_or_null("Hotbar") as Hotbar
		if left > 0 and hotbar:
			hotbar.remove_item(String(id), left)


func _format_amounts(amounts: Dictionary, infix: String) -> String:
	var parts: PackedStringArray = []
	for id in amounts:
		parts.append("%d%s%s" % [int(amounts[id]), infix, String(id).capitalize()])
	return ", ".join(parts)


# --- Charging pad -----------------------------------------------------------

func _on_body_entered(body: Node3D) -> void:
	var battery := body.get_node_or_null("Battery") as RobotBattery
	if battery == null:
		return
	_occupant = battery
	if _status == Status.ONLINE:
		_claim_respawn_point(battery)
		battery.set_charging(true)


func _service_pad(delta: float) -> void:
	if _occupant == null:
		return
	var robot := _occupant.get_parent()
	if robot == null:
		return
	var hull := robot.get_node_or_null("Hull") as RobotHull
	if hull and hull.needs_repair():
		var was_hurt := true
		hull.repair(hull_repair_rate * delta)
		if was_hurt and not hull.needs_repair():
			GameEvents.notify("CHASSIS RESTORED", Color(0.5, 1.0, 0.72))
	var upgrades := robot.get_node_or_null("Upgrades")
	if upgrades and upgrades.has_method("needs_repair") and upgrades.has_method("repair_all"):
		var parts_hurt: bool = bool(upgrades.call("needs_repair"))
		upgrades.call("repair_all", upgrade_repair_rate * delta)
		if parts_hurt and upgrades.has_method("needs_repair") and not bool(upgrades.call("needs_repair")):
			GameEvents.notify("UPGRADES RESTORED", Color(0.5, 0.95, 1.0))


func _on_body_exited(body: Node3D) -> void:
	var battery := body.get_node_or_null("Battery") as RobotBattery
	if battery == null or battery != _occupant:
		return
	battery.set_charging(false)
	_occupant = null


## Robots reboot at the last working charger they touched.
func _claim_respawn_point(battery: RobotBattery) -> void:
	battery.respawn_position = to_global(Vector3(0.0, 0.2, 0.0))


# --- Sound ------------------------------------------------------------------

func _prepare_service_sound() -> void:
	if _sfx == null or _sfx.stream == null:
		return
	var stream := _sfx.stream.duplicate()
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true
	_sfx.stream = stream


func _update_service_sound(active: bool) -> void:
	if _sfx == null:
		return
	if active:
		if not _sfx.playing:
			_sfx.play()
	elif _sfx.playing:
		_sfx.stop()
