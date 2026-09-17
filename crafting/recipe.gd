extends Resource
class_name CraftingRecipe
## SCRAPLAND -- One crafting recipe, stored as a .tres file in crafting/recipes/.
##
## Like ItemData, recipes are data rather than code: adding one means creating a
## resource file and dropping it into the Crafting node's list, not editing any
## script.

## Stable lookup key. Used when something unlocks a recipe by name.
@export var id: String = ""

@export_group("Result")
@export var result_item: ItemData
@export var result_amount: int = 1

@export_group("Cost")
## {item_id: amount}, the same shape the inventory's spend() and has_all() take.
@export var costs: Dictionary = {}

@export_group("Availability")
## Recipes that need a workbench cannot be made by hand in the field.
@export var requires_workbench: bool = false
## Untick for recipes that have to be discovered or unlocked by progress.
@export var unlocked_from_start: bool = true

@export_group("Presentation")
## Optional extra line shown under the item description in the crafting menu.
@export_multiline var note: String = ""


func get_display_name() -> String:
	return result_item.display_name if result_item else id


## "5 Scrap Metal, 2 Copper"
func format_costs() -> String:
	var parts: PackedStringArray = []
	for id_key in costs:
		parts.append("%d %s" % [int(costs[id_key]), String(id_key).capitalize()])
	return ", ".join(parts)
