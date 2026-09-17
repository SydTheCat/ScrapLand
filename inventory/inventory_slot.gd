extends RefCounted
class_name InventorySlot
## SCRAPLAND -- One slot in an Inventory.
##
## A slot is either empty, or holds one ItemData plus how many of it. Kept in its
## own file (rather than as a Dictionary or an inner class) so its fields are
## typed and the inventory UI can read them without guessing key names.

var item: ItemData
var amount: int = 0


func is_empty() -> bool:
	return item == null or amount <= 0


## How many more of the current item would fit here.
func space_left() -> int:
	return 0 if item == null else item.max_stack - amount


func clear() -> void:
	item = null
	amount = 0


## Drops `other` onto this square. Empty destination takes the whole stack;
## matching items combine up to max_stack; different items swap. `other` is the
## source and is left with whatever did not move.
func merge_or_swap(other: InventorySlot) -> void:
	if other == null or other.is_empty() or other == self:
		return
	if is_empty():
		item = other.item
		amount = other.amount
		other.clear()
		return
	if item.matches(other.item):
		var moved: int = mini(space_left(), other.amount)
		amount += moved
		other.amount -= moved
		if other.amount <= 0:
			other.clear()
		return
	var swapped_item := item
	var swapped_amount := amount
	item = other.item
	amount = other.amount
	other.item = swapped_item
	other.amount = swapped_amount
