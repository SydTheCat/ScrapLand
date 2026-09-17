extends CanvasLayer
class_name InventoryUI
## SCRAPLAND -- The cargo hold screen, toggled with Tab.
##
## Builds one InventorySlotUI per inventory slot, then redraws whenever the
## inventory reports a change. It owns no game state: everything it shows is
## read from the player's Inventory node.
##
## While it is open the robot stops moving and the mouse is released, so the
## grid can be used with the cursor.

@export_group("Setup")
## The square drawn for each slot. Defaults to inventory_slot_ui.tscn.
@export var slot_scene: PackedScene
@export var columns: int = 5

@export_group("Behaviour")
## Freeze the robot while the panel is open. Turn off if you would rather keep
## walking with the inventory up.
@export var pause_player: bool = true

@onready var root: Control = $Root
@onready var grid: GridContainer = $Root/Frame/Margin/VBox/Body/Grid
@onready var capacity_label: Label = $Root/Frame/Margin/VBox/Header/Capacity
@onready var detail_name: Label = $Root/Frame/Margin/VBox/Body/Details/DetailName
@onready var detail_meta: Label = $Root/Frame/Margin/VBox/Body/Details/DetailMeta
@onready var detail_description: Label = $Root/Frame/Margin/VBox/Body/Details/DetailDescription
@onready var use_button: Button = $Root/Frame/Margin/VBox/Body/Details/UseButton

var _player: Player
var _inventory: Inventory
var _item_user: ItemUser
var _slot_widgets: Array[InventorySlotUI] = []
## The item shown in the details panel, i.e. what the Use button acts on.
var _detailed_item: ItemData


func _ready() -> void:
	root.visible = false
	grid.columns = columns
	use_button.pressed.connect(_on_use_pressed)
	# Only one full-screen menu at a time.
	GameEvents.menu_opened.connect(_on_menu_opened)

	_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		push_warning("inventory_ui.gd: no node in the 'player' group.")
		return

	_inventory = _player.get_node_or_null("Inventory") as Inventory
	_item_user = _player.get_node_or_null("ItemUser") as ItemUser
	if _inventory == null:
		push_warning("inventory_ui.gd: the player has no Inventory child.")
		return

	_inventory.changed.connect(_refresh)
	_build_slot_widgets()
	_refresh()
	_show_placeholder_details()


## Handled in _input (not _unhandled_input) so focused Buttons cannot swallow
## Tab for their own focus navigation.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"inventory"):
		toggle()
		get_viewport().set_input_as_handled()
	elif root.visible and event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


# --- Open / close -----------------------------------------------------------

func toggle() -> void:
	if root.visible:
		close()
	else:
		open()


func open() -> void:
	if _inventory == null:
		return
	# Announce first so any other open menu closes before we take the mouse.
	GameEvents.announce_menu_opened(self)
	_refresh()
	root.visible = true
	_set_gameplay_input_enabled(false)


func close() -> void:
	if not root.visible:
		return
	root.visible = false
	_show_placeholder_details()
	_set_gameplay_input_enabled(true)
	GameEvents.announce_menu_closed(self)
	var hotbar := _player.get_node_or_null("Hotbar") as Hotbar if _player else null
	if hotbar:
		hotbar.apply_selected()


func is_open() -> bool:
	return root != null and root.visible


## Another menu took over. Just hide -- the menu that is opening owns the mouse
## from here, so we must not hand it back.
func _on_menu_opened(menu: Node) -> void:
	if menu != self and is_open():
		root.visible = false
		GameEvents.announce_menu_closed(self)


## Releasing the mouse and freezing the robot are the same operation from the
## panel's point of view, so they live together.
func _set_gameplay_input_enabled(enabled: bool) -> void:
	if _player == null:
		return
	if pause_player:
		_player.can_move = enabled
	# The camera rig owns the mouse capture state.
	_player.camera_rig.set_look_enabled(enabled)


# --- Building and refreshing ------------------------------------------------

func _build_slot_widgets() -> void:
	for i in _inventory.get_slots().size():
		_add_slot_widget()


## Redraws every square. With 20 slots this is cheap enough to do wholesale
## rather than tracking which one changed.
func _refresh() -> void:
	if _inventory == null:
		return

	# The inventory can grow or shrink (backpack upgrades).
	_sync_slot_widgets()

	var slots := _inventory.get_slots()
	for i in _slot_widgets.size():
		_slot_widgets[i].display(slots[i] if i < slots.size() else null)

	capacity_label.text = "%d / %d slots used" % [_inventory.get_used_slot_count(), slots.size()]


func _sync_slot_widgets() -> void:
	var needed := _inventory.get_slots().size()
	while _slot_widgets.size() < needed:
		_add_slot_widget()
	while _slot_widgets.size() > needed:
		var widget := _slot_widgets.pop_back() as InventorySlotUI
		if widget:
			grid.remove_child(widget)
			widget.queue_free()


func _add_slot_widget() -> void:
	var scene := slot_scene
	if scene == null:
		scene = load("res://inventory/inventory_slot_ui.tscn") as PackedScene
	var widget := scene.instantiate() as InventorySlotUI
	widget.index = _slot_widgets.size()
	widget.slot_hovered.connect(_on_slot_hovered)
	widget.stack_dropped.connect(_on_stack_dropped.bind(widget.index))
	grid.add_child(widget)
	_slot_widgets.append(widget)


# --- Details panel ----------------------------------------------------------

func _on_slot_hovered(slot: InventorySlot) -> void:
	if slot == null or slot.is_empty():
		_show_placeholder_details()
		return

	var item := slot.item
	_detailed_item = item
	detail_name.text = item.display_name
	detail_name.add_theme_color_override(&"font_color", item.color)
	detail_meta.text = "%s   ·   %d / %d per stack" % [item.get_category_name(), slot.amount, item.max_stack]
	detail_description.text = item.description
	# Nothing else on screen mentions build mode, so a buildable item says so
	# itself. Read straight off the item data, so this needs no help from the
	# Builder.
	if item.is_placeable() or item.category == ItemData.Category.TOOL:
		detail_description.text += "\n\nDrag this onto the hotbar to take it out of the cargo hold, then press 1–9 or 0 to use it."
	if item.is_placeable():
		detail_description.text += " Hold the salvage beam on a placed one to pack it back up."
	# Only consumables (anything with an effect) get a Use button.
	use_button.visible = _item_user != null and item.is_usable()


func _show_placeholder_details() -> void:
	_detailed_item = null
	use_button.visible = false
	detail_name.text = "Cargo Hold"
	detail_name.add_theme_color_override(&"font_color", Color(0.85, 0.88, 0.92))
	detail_meta.text = "Hover a slot for details"
	detail_description.text = "Everything you have managed to pick up. Drag an item onto the hotbar to take it with you. Drag it back to put it away."


func _on_stack_dropped(payload: Dictionary, dest_index: int) -> void:
	var hotbar := _player.get_node_or_null("Hotbar") as Hotbar if _player else null
	if hotbar == null:
		return
	var from_hotbar := int(payload.get("from_hotbar", -1))
	if from_hotbar >= 0:
		hotbar.return_to_inventory(from_hotbar, dest_index)


func _on_use_pressed() -> void:
	if _item_user == null or _detailed_item == null:
		return
	_item_user.use(_detailed_item)
	_refresh()
	# The last one may have just been consumed.
	if _inventory.count(_detailed_item.id) <= 0:
		_show_placeholder_details()
