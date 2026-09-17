extends Resource
class_name ItemData
## SCRAPLAND -- Definition of one kind of item.
##
## This is a Resource, not a node: each item is a small .tres data file in
## resources/items/. Nothing in the game hard-codes item names or stack sizes,
## so adding a new resource means creating a .tres file, not editing scripts.
##
## To make a new item: right-click in resources/items/ -> New Resource ->
## search "ItemData", fill in the fields, save as <id>.tres.

## Used to group items in the inventory UI and to decide what can be equipped.
enum Category {
	RESOURCE,    ## Scrap, copper, energy cells -- raw crafting input.
	TOOL,        ## Equippable: scrap pick, repair tool.
	BUILDABLE,   ## Placeable in build mode.
	CONSUMABLE,  ## Portable battery and similar one-shot items.
	JUNK,        ## Useless human artefacts. Kept purely for the jokes.
}

## Stable lookup key, lower_snake_case. Recipes and repair costs refer to items
## by this string, so never change it once saved.
@export var id: String = ""
@export var display_name: String = "Item"
@export_multiline var description: String = ""
@export var category: Category = Category.RESOURCE

@export_group("Presentation")
## Optional. The inventory falls back to `color` while there are no icons drawn.
@export var icon: Texture2D
## Swatch colour used by the inventory UI and by pickup notifications.
@export var color: Color = Color(0.7, 0.7, 0.7)

@export_group("Stacking")
## How many fit in one inventory slot.
@export var max_stack: int = 50

@export_group("Consumable")
## Energy restored when the item is used. Above zero makes the item usable from
## the inventory (this is what makes the Portable Battery work).
@export var energy_restored: float = 0.0

@export_group("Buildable")
## Scene dropped into the world by build mode. Setting this is the only thing
## that makes an item placeable, so build mode needs no list of its own.
@export var place_scene: PackedScene
## Footprint used for the clearance check while placing, in metres. Make it a
## little larger than the structure's collision box so two of them cannot end up
## touching.
@export var build_size: Vector3 = Vector3(1.0, 1.0, 1.0)

@export_group("Upgrade")
## Empty: not an upgrade. One of back, chassis, head, arm, leg.
@export var upgrade_slot: String = ""
@export var extra_inventory_slots: int = 0
@export var extra_max_energy: float = 0.0
@export var extra_max_hull: float = 0.0
@export var upgrade_max_integrity: float = 40.0


## True if using this item from the inventory does anything.
func is_usable() -> bool:
	return energy_restored > 0.0


## True if this item can be placed in build mode.
func is_placeable() -> bool:
	return place_scene != null


func is_upgrade() -> bool:
	return not upgrade_slot.is_empty()


## "RESOURCE" -> "Resource". Used by the inventory details panel.
func get_category_name() -> String:
	return String(Category.keys()[category]).capitalize()


## True if two references describe the same item. Compared by id rather than by
## object identity so a duplicated resource still stacks correctly.
func matches(other: ItemData) -> bool:
	return other != null and other.id == id
