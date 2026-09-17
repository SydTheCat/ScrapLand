extends Node
class_name Inventory
## SCRAPLAND -- Slot-based inventory. Attach as a child of the Player.
##
## Pure data: it stores slots, stacks items and reports what changed. It draws
## nothing. The inventory UI (a later step) listens to `changed` and redraws.
##
## Recipes and repair costs address items by their string id, so callers can ask
## questions like has_all({"scrap_metal": 10, "copper": 3}) without holding any
## ItemData references.

## Something in the inventory changed. The UI redraws on this.
signal changed
signal item_added(item: ItemData, amount: int)
signal item_removed(item: ItemData, amount: int)
## Fired when part of a pickup would not fit, with the amount left over.
signal overflowed(item: ItemData, amount: int)

## Starting capacity. Backpack upgrades add to this through set_bonus_slots()
## rather than rewriting it, so removing a rack can put the hold back to size.
@export var slot_count: int = 20
## Given on a new game, and again after a load if they are missing, so the
## salvage beam is always there to drag onto the hotbar.
@export var starting_item_ids: PackedStringArray = PackedStringArray(["salvage_beam"])


## Slots are InventorySlot objects (see inventory_slot.gd).
var _slots: Array[InventorySlot] = []
## Extra squares from installed parts. Not saved as the base capacity.
var _bonus_slots: int = 0


func _ready() -> void:
	set_slot_count(slot_count)

	# Shutting down scatters part of the cargo. The battery announces it and we
	# react to it here, so the battery never needs to know an inventory exists.
	var battery := get_parent().get_node_or_null("Battery") as RobotBattery
	if battery:
		battery.resources_lost.connect(remove_fraction)

	# See systems/save_manager.gd for the group contract.
	add_to_group(&"persist")
	_grant_starting_items()


# --- Adding -----------------------------------------------------------------

## Adds up to `amount` of `item`. Returns how many did NOT fit, so a pickup can
## leave the remainder lying in the world.
func add_item(item: ItemData, amount: int) -> int:
	if item == null or amount <= 0:
		return 0

	var remaining := amount

	# Top up part-filled stacks first so the inventory stays tidy.
	for slot in _slots:
		if remaining <= 0:
			break
		if slot.is_empty() or not slot.item.matches(item):
			continue
		var space := slot.space_left()
		if space <= 0:
			continue
		var moved: int = mini(space, remaining)
		slot.amount += moved
		remaining -= moved

	# Then start new stacks in empty slots.
	for slot in _slots:
		if remaining <= 0:
			break
		if not slot.is_empty():
			continue
		var moved: int = mini(item.max_stack, remaining)
		slot.item = item
		slot.amount = moved
		remaining -= moved

	var added := amount - remaining
	if added > 0:
		item_added.emit(item, added)
		changed.emit()
	if remaining > 0:
		overflowed.emit(item, remaining)
	return remaining


# --- Removing ---------------------------------------------------------------

## Removes up to `amount` of the item with this id. Returns how many were
## actually removed.
func remove_item(id: String, amount: int) -> int:
	if amount <= 0:
		return 0

	var remaining := amount
	var removed_item: ItemData = null

	# Drain the smallest stacks first by walking backwards, which keeps one big
	# stack intact rather than leaving several near-empty ones.
	for i in range(_slots.size() - 1, -1, -1):
		if remaining <= 0:
			break
		var slot := _slots[i]
		if slot.is_empty() or slot.item.id != id:
			continue
		removed_item = slot.item
		var taken: int = mini(slot.amount, remaining)
		slot.amount -= taken
		remaining -= taken
		if slot.amount <= 0:
			slot.clear()

	var removed := amount - remaining
	if removed > 0:
		item_removed.emit(removed_item, removed)
		changed.emit()
	return removed


## Spends a whole recipe/repair cost at once, or nothing at all. Returns false
## and changes nothing if the player cannot afford it.
func spend(costs: Dictionary) -> bool:
	if not has_all(costs):
		return false
	for id in costs:
		remove_item(String(id), int(costs[id]))
	return true


# --- Moving between inventories ---------------------------------------------

## Moves one slot's contents into another inventory. Returns how many actually
## moved; anything that does not fit stays exactly where it was.
##
## Slot-specific on purpose. remove_item() drains the smallest stacks first,
## which is right for paying a recipe but wrong for a container screen, where the
## player expects the stack they clicked on to be the one that moves.
func transfer_slot(index: int, destination: Inventory, amount: int = -1) -> int:
	if destination == null or index < 0 or index >= _slots.size():
		return 0

	var slot := _slots[index]
	if slot.is_empty():
		return 0

	var wanted := slot.amount if amount < 0 else mini(amount, slot.amount)
	if wanted <= 0:
		return 0

	var moved_item := slot.item
	var moved := wanted - destination.add_item(moved_item, wanted)
	if moved <= 0:
		return 0

	slot.amount -= moved
	if slot.amount <= 0:
		slot.clear()

	item_removed.emit(moved_item, moved)
	changed.emit()
	return moved


## Empties as much as will fit into `destination`. Returns the total moved, so a
## caller can tell "nothing to move" from "no room at the other end".
func transfer_all(destination: Inventory) -> int:
	var moved := 0
	for i in _slots.size():
		moved += transfer_slot(i, destination)
	return moved


# --- Queries ----------------------------------------------------------------

## Total amount of one item id across every slot.
func count(id: String) -> int:
	var total := 0
	for slot in _slots:
		if not slot.is_empty() and slot.item.id == id:
			total += slot.amount
	return total


## costs is {item_id: amount}, the same shape as a recipe or a repair cost.
func has_all(costs: Dictionary) -> bool:
	for id in costs:
		if count(String(id)) < int(costs[id]):
			return false
	return true


## How many of `costs` are still missing: {item_id: shortfall}. Only includes
## items the player is actually short of.
func get_missing(costs: Dictionary) -> Dictionary:
	var missing := {}
	for id in costs:
		var shortfall := int(costs[id]) - count(String(id))
		if shortfall > 0:
			missing[String(id)] = shortfall
	return missing


## How many more of this item would fit right now, counting part-filled stacks
## and empty slots. Crafting uses this to refuse before spending materials.
func get_space_for(item: ItemData) -> int:
	if item == null:
		return 0
	var space := 0
	for slot in _slots:
		if slot.is_empty():
			space += item.max_stack
		elif slot.item.matches(item):
			space += slot.space_left()
	return space


func can_accept(item: ItemData, amount: int) -> bool:
	return get_space_for(item) >= amount


## Live slot list. The UI reads this; do not resize it from outside.
func get_slots() -> Array[InventorySlot]:
	return _slots


func get_slot_at(index: int) -> InventorySlot:
	if index < 0 or index >= _slots.size():
		return null
	return _slots[index]


## After another system edits a slot in place (a hotbar drop), tell listeners.
func notify_changed() -> void:
	changed.emit()


func get_used_slot_count() -> int:
	var used := 0
	for slot in _slots:
		if not slot.is_empty():
			used += 1
	return used


func is_full() -> bool:
	return get_used_slot_count() >= _slots.size()


# --- Capacity ---------------------------------------------------------------

func get_base_slot_count() -> int:
	return slot_count


func get_bonus_slots() -> int:
	return _bonus_slots


## Backpack upgrades call this. Growing keeps everything; shrinking compactes
## first and only drops empty squares from the end.
func set_bonus_slots(bonus: int) -> void:
	_bonus_slots = maxi(0, bonus)
	_resize_to(slot_count + _bonus_slots)


## Starting capacity. Backpack upgrades should use set_bonus_slots() so this
## number stays the hold's unupgraded size.
func set_slot_count(new_count: int) -> void:
	slot_count = maxi(1, new_count)
	_resize_to(slot_count + _bonus_slots)


func _resize_to(new_count: int) -> void:
	new_count = maxi(1, new_count)
	if _slots.size() > new_count:
		_compact()
	while _slots.size() < new_count:
		_slots.append(InventorySlot.new())
	while _slots.size() > new_count:
		var last: InventorySlot = _slots[_slots.size() - 1]
		if last != null and not last.is_empty():
			break
		_slots.pop_back()
	changed.emit()


## Packed stacks slide to the front so shrinking can drop empty tail squares.
func _compact() -> void:
	var packed: Array[InventorySlot] = []
	var empties: Array[InventorySlot] = []
	for slot in _slots:
		if slot.is_empty():
			empties.append(slot)
		else:
			packed.append(slot)
	_slots.clear()
	_slots.append_array(packed)
	_slots.append_array(empties)


# --- Saving -----------------------------------------------------------------

## Slots are saved in order, as item ids rather than resource references, so a
## save file stays valid when an item's description or colour is edited.
func save_data() -> Dictionary:
	var entries: Array = []
	for slot in _slots:
		if slot.is_empty():
			entries.append(null)
		else:
			entries.append({"id": slot.item.id, "amount": slot.amount})
	return {"slots": entries}


func load_data(data: Dictionary) -> void:
	var entries: Array = data.get("slots", [])
	# Saved slot_count used to be the TOTAL hold size, including racks. Ignore
	# it and size from the base plus whatever upgrades currently add.
	_resize_to(maxi(slot_count + _bonus_slots, entries.size()))
	for slot in _slots:
		slot.clear()
	for i in mini(entries.size(), _slots.size()):
		var entry = entries[i]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var id := String((entry as Dictionary).get("id", ""))
		var item := ItemDB.get_item(id)
		if item == null:
			# The item was renamed or removed from the database. Skip it rather
			# than crash, and say so loudly enough to notice.
			push_warning("inventory: save file mentions unknown item '%s'." % id)
			continue
		_slots[i].item = item
		_slots[i].amount = clampi(int((entry as Dictionary).get("amount", 0)), 0, item.max_stack)
		if _slots[i].amount <= 0:
			_slots[i].clear()
	# Drop empty tail squares from older saves that stored upgraded capacity.
	_resize_to(slot_count + _bonus_slots)

	changed.emit()
	_grant_starting_items()


## Used when the robot shuts down and drops part of its cargo.
func remove_fraction(fraction: float) -> void:
	if fraction <= 0.0:
		return
	for slot in _slots:
		if slot.is_empty():
			continue
		var lost := int(ceil(slot.amount * fraction))
		slot.amount -= lost
		if slot.amount <= 0:
			slot.clear()
	changed.emit()


func _grant_starting_items() -> void:
	# Storage boxes reuse this script. Only the robot starts with a kit.
	if not (get_parent() is Player):
		return
	for id in starting_item_ids:
		var item := ItemDB.get_item(id)
		if item == null or count(id) > 0:
			continue
		add_item(item, 1)
