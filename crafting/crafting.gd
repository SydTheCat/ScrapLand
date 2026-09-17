extends Node
class_name Crafting
## SCRAPLAND -- The robot's fabrication system. Attach as a child of the Player.
##
## Owns the recipe list, which recipes are unlocked, and whether a workbench is
## currently in reach. It performs crafting against the player's Inventory and
## draws nothing -- crafting_ui.gd is the screen.
##
## Recipes are .tres files in crafting/recipes/, listed on this node in the
## Inspector. Simple things can be made by hand anywhere; recipes flagged
## `requires_workbench` need you to be standing at one.

## Unlock state or workbench availability changed, so the menu should redraw.
signal recipes_changed
signal crafted(recipe: CraftingRecipe)
signal craft_failed(recipe: CraftingRecipe, reason: String)

## Typed as Array[Resource] rather than Array[CraftingRecipe] because plain
## Resource is a built-in type and always serialises cleanly into scene files.
## Entries are cast to CraftingRecipe on read.
@export var recipes: Array[Resource] = []

## recipe id -> true. Absent means locked.
var _unlocked: Dictionary = {}
## How many workbench areas the player is standing in. More than one is fine.
var _workbenches_in_range: int = 0

@onready var _inventory: Inventory = get_parent().get_node_or_null("Inventory") as Inventory
@onready var _hotbar: Hotbar = get_parent().get_node_or_null("Hotbar") as Hotbar


func _ready() -> void:
	for recipe in get_recipes():
		if recipe.unlocked_from_start:
			_unlocked[recipe.id] = true

	# Anything can unlock a recipe through the event bus without knowing this
	# node exists -- the charging station does exactly that when repaired.
	GameEvents.recipe_unlock_requested.connect(unlock_recipe)

	# See systems/save_manager.gd for the group contract.
	add_to_group(&"persist")


## The recipe list, cast to the real type.
func get_recipes() -> Array[CraftingRecipe]:
	var typed: Array[CraftingRecipe] = []
	for entry in recipes:
		var recipe := entry as CraftingRecipe
		if recipe:
			typed.append(recipe)
	return typed


# --- Unlocking --------------------------------------------------------------

func is_unlocked(recipe_id: String) -> bool:
	return _unlocked.get(recipe_id, false)


func unlock_recipe(recipe_id: String) -> void:
	if _unlocked.get(recipe_id, false):
		return
	_unlocked[recipe_id] = true
	recipes_changed.emit()

	var recipe := find_recipe(recipe_id)
	if recipe:
		GameEvents.notify("NEW BLUEPRINT: %s" % recipe.get_display_name(), Color(0.6, 0.95, 1.0))


func find_recipe(recipe_id: String) -> CraftingRecipe:
	for recipe in get_recipes():
		if recipe.id == recipe_id:
			return recipe
	return null


# --- Workbench presence -----------------------------------------------------

## Called by workbench.gd as the player walks in and out of range.
func add_workbench() -> void:
	_workbenches_in_range += 1
	recipes_changed.emit()


func remove_workbench() -> void:
	_workbenches_in_range = maxi(_workbenches_in_range - 1, 0)
	recipes_changed.emit()


func has_workbench() -> bool:
	return _workbenches_in_range > 0


# --- Crafting ---------------------------------------------------------------

## Empty string means the recipe can be made right now. Otherwise it is the
## reason why not, ready to show in the UI.
func get_blocker(recipe: CraftingRecipe) -> String:
	if recipe == null or recipe.result_item == null:
		return "Blueprint corrupted."
	if not is_unlocked(recipe.id):
		return "Blueprint not recovered yet."
	if recipe.requires_workbench and not has_workbench():
		return "Requires a workbench."
	if _inventory == null:
		return "No cargo hold."
	if not _inventory.can_accept(recipe.result_item, recipe.result_amount):
		return "No room in the cargo hold."

	var missing := _get_missing(recipe.costs)
	if not missing.is_empty():
		var parts: PackedStringArray = []
		for id in missing:
			parts.append("%d %s" % [int(missing[id]), String(id).capitalize()])
		return "Short of " + ", ".join(parts) + "."
	return ""


func can_craft(recipe: CraftingRecipe) -> bool:
	return get_blocker(recipe).is_empty()


func craft(recipe: CraftingRecipe) -> bool:
	var blocker := get_blocker(recipe)
	if not blocker.is_empty():
		craft_failed.emit(recipe, blocker)
		GameEvents.notify(blocker, Color(1, 0.6, 0.3))
		return false

	# spend() is all-or-nothing, and the room check above already passed, so
	# from here the craft cannot half-succeed.
	_spend_costs(recipe.costs)
	_inventory.add_item(recipe.result_item, recipe.result_amount)

	GameEvents.notify("Fabricated: %s" % recipe.get_display_name(), recipe.result_item.color)
	crafted.emit(recipe)
	return true


func _available(item_id: String) -> int:
	var total := _inventory.count(item_id) if _inventory else 0
	if _hotbar:
		total += _hotbar.count(item_id)
	return total


func _get_missing(costs: Dictionary) -> Dictionary:
	var missing := {}
	for id in costs:
		var shortfall := int(costs[id]) - _available(String(id))
		if shortfall > 0:
			missing[String(id)] = shortfall
	return missing


func _spend_costs(costs: Dictionary) -> void:
	for id in costs:
		var need := int(costs[id])
		if _inventory:
			need -= _inventory.remove_item(String(id), need)
		if need > 0 and _hotbar:
			_hotbar.remove_item(String(id), need)


# --- Saving -----------------------------------------------------------------

## Only the unlock list is saved. Which recipes exist is decided by the resource
## files, so a new blueprint added to the game shows up in old saves too.
func save_data() -> Dictionary:
	return {"unlocked": _unlocked.keys()}


func load_data(data: Dictionary) -> void:
	_unlocked.clear()
	for id in data.get("unlocked", []):
		_unlocked[String(id)] = true
	# Recipes marked unlocked_from_start stay available even in an old save.
	for recipe in get_recipes():
		if recipe.unlocked_from_start:
			_unlocked[recipe.id] = true
	recipes_changed.emit()
