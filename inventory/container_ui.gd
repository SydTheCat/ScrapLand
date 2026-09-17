extends CanvasLayer
class_name ContainerUI
## SCRAPLAND -- The screen shown when you open a storage box.
##
## Two grids: the box on the left, the robot's cargo hold on the right. Clicking a
## stack sends it to the other side, and the two buttons in the middle move
## everything at once.
##
## One instance serves every container in the game. A box asks it to open by
## passing its own inventory to open_container(), having found this through the
## "container_ui" group, so neither side holds a permanent reference to the other
## and neither knows the other's type.
##
## It owns no state: both grids are drawn from Inventory nodes, and every transfer
## goes through Inventory.transfer_slot(), which is what keeps stacking and
## capacity rules in one place.

@export_group("Setup")
## The square drawn for each slot. Defaults to inventory_slot_ui.tscn.
@export var slot_scene: PackedScene
@export var box_columns: int = 4
@export var player_columns: int = 5

@export_group("Behaviour")
## Freeze the robot while the panel is open.
@export var pause_player: bool = true

@onready var root: Control = $Root
@onready var title_label: Label = $Root/Frame/Margin/VBox/Header/Title
@onready var box_caption: Label = $Root/Frame/Margin/VBox/Body/BoxSide/BoxCaption
@onready var box_grid: GridContainer = $Root/Frame/Margin/VBox/Body/BoxSide/BoxGrid
@onready var player_caption: Label = $Root/Frame/Margin/VBox/Body/PlayerSide/PlayerCaption
@onready var player_grid: GridContainer = $Root/Frame/Margin/VBox/Body/PlayerSide/PlayerGrid
@onready var store_all_button: Button = $Root/Frame/Margin/VBox/Body/Middle/StoreAll
@onready var take_all_button: Button = $Root/Frame/Margin/VBox/Body/Middle/TakeAll

var _player: Player
var _player_inventory: Inventory
## The inventory currently on show on the left. Null while closed.
var _box_inventory: Inventory
var _box_widgets: Array[InventorySlotUI] = []
var _player_widgets: Array[InventorySlotUI] = []


func _ready() -> void:
	root.visible = false
	box_grid.columns = box_columns
	player_grid.columns = player_columns
	store_all_button.pressed.connect(_on_store_all)
	take_all_button.pressed.connect(_on_take_all)

	# Only one full-screen menu at a time.
	GameEvents.menu_opened.connect(_on_menu_opened)
	# A load can retire the very box being looked at, so the panel gets out of the
	# way rather than showing a crate that no longer exists.
	SaveManager.loaded.connect(close)

	_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		push_warning("container_ui.gd: no node in the 'player' group.")
		return

	_player_inventory = _player.get_node_or_null("Inventory") as Inventory
	if _player_inventory == null:
		push_warning("container_ui.gd: the player has no Inventory child.")
		return

	_player_inventory.changed.connect(_refresh)
	_player_widgets = _build_widgets(player_grid, _player_inventory, _on_player_slot_clicked)


## Handled in _input rather than _unhandled_input so a focused Button cannot
## swallow Tab for its own focus navigation.
func _input(event: InputEvent) -> void:
	if not root.visible:
		return
	if (
			event.is_action_pressed(&"ui_cancel")
			or event.is_action_pressed(&"inventory")
			or event.is_action_pressed(&"interact")
	):
		close()
		get_viewport().set_input_as_handled()


# --- Open / close -----------------------------------------------------------

## Called by a storage box when the player interacts with it.
##
## Takes the inventory and a title rather than the box itself, so this screen
## works for any future machine that holds items -- a furnace, a refinery -- and
## does not depend on the StorageBox type.
func open_container(inventory: Inventory, title: String = "Container") -> void:
	if inventory == null or _player_inventory == null:
		return
	if is_showing(inventory):
		close()
		return

	var previous := _box_inventory
	_unbind_box()
	if previous and previous != inventory:
		GameEvents.announce_container_closed(previous)

	_box_inventory = inventory
	_box_inventory.changed.connect(_refresh)

	# Announce first so any other open menu closes before we take the mouse.
	GameEvents.announce_menu_opened(self)
	title_label.text = title.to_upper()
	# Rebuilt per box, because a bigger crate later will have more slots.
	_box_widgets = _rebuild_box_widgets()
	# A backpack upgrade can add cargo slots after this panel was first built.
	_top_up_widgets(player_grid, _player_inventory, _player_widgets, _on_player_slot_clicked)
	_refresh()

	root.visible = true
	_set_gameplay_input_enabled(false)
	GameEvents.announce_container_opened(inventory)


func close() -> void:
	if not root.visible:
		return
	root.visible = false
	var inv := _box_inventory
	_unbind_box()
	_set_gameplay_input_enabled(true)
	if inv:
		GameEvents.announce_container_closed(inv)
	GameEvents.announce_menu_closed(self)
	var hotbar := _player.get_node_or_null("Hotbar") as Hotbar if _player else null
	if hotbar:
		hotbar.apply_selected()


func is_open() -> bool:
	return root != null and root.visible


func is_showing(inventory: Inventory) -> bool:
	return is_open() and _box_inventory == inventory


## Another menu took over. Hide without handing the mouse back, because the menu
## that is opening owns it from here.
func _on_menu_opened(menu: Node) -> void:
	if menu != self and is_open():
		var inv := _box_inventory
		root.visible = false
		_unbind_box()
		if inv:
			GameEvents.announce_container_closed(inv)
		GameEvents.announce_menu_closed(self)


func _unbind_box() -> void:
	if is_instance_valid(_box_inventory) and _box_inventory.changed.is_connected(_refresh):
		_box_inventory.changed.disconnect(_refresh)
	_box_inventory = null


func _set_gameplay_input_enabled(enabled: bool) -> void:
	if _player == null:
		return
	if pause_player:
		_player.can_move = enabled
	_player.camera_rig.set_look_enabled(enabled)


# --- Transfers --------------------------------------------------------------

func _on_box_slot_clicked(slot: InventorySlot) -> void:
	_transfer(_box_inventory, _player_inventory, slot, "Your cargo hold is full.")


func _on_player_slot_clicked(slot: InventorySlot) -> void:
	_transfer(_player_inventory, _box_inventory, slot, "The box is full.")


## Moves one clicked stack across. The slot object itself is looked up rather than
## trusting an index, because the widget holds a live reference to it.
func _transfer(from: Inventory, to: Inventory, slot: InventorySlot, full_message: String) -> void:
	if not _both_valid() or slot == null or slot.is_empty():
		return
	var index := from.get_slots().find(slot)
	if index < 0:
		return
	if from.transfer_slot(index, to) <= 0:
		GameEvents.notify(full_message, Color(1, 0.7, 0.35))


func _on_store_all() -> void:
	if not _both_valid():
		return
	if _player_inventory.get_used_slot_count() <= 0:
		GameEvents.notify("Nothing to store.", Color(1, 0.7, 0.35))
		return
	if _player_inventory.transfer_all(_box_inventory) <= 0:
		GameEvents.notify("The box is full.", Color(1, 0.7, 0.35))


func _on_take_all() -> void:
	if not _both_valid():
		return
	if _box_inventory.get_used_slot_count() <= 0:
		GameEvents.notify("The box is empty.", Color(1, 0.7, 0.35))
		return
	if _box_inventory.transfer_all(_player_inventory) <= 0:
		GameEvents.notify("Your cargo hold is full.", Color(1, 0.7, 0.35))


func _both_valid() -> bool:
	return is_instance_valid(_box_inventory) and is_instance_valid(_player_inventory)


# --- Building and refreshing ------------------------------------------------

func _refresh() -> void:
	if not _both_valid():
		return
	_top_up_widgets(player_grid, _player_inventory, _player_widgets, _on_player_slot_clicked)
	_display(_box_widgets, _box_inventory)
	_display(_player_widgets, _player_inventory)
	box_caption.text = _capacity_text(_box_inventory)
	player_caption.text = _capacity_text(_player_inventory)


func _capacity_text(inventory: Inventory) -> String:
	return "%d / %d slots used" % [inventory.get_used_slot_count(), inventory.get_slots().size()]


func _display(widgets: Array[InventorySlotUI], inventory: Inventory) -> void:
	var slots := inventory.get_slots()
	for i in widgets.size():
		widgets[i].display(slots[i] if i < slots.size() else null)


func _rebuild_box_widgets() -> Array[InventorySlotUI]:
	# Detached before freeing so the grid never lays out both the old and the new
	# squares for a frame.
	for child in box_grid.get_children():
		box_grid.remove_child(child)
		child.queue_free()
	_box_widgets.clear()
	return _build_widgets(box_grid, _box_inventory, _on_box_slot_clicked)


func _build_widgets(grid: GridContainer, inventory: Inventory, on_click: Callable) -> Array[InventorySlotUI]:
	var widgets: Array[InventorySlotUI] = []
	_top_up_widgets(grid, inventory, widgets, on_click)
	return widgets


## Adds or removes squares so the grid matches the inventory's current size.
func _top_up_widgets(
		grid: GridContainer,
		inventory: Inventory,
		widgets: Array[InventorySlotUI],
		on_click: Callable) -> void:
	var scene := slot_scene
	if scene == null:
		scene = load("res://inventory/inventory_slot_ui.tscn") as PackedScene

	while widgets.size() < inventory.get_slots().size():
		var widget := scene.instantiate() as InventorySlotUI
		widget.slot_clicked.connect(on_click)
		grid.add_child(widget)
		widgets.append(widget)
	while widgets.size() > inventory.get_slots().size():
		var extra := widgets.pop_back() as InventorySlotUI
		if extra:
			grid.remove_child(extra)
			extra.queue_free()
