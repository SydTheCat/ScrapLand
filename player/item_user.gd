extends Node
class_name ItemUser
## SCRAPLAND -- Handles "use this item" requests. Attach as a child of the Player.
##
## Right now the only usable items are ones with `energy_restored` above zero,
## which covers the Portable Battery. Equipping tools, installing upgrades and
## placing buildables will each add a branch here rather than scattering item
## behaviour across the UI.

signal item_used(item: ItemData)

@onready var _inventory: Inventory = get_parent().get_node_or_null("Inventory") as Inventory
@onready var _battery: RobotBattery = get_parent().get_node_or_null("Battery") as RobotBattery


## Consumes one of `item` and applies its effect. Returns false (and consumes
## nothing) if the item is not usable or the player does not have one.
func use(item: ItemData) -> bool:
	if item == null or _inventory == null:
		return false
	if not item.is_usable():
		GameEvents.notify("%s cannot be used directly." % item.display_name, Color(0.8, 0.8, 0.85))
		return false
	var hotbar := get_parent().get_node_or_null("Hotbar") as Hotbar
	var on_bar := _is_selected_on_hotbar(hotbar, item)
	if not on_bar and _inventory.count(item.id) <= 0:
		return false

	if item.energy_restored > 0.0:
		if _battery == null:
			return false
		# Refuse when it would be wasted, so a full robot cannot burn a battery.
		if _battery.get_energy() >= _battery.max_energy:
			GameEvents.notify("Already at full charge.", Color(0.6, 0.9, 1.0))
			return false
		_battery.add_energy(item.energy_restored)

	if on_bar:
		hotbar.consume_selected(1)
	else:
		_inventory.remove_item(item.id, 1)
	GameEvents.notify("Used: %s" % item.display_name, item.color)
	item_used.emit(item)
	return true


func _is_selected_on_hotbar(hotbar: Hotbar, item: ItemData) -> bool:
	if hotbar == null or item == null:
		return false
	var selected := hotbar.get_selected_item()
	return selected != null and selected.id == item.id and hotbar.get_count(hotbar.get_selected_index()) > 0
