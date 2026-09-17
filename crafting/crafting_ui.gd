extends CanvasLayer
class_name CraftingUI
## SCRAPLAND -- The fabrication screen, toggled with C.
##
## Lists every recipe the Crafting node knows about, colour-coded by whether it
## can be made right now, and shows the selected recipe's cost breakdown with
## have/need counts. Owns no game state: Crafting decides what is possible and
## this only draws the answer.
##
## Workbenches call open() on this directly when you press E on them.

@export_group("Colours")
@export var color_ready: Color = Color(0.6, 1.0, 0.65)
@export var color_short: Color = Color(1.0, 0.72, 0.35)
@export var color_locked: Color = Color(0.5, 0.53, 0.58)
@export var color_have: Color = Color(0.65, 0.95, 0.7)
@export var color_need: Color = Color(1.0, 0.5, 0.4)

@export_group("Behaviour")
@export var pause_player: bool = true

@onready var root: Control = $Root
@onready var recipe_list: VBoxContainer = $Root/Frame/Margin/VBox/Body/Recipes/Scroll/List
@onready var bench_status: Label = $Root/Frame/Margin/VBox/Header/BenchStatus
@onready var detail_name: Label = $Root/Frame/Margin/VBox/Body/Details/DetailName
@onready var detail_description: Label = $Root/Frame/Margin/VBox/Body/Details/DetailDescription
@onready var cost_list: VBoxContainer = $Root/Frame/Margin/VBox/Body/Details/CostList
@onready var craft_button: Button = $Root/Frame/Margin/VBox/Body/Details/CraftButton
@onready var status_label: Label = $Root/Frame/Margin/VBox/Body/Details/StatusLabel

var _player: Player
var _crafting: Crafting
var _inventory: Inventory
var _selected: CraftingRecipe
## recipe id -> its row button, so refreshing does not rebuild the list.
var _rows: Dictionary = {}


func _ready() -> void:
	root.visible = false
	craft_button.pressed.connect(_on_craft_pressed)
	GameEvents.menu_opened.connect(_on_menu_opened)

	_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		push_warning("crafting_ui.gd: no node in the 'player' group.")
		return

	_crafting = _player.get_node_or_null("Crafting") as Crafting
	_inventory = _player.get_node_or_null("Inventory") as Inventory
	if _crafting == null or _inventory == null:
		push_warning("crafting_ui.gd: the player needs both Crafting and Inventory children.")
		return

	# Redraw when materials change, when a blueprint unlocks, or when the player
	# walks into a workbench.
	_inventory.changed.connect(_refresh)
	_crafting.recipes_changed.connect(_rebuild_rows)
	_crafting.crafted.connect(func(_recipe): _refresh())

	_rebuild_rows()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"crafting"):
		toggle()
		get_viewport().set_input_as_handled()
	elif root.visible and (
			event.is_action_pressed(&"ui_cancel")
			or event.is_action_pressed(&"interact")
	):
		close()
		get_viewport().set_input_as_handled()


# --- Open / close -----------------------------------------------------------

func toggle() -> void:
	if root.visible:
		close()
	else:
		open()


func open() -> void:
	if _crafting == null:
		return
	# Announce first: any other open menu closes before we take the mouse.
	GameEvents.announce_menu_opened(self)
	_rebuild_rows()
	root.visible = true
	_set_gameplay_input_enabled(false)


func close() -> void:
	if not root.visible:
		return
	root.visible = false
	_set_gameplay_input_enabled(true)
	GameEvents.announce_menu_closed(self)
	var hotbar := _player.get_node_or_null("Hotbar") as Hotbar if _player else null
	if hotbar:
		hotbar.apply_selected()


func is_open() -> bool:
	return root != null and root.visible


func _on_menu_opened(menu: Node) -> void:
	if menu != self and is_open():
		root.visible = false
		GameEvents.announce_menu_closed(self)


func _set_gameplay_input_enabled(enabled: bool) -> void:
	if _player == null:
		return
	if pause_player:
		_player.can_move = enabled
	_player.camera_rig.set_look_enabled(enabled)


# --- Recipe list ------------------------------------------------------------

## Rebuilt only when the set of recipes changes. Cheaper refreshes just recolour.
func _rebuild_rows() -> void:
	# remove_child before queue_free, otherwise the doomed rows linger for a
	# frame and the container shows the list twice.
	for child in recipe_list.get_children():
		recipe_list.remove_child(child)
		child.queue_free()
	_rows.clear()

	for recipe in _crafting.get_recipes():
		var row := Button.new()
		row.text = recipe.get_display_name()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.custom_minimum_size = Vector2(0, 38)
		row.focus_mode = Control.FOCUS_NONE
		row.pressed.connect(_select_recipe.bind(recipe))
		recipe_list.add_child(row)
		_rows[recipe.id] = row

	# Keep the previous selection if it still exists, otherwise take the first.
	var recipes := _crafting.get_recipes()
	if _selected == null or not _rows.has(_selected.id):
		_selected = recipes[0] if not recipes.is_empty() else null
	_refresh()


## Recolours rows and redraws the details panel against current materials.
func _refresh() -> void:
	if _crafting == null:
		return

	bench_status.text = "WORKBENCH CONNECTED" if _crafting.has_workbench() else "HANDCRAFTING ONLY"
	bench_status.add_theme_color_override(
		&"font_color", color_ready if _crafting.has_workbench() else color_locked)

	for recipe in _crafting.get_recipes():
		var row := _rows.get(recipe.id) as Button
		if row == null:
			continue
		if not _crafting.is_unlocked(recipe.id):
			row.text = "???"
			row.add_theme_color_override(&"font_color", color_locked)
		else:
			row.text = recipe.get_display_name()
			row.add_theme_color_override(
				&"font_color", color_ready if _crafting.can_craft(recipe) else color_short)

	_refresh_details()


func _select_recipe(recipe: CraftingRecipe) -> void:
	_selected = recipe
	_refresh_details()


# --- Details panel ----------------------------------------------------------

func _refresh_details() -> void:
	for child in cost_list.get_children():
		cost_list.remove_child(child)
		child.queue_free()

	if _selected == null:
		detail_name.text = "No blueprints"
		detail_description.text = ""
		status_label.text = ""
		craft_button.disabled = true
		return

	var locked := not _crafting.is_unlocked(_selected.id)
	var item := _selected.result_item

	detail_name.text = "???" if locked else _selected.get_display_name()
	detail_name.add_theme_color_override(&"font_color", color_locked if locked else item.color)

	if locked:
		detail_description.text = "This blueprint has not been recovered yet."
	else:
		detail_description.text = item.description
		if not _selected.note.is_empty():
			detail_description.text += "\n\n" + _selected.note
		_build_cost_lines()

	var blocker := _crafting.get_blocker(_selected)
	craft_button.disabled = not blocker.is_empty()
	status_label.text = blocker
	status_label.add_theme_color_override(&"font_color", color_need)


## One line per ingredient: "5 Scrap Metal      have 12", green when satisfied.
func _build_cost_lines() -> void:
	for id in _selected.costs:
		var needed := int(_selected.costs[id])
		var held := _inventory.count(String(id))
		var line := Label.new()
		line.text = "%d %s      have %d" % [needed, String(id).capitalize(), held]
		line.add_theme_font_size_override(&"font_size", 15)
		line.add_theme_color_override(&"font_color", color_have if held >= needed else color_need)
		cost_list.add_child(line)


func _on_craft_pressed() -> void:
	if _selected and _crafting.craft(_selected):
		_refresh()
