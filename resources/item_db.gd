extends RefCounted
class_name ItemDB
## SCRAPLAND -- Turns a saved item id back into an ItemData.
##
## Save files store items as ids ("scrap_metal"), never as resource references.
## That keeps saves readable and stops them breaking when an item's description
## or colour is edited. Something has to know the full list to reverse it, and
## this is it.
##
## Used statically, so there is nothing to place and nothing to autoload:
##
##     var item := ItemDB.get_item("scrap_metal")
##
## preload() rather than load() is deliberate. These are resolved when the script
## is compiled, so looking an item up during a load never touches the disk and
## never enters the resource loader. Add a new item to resources/items/ and it
## needs one line here, or it will vanish from save files.

const ITEMS := {
	"scrap_metal": preload("res://resources/items/scrap_metal.tres"),
	"copper": preload("res://resources/items/copper.tres"),
	"energy_cell": preload("res://resources/items/energy_cell.tres"),
	"salvage_beam": preload("res://resources/items/salvage_beam.tres"),
	"scrap_pick": preload("res://resources/items/scrap_pick.tres"),
	"repair_tool": preload("res://resources/items/repair_tool.tres"),
	"portable_battery": preload("res://resources/items/portable_battery.tres"),
	"storage_box": preload("res://resources/items/storage_box.tres"),
	"basic_workbench": preload("res://resources/items/basic_workbench.tres"),
	"metal_plate": preload("res://resources/items/metal_plate.tres"),
	"furnace": preload("res://resources/items/furnace.tres"),
	"cargo_rack": preload("res://resources/items/cargo_rack.tres"),
	"hull_plating": preload("res://resources/items/hull_plating.tres"),
}


## Returns the item with this id, or null if it is not listed above.
static func get_item(id: String) -> ItemData:
	return ITEMS.get(id, null) as ItemData


static func has_item(id: String) -> bool:
	return ITEMS.has(id)


## The placeable item whose scene is this file, or null. Used when packing a
## structure back up, so the beam does not need its own list of buildings.
static func get_item_for_scene(scene_path: String) -> ItemData:
	if scene_path.is_empty():
		return null
	for id in ITEMS:
		var item := get_item(id)
		if item and item.place_scene and item.place_scene.resource_path == scene_path:
			return item
	return null
