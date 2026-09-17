extends Node
class_name Hotbar
## SCRAPLAND -- Ten extra inventory slots on the HUD.
##
## Unlike a shortcut bar, these hold the actual stacks. Dragging from the cargo
## hold moves the item out of the backpack; dragging back puts it in again.
## Keys 1-9 and 0 select a slot. The highlighted slot is what the robot uses.

signal changed
signal selected_changed(index: int)

const SLOT_COUNT: int = 10

var _slots: Array[InventorySlot] = []
var _selected: int = -1

@onready var _robot: Player = get_parent() as Player
@onready var _inventory: Inventory = _robot.get_node_or_null("Inventory") as Inventory
@onready var _equipment: Equipment = _robot.get_node_or_null("Tools") as Equipment
@onready var _builder: Builder = _robot.get_node_or_null("Builder") as Builder
@onready var _item_user: ItemUser = _robot.get_node_or_null("ItemUser") as ItemUser


func _ready() -> void:
	for _i in SLOT_COUNT:
		_slots.append(InventorySlot.new())
	add_to_group(&"persist")
	changed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if _robot == null or not _robot.can_move:
		return
	for n in SLOT_COUNT:
		if event.is_action_pressed("tool_slot_%d" % n):
			select(_index_for_key(n))
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed(&"tool_primary") and _robot.actions_enabled:
		_try_use_consumable()


# --- Slots ------------------------------------------------------------------

func get_slot(index: int) -> InventorySlot:
	if index < 0 or index >= SLOT_COUNT:
		return null
	return _slots[index]


func get_slot_id(index: int) -> String:
	var slot := get_slot(index)
	if slot == null or slot.is_empty():
		return ""
	return slot.item.id


func get_count(index: int) -> int:
	var slot := get_slot(index)
	if slot == null or slot.is_empty():
		return 0
	return slot.amount


func count(item_id: String) -> int:
	var total := 0
	for slot in _slots:
		if not slot.is_empty() and slot.item.id == item_id:
			total += slot.amount
	return total


func get_selected_index() -> int:
	return _selected


func get_selected_item() -> ItemData:
	var slot := get_slot(_selected)
	if slot == null or slot.is_empty():
		return null
	return slot.item


func select(index: int) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return
	_selected = index
	selected_changed.emit(_selected)
	changed.emit()
	apply_selected()


## Moves a cargo-hold stack onto this bar. Matching items combine; different
## items swap, so the backpack receives whatever was in the square.
func take_from_inventory(inventory_index: int, dest_index: int) -> void:
	if _inventory == null:
		return
	var source := _inventory.get_slot_at(inventory_index)
	var dest := get_slot(dest_index)
	if source == null or dest == null:
		return
	dest.merge_or_swap(source)
	_inventory.notify_changed()
	changed.emit()
	if dest_index == _selected:
		apply_selected()


## Puts a hotbar stack back into a cargo-hold square.
func return_to_inventory(hotbar_index: int, inventory_index: int) -> void:
	if _inventory == null:
		return
	var source := get_slot(hotbar_index)
	var dest := _inventory.get_slot_at(inventory_index)
	if source == null or dest == null:
		return
	dest.merge_or_swap(source)
	_inventory.notify_changed()
	changed.emit()
	if hotbar_index == _selected:
		apply_selected()


## Right-click: dump the square back into any free cargo space.
func return_anywhere(hotbar_index: int) -> void:
	if _inventory == null:
		return
	var source := get_slot(hotbar_index)
	if source == null or source.is_empty():
		return
	var leftover := _inventory.add_item(source.item, source.amount)
	source.amount = leftover
	if source.amount <= 0:
		source.clear()
	elif leftover > 0:
		GameEvents.notify("No room in the cargo hold.", Color(1, 0.7, 0.35))
	changed.emit()
	if hotbar_index == _selected:
		apply_selected()


func swap_slots(a: int, b: int) -> void:
	if a < 0 or b < 0 or a >= SLOT_COUNT or b >= SLOT_COUNT or a == b:
		return
	_slots[b].merge_or_swap(_slots[a])
	changed.emit()
	if _selected == a or _selected == b:
		apply_selected()


func consume_selected(amount: int = 1) -> bool:
	var slot := get_slot(_selected)
	if slot == null or slot.is_empty() or slot.amount < amount:
		return false
	slot.amount -= amount
	if slot.amount <= 0:
		slot.clear()
	changed.emit()
	apply_selected()
	return true


## Used by crafting so materials sitting on the bar still count.
func remove_item(item_id: String, amount: int) -> int:
	if amount <= 0:
		return 0
	var remaining := amount
	for i in range(SLOT_COUNT - 1, -1, -1):
		if remaining <= 0:
			break
		var slot := _slots[i]
		if slot.is_empty() or slot.item.id != item_id:
			continue
		var taken: int = mini(slot.amount, remaining)
		slot.amount -= taken
		remaining -= taken
		if slot.amount <= 0:
			slot.clear()
	var removed := amount - remaining
	if removed > 0:
		changed.emit()
		if _selected >= 0:
			apply_selected()
	return removed


func apply_selected() -> void:
	var item := get_selected_item()
	var available := item != null and get_count(_selected) > 0

	if _equipment:
		_equipment.unequip()

	if not available:
		if _builder:
			_builder.close()
		return

	var tool_node := _equipment.find_for_item(item.id) if _equipment else null
	if tool_node:
		_equipment.equip_tool(tool_node)
		if _builder:
			_builder.close()
		return

	if item.is_placeable() and _builder:
		_builder.open_item(item)
		return

	if _builder:
		_builder.close()


func _try_use_consumable() -> void:
	var item := get_selected_item()
	if item == null or not item.is_usable() or _item_user == null:
		return
	if _equipment and _equipment.get_equipped():
		return
	_item_user.use(item)


func _index_for_key(key_number: int) -> int:
	return 9 if key_number == 0 else key_number - 1


# --- Save / load ------------------------------------------------------------

func save_data() -> Dictionary:
	var entries: Array = []
	for slot in _slots:
		if slot.is_empty():
			entries.append(null)
		else:
			entries.append({"id": slot.item.id, "amount": slot.amount})
	return {"slots": entries, "selected": _selected}


func load_data(data: Dictionary) -> void:
	var entries: Array = data.get("slots", [])
	for i in SLOT_COUNT:
		if i < _slots.size():
			_slots[i].clear()
		if i >= entries.size() or typeof(entries[i]) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = entries[i]
		var item := ItemDB.get_item(String(entry.get("id", "")))
		if item == null:
			continue
		_slots[i].item = item
		_slots[i].amount = clampi(int(entry.get("amount", 0)), 0, item.max_stack)
		if _slots[i].amount <= 0:
			_slots[i].clear()
	_selected = int(data.get("selected", -1))
	changed.emit()
	apply_selected.call_deferred()
