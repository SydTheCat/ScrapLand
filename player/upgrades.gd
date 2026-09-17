extends Node
class_name RobotUpgrades
## SCRAPLAND -- Installed robot parts. One piece per slot.
##
## The regeneration station repairs these while you stand on the pad, and the
## upgrade menu (E at a working station) is how they go on and come off.
## Markers live under RobotModel/UpgradePoints.

signal changed

const SLOTS: PackedStringArray = ["back", "chassis", "head", "arm", "leg"]
const SLOT_NODES := {
	"back": "BackSlot",
	"chassis": "ChassisSlot",
	"head": "HeadSlot",
	"arm": "ArmSlot",
	"leg": "LegSlot",
}

var _equipped: Dictionary = {}
var _visuals: Dictionary = {}
var _base_slots: int = 20
var _base_energy: float = 100.0
var _base_hull: float = 100.0

@onready var _robot: Player = get_parent() as Player
@onready var _inventory: Inventory = get_parent().get_node_or_null("Inventory") as Inventory
@onready var _battery: RobotBattery = get_parent().get_node_or_null("Battery") as RobotBattery
@onready var _hull: RobotHull = get_parent().get_node_or_null("Hull") as RobotHull
@onready var _points: Node3D = get_parent().get_node_or_null("RobotModel/UpgradePoints") as Node3D


func _ready() -> void:
	if _inventory:
		_base_slots = _inventory.slot_count
	if _battery:
		_base_energy = _battery.max_energy
	if _hull:
		_base_hull = _hull.max_integrity
	add_to_group(&"persist")
	SaveManager.loaded.connect(_on_save_loaded)
	_recompute()


func get_slots() -> PackedStringArray:
	return SLOTS


func _on_save_loaded() -> void:
	# Hull and inventory restore their own ceilings from the save. Re-apply
	# bonuses afterwards so load order cannot wipe an installed part.
	_recompute()


func get_equipped_id(slot: String) -> String:
	var entry: Variant = _equipped.get(slot, null)
	if entry is Dictionary:
		return String(entry.get("id", ""))
	return ""


func get_equipped_item(slot: String) -> ItemData:
	return ItemDB.get_item(get_equipped_id(slot))


func get_integrity(slot: String) -> float:
	var entry: Variant = _equipped.get(slot, null)
	if entry is Dictionary:
		return float(entry.get("integrity", 0.0))
	return 0.0


func get_max_integrity(slot: String) -> float:
	var item := get_equipped_item(slot)
	if item:
		return maxf(item.upgrade_max_integrity, 1.0)
	return 1.0


func get_integrity_ratio(slot: String) -> float:
	return get_integrity(slot) / get_max_integrity(slot)


func is_slot_filled(slot: String) -> bool:
	return not get_equipped_id(slot).is_empty()


func needs_repair() -> bool:
	for slot in SLOTS:
		if is_slot_filled(slot) and get_integrity(slot) < get_max_integrity(slot) - 0.25:
			return true
	return false


func repair_all(amount: float) -> void:
	if amount <= 0.0:
		return
	var any := false
	for slot in SLOTS:
		if not is_slot_filled(slot):
			continue
		var cap := get_max_integrity(slot)
		var now := get_integrity(slot)
		if now >= cap:
			continue
		_equipped[slot]["integrity"] = clampf(now + amount, 0.0, cap)
		any = true
	if any:
		changed.emit()


func install(item: ItemData) -> bool:
	if item == null or not item.is_upgrade():
		return false
	var slot := item.upgrade_slot
	if not SLOTS.has(slot):
		return false
	if is_slot_filled(slot):
		GameEvents.notify("%s is occupied." % slot.capitalize(), Color(1.0, 0.7, 0.35))
		return false
	if _inventory == null or _inventory.count(item.id) <= 0:
		GameEvents.notify("You are not carrying a %s." % item.display_name, Color(1.0, 0.7, 0.35))
		return false
	_inventory.remove_item(item.id, 1)
	_equipped[slot] = {
		"id": item.id,
		"integrity": item.upgrade_max_integrity,
		"extra_inventory_slots": item.extra_inventory_slots,
		"extra_max_energy": item.extra_max_energy,
		"extra_max_hull": item.extra_max_hull,
	}
	_recompute()
	GameEvents.notify("INSTALLED: %s" % item.display_name, item.color)
	return true


func uninstall(slot: String) -> bool:
	var item := get_equipped_item(slot)
	if item == null:
		return false
	if _inventory == null or _inventory.add_item(item, 1) > 0:
		GameEvents.notify("Cargo is full.", Color(1.0, 0.7, 0.35))
		return false
	_equipped.erase(slot)
	_recompute()
	GameEvents.notify("REMOVED: %s" % item.display_name, item.color)
	return true


func items_for_slot(slot: String) -> Array[ItemData]:
	var found: Array[ItemData] = []
	if _inventory == null:
		return found
	var seen: PackedStringArray = []
	for inv_slot in _inventory.get_slots():
		if inv_slot.is_empty() or not inv_slot.item.is_upgrade():
			continue
		if inv_slot.item.upgrade_slot != slot:
			continue
		if inv_slot.item.id in seen:
			continue
		seen.append(inv_slot.item.id)
		found.append(inv_slot.item)
	return found


func save_data() -> Dictionary:
	return {"equipped": _equipped.duplicate(true)}


func load_data(data: Dictionary) -> void:
	_equipped.clear()
	var saved: Variant = data.get("equipped", {})
	if saved is Dictionary:
		for slot in saved:
			if not SLOTS.has(String(slot)):
				continue
			var entry: Variant = saved[slot]
			if entry is Dictionary and not String(entry.get("id", "")).is_empty():
				_equipped[String(slot)] = {
					"id": String(entry.get("id", "")),
					"integrity": float(entry.get("integrity", 0.0)),
					"extra_inventory_slots": int(entry.get("extra_inventory_slots", 0)),
					"extra_max_energy": float(entry.get("extra_max_energy", 0.0)),
					"extra_max_hull": float(entry.get("extra_max_hull", 0.0)),
				}
				if int(_equipped[String(slot)]["extra_inventory_slots"]) == 0:
					var loaded := ItemDB.get_item(String(entry.get("id", "")))
					if loaded:
						_equipped[String(slot)]["extra_inventory_slots"] = loaded.extra_inventory_slots
						_equipped[String(slot)]["extra_max_energy"] = loaded.extra_max_energy
						_equipped[String(slot)]["extra_max_hull"] = loaded.extra_max_hull
	_recompute()


func _recompute() -> void:
	if _inventory:
		_inventory.set_bonus_slots(_sum_extra_slots())
	if _battery:
		_battery.set_max_energy(_base_energy + _sum_extra_energy())
	if _hull:
		_hull.set_max_integrity(_base_hull + _sum_extra_hull())
	_refresh_visuals()
	changed.emit()


func _sum_extra_slots() -> int:
	var extra := 0
	for slot in SLOTS:
		extra += int(_entry_value(slot, "extra_inventory_slots", 0))
	return extra


func _sum_extra_energy() -> float:
	var extra := 0.0
	for slot in SLOTS:
		extra += float(_entry_value(slot, "extra_max_energy", 0.0))
	return extra


func _sum_extra_hull() -> float:
	var extra := 0.0
	for slot in SLOTS:
		extra += float(_entry_value(slot, "extra_max_hull", 0.0))
	return extra


func _entry_value(slot: String, key: String, fallback: Variant) -> Variant:
	var entry: Variant = _equipped.get(slot, null)
	if entry is Dictionary and entry.has(key):
		return entry[key]
	var item := get_equipped_item(slot)
	if item == null:
		return fallback
	return item.get(key)


func _refresh_visuals() -> void:
	for slot in SLOTS:
		var node_name := String(SLOT_NODES.get(slot, ""))
		var marker := _points.get_node_or_null(node_name) as Marker3D if _points else null
		var mesh := _visuals.get(slot) as MeshInstance3D
		var item := get_equipped_item(slot)
		if item == null:
			if mesh:
				mesh.queue_free()
				_visuals.erase(slot)
			continue
		if marker == null:
			continue
		if mesh == null:
			mesh = MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.16, 0.1, 0.18)
			mesh.mesh = box
			marker.add_child(mesh)
			_visuals[slot] = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = item.color
		mat.emission_enabled = true
		mat.emission = item.color
		mat.emission_energy_multiplier = 0.35 + 0.9 * get_integrity_ratio(slot)
		mesh.set_surface_override_material(0, mat)
