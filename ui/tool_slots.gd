extends Control
class_name HotbarUI
## SCRAPLAND -- The ten-slot bar along the bottom of the screen.
##
## Purely a view of player/hotbar.gd plus a drop target while the cargo hold is
## open. Number keys and the actual equip/place decisions live on the Hotbar.

@onready var row: HBoxContainer = $Row

var _hotbar: Hotbar
var _slots: Array[HotbarSlotUI] = []


func bind_hotbar(hotbar: Hotbar) -> void:
	_hotbar = hotbar
	hotbar.changed.connect(refresh)
	if _slots.is_empty():
		_build_slots()
	refresh()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", 6)
	if _slots.is_empty():
		_build_slots()


func _process(_delta: float) -> void:
	# While the mouse is free (inventory, crafting) the squares have to catch
	# drags. While it is captured they must ignore it so look is not stolen.
	var interactive := Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	var filter := Control.MOUSE_FILTER_STOP if interactive else Control.MOUSE_FILTER_IGNORE
	mouse_filter = filter
	row.mouse_filter = filter
	for slot_ui in _slots:
		slot_ui.mouse_filter = filter


func refresh() -> void:
	if _hotbar == null:
		return
	if _slots.is_empty():
		_build_slots()
	var selected := _hotbar.get_selected_index()
	for i in _slots.size():
		var item_id := _hotbar.get_slot_id(i)
		var count := _hotbar.get_count(i)
		_slots[i].display(item_id, count, i == selected, count > 0)


func _build_slots() -> void:
	for child in row.get_children():
		row.remove_child(child)
		child.queue_free()
	_slots.clear()
	for i in Hotbar.SLOT_COUNT:
		var slot_ui := HotbarSlotUI.new()
		var key := "0" if i == 9 else str(i + 1)
		row.add_child(slot_ui)
		slot_ui.setup(i, key)
		slot_ui.slot_selected.connect(_on_slot_selected.bind(i))
		slot_ui.slot_cleared.connect(_on_slot_cleared.bind(i))
		slot_ui.item_dropped.connect(_on_item_dropped.bind(i))
		_slots.append(slot_ui)


func _on_slot_selected(index: int) -> void:
	if _hotbar:
		_hotbar.select(index)


func _on_slot_cleared(index: int) -> void:
	if _hotbar:
		_hotbar.return_anywhere(index)


func _on_item_dropped(payload: Dictionary, index: int) -> void:
	if _hotbar == null:
		return
	var from_hotbar := int(payload.get("from_hotbar", -1))
	var from_inventory := int(payload.get("from_inventory", -1))
	if from_hotbar >= 0:
		_hotbar.swap_slots(from_hotbar, index)
	elif from_inventory >= 0:
		_hotbar.take_from_inventory(from_inventory, index)
