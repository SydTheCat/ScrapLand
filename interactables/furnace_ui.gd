extends CanvasLayer
class_name FurnaceUI
## SCRAPLAND -- The screen shown when you open a furnace.
##
## Input on the left, output in the middle, cargo hold on the right. Click a
## stack to move it. The furnace itself does the smelting; this panel only
## shows progress and moves items.

@export var slot_scene: PackedScene
@export var pause_player: bool = true

@onready var root: Control = $Root
@onready var title_label: Label = $Root/Frame/Margin/VBox/Header/Title
@onready var input_grid: GridContainer = $Root/Frame/Margin/VBox/Body/InputSide/InputGrid
@onready var output_grid: GridContainer = $Root/Frame/Margin/VBox/Body/OutputSide/OutputGrid
@onready var player_grid: GridContainer = $Root/Frame/Margin/VBox/Body/PlayerSide/PlayerGrid
@onready var status_label: Label = $Root/Frame/Margin/VBox/Body/Middle/Status
@onready var fill: ColorRect = $Root/Frame/Margin/VBox/Body/Middle/Track/Fill
@onready var feed_button: Button = $Root/Frame/Margin/VBox/Body/Middle/FeedAll
@onready var take_button: Button = $Root/Frame/Margin/VBox/Body/Middle/TakeAll

var _player: Player
var _player_inventory: Inventory
var _machine: Node
var _hopper: Inventory
var _output: Inventory
var _input_widgets: Array[InventorySlotUI] = []
var _output_widgets: Array[InventorySlotUI] = []
var _player_widgets: Array[InventorySlotUI] = []
var _fill_width: float = 0.0


func _ready() -> void:
	root.visible = false
	_fill_width = fill.size.x
	if _fill_width <= 1.0:
		_fill_width = 176.0
	feed_button.pressed.connect(_on_feed_all)
	take_button.pressed.connect(_on_take_all)
	GameEvents.menu_opened.connect(_on_menu_opened)
	SaveManager.loaded.connect(close)

	_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		return
	_player_inventory = _player.get_node_or_null("Inventory") as Inventory
	if _player_inventory:
		_player_inventory.changed.connect(_refresh)
		_player_widgets = _build_widgets(player_grid, _player_inventory, _on_player_clicked)


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


func _process(_delta: float) -> void:
	if root.visible:
		_refresh_progress()


func open_furnace(machine: Node) -> void:
	if machine == null or _player_inventory == null:
		return
	if is_showing(machine):
		close()
		return
	_unbind()
	_machine = machine
	_hopper = machine.get("input") as Inventory
	_output = machine.get("output") as Inventory
	if _hopper == null or _output == null:
		return
	_hopper.changed.connect(_refresh)
	_output.changed.connect(_refresh)
	if _machine.has_signal("progress_changed"):
		_machine.connect("progress_changed", _refresh_progress)

	GameEvents.announce_menu_opened(self)
	var heading := "FURNACE"
	if machine.has_method("get_display_name"):
		heading = String(machine.call("get_display_name"))
	title_label.text = heading.to_upper()
	_input_widgets = _rebuild(input_grid, _hopper, _on_input_clicked, _input_widgets)
	_output_widgets = _rebuild(output_grid, _output, _on_output_clicked, _output_widgets)
	_top_up(player_grid, _player_inventory, _player_widgets, _on_player_clicked)
	_refresh()
	root.visible = true
	_set_gameplay_input_enabled(false)


func close() -> void:
	if not root.visible:
		return
	root.visible = false
	_unbind()
	_set_gameplay_input_enabled(true)
	GameEvents.announce_menu_closed(self)
	var hotbar := _player.get_node_or_null("Hotbar") as Hotbar if _player else null
	if hotbar:
		hotbar.apply_selected()


func is_open() -> bool:
	return root != null and root.visible


func is_showing(machine: Node) -> bool:
	return is_open() and _machine == machine


func _on_menu_opened(menu: Node) -> void:
	if menu != self and is_open():
		root.visible = false
		_unbind()
		GameEvents.announce_menu_closed(self)


func _unbind() -> void:
	if is_instance_valid(_hopper) and _hopper.changed.is_connected(_refresh):
		_hopper.changed.disconnect(_refresh)
	if is_instance_valid(_output) and _output.changed.is_connected(_refresh):
		_output.changed.disconnect(_refresh)
	if is_instance_valid(_machine) and _machine.has_signal("progress_changed"):
		if _machine.is_connected("progress_changed", _refresh_progress):
			_machine.disconnect("progress_changed", _refresh_progress)
	_machine = null
	_hopper = null
	_output = null


func _set_gameplay_input_enabled(enabled: bool) -> void:
	if _player == null:
		return
	if pause_player:
		_player.can_move = enabled
	_player.camera_rig.set_look_enabled(enabled)


func _on_player_clicked(slot: InventorySlot) -> void:
	if not _both_valid() or slot == null or slot.is_empty():
		return
	if _machine and _machine.has_method("accepts_item") and not _machine.call("accepts_item", slot.item.id):
		GameEvents.notify("The furnace does not eat that.", Color(1, 0.7, 0.35))
		return
	var index := _player_inventory.get_slots().find(slot)
	if index >= 0:
		_player_inventory.transfer_slot(index, _hopper)


func _on_input_clicked(slot: InventorySlot) -> void:
	if not _both_valid() or slot == null or slot.is_empty():
		return
	var index := _hopper.get_slots().find(slot)
	if index >= 0:
		_hopper.transfer_slot(index, _player_inventory)


func _on_output_clicked(slot: InventorySlot) -> void:
	if not _both_valid() or slot == null or slot.is_empty():
		return
	var index := _output.get_slots().find(slot)
	if index >= 0:
		_output.transfer_slot(index, _player_inventory)


func _on_feed_all() -> void:
	if not _both_valid():
		return
	var moved := 0
	var slots := _player_inventory.get_slots()
	for i in slots.size():
		if slots[i].is_empty():
			continue
		if _machine and _machine.has_method("accepts_item") and not _machine.call("accepts_item", slots[i].item.id):
			continue
		moved += _player_inventory.transfer_slot(i, _hopper)
	if moved <= 0:
		GameEvents.notify("Nothing the furnace will eat.", Color(1, 0.7, 0.35))


func _on_take_all() -> void:
	if not _both_valid():
		return
	if _output.transfer_all(_player_inventory) <= 0:
		GameEvents.notify("Nothing to take.", Color(1, 0.7, 0.35))


func _both_valid() -> bool:
	return is_instance_valid(_hopper) and is_instance_valid(_output) and is_instance_valid(_player_inventory)


func _refresh() -> void:
	if not _both_valid():
		return
	_top_up(player_grid, _player_inventory, _player_widgets, _on_player_clicked)
	_display(_input_widgets, _hopper)
	_display(_output_widgets, _output)
	_display(_player_widgets, _player_inventory)
	_refresh_progress()


func _refresh_progress() -> void:
	if _machine == null or not is_instance_valid(_machine):
		return
	var ratio := 0.0
	if _machine.has_method("get_progress"):
		ratio = float(_machine.call("get_progress"))
	fill.size.x = _fill_width * clampf(ratio, 0.0, 1.0)
	if _machine.has_method("get_status_text"):
		status_label.text = String(_machine.call("get_status_text"))


func _display(widgets: Array[InventorySlotUI], inventory: Inventory) -> void:
	var slots := inventory.get_slots()
	for i in widgets.size():
		widgets[i].display(slots[i] if i < slots.size() else null)


func _rebuild(
		grid: GridContainer,
		inventory: Inventory,
		on_click: Callable,
		_old: Array[InventorySlotUI]) -> Array[InventorySlotUI]:
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	var widgets: Array[InventorySlotUI] = []
	_top_up(grid, inventory, widgets, on_click)
	return widgets


func _build_widgets(grid: GridContainer, inventory: Inventory, on_click: Callable) -> Array[InventorySlotUI]:
	var widgets: Array[InventorySlotUI] = []
	_top_up(grid, inventory, widgets, on_click)
	return widgets


func _top_up(
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
