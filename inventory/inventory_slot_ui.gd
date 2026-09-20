extends Button
class_name InventorySlotUI
## SCRAPLAND -- One square in the inventory grid.
##
## A Button so hover, press and tooltips come for free. It displays whatever
## InventorySlot it is handed and reports hovers back to the inventory UI so the
## details panel can update.
##
## Until real item icons exist it draws the item's `color` as a solid swatch.
## The moment you assign an icon on an ItemData, the swatch is replaced by it
## with no code change.

signal slot_hovered(slot: InventorySlot)
## Emitted on an actual click, as opposed to a hover. The container screen uses
## this to move a stack across; the cargo hold screen ignores it.
signal slot_clicked(slot: InventorySlot)
## A hotbar stack was dropped on this cargo square.
signal stack_dropped(payload: Dictionary)

## Which cargo-hold index this square is, set by the inventory UI.
var index: int = -1

@onready var swatch: ColorRect = $Swatch
@onready var icon_rect: TextureRect = $Icon
@onready var count_label: Label = $Count

## The slot this square is currently showing. May be null.
var slot: InventorySlot
## Button click handling eats a normal drag start, so we begin the drag by hand
## once the mouse has moved far enough.
var _press_at: Vector2 = Vector2.INF


func _ready() -> void:
	mouse_entered.connect(_report_hover)
	pressed.connect(_on_pressed)
	gui_input.connect(_on_gui_input)


func display(new_slot: InventorySlot) -> void:
	slot = new_slot
	var is_empty: bool = new_slot == null or new_slot.is_empty()

	if is_empty:
		swatch.visible = false
		icon_rect.visible = false
		count_label.visible = false
		tooltip_text = ""
		return

	var item := new_slot.item
	var has_icon := item.icon != null

	swatch.visible = not has_icon
	swatch.color = item.color
	icon_rect.visible = has_icon
	icon_rect.texture = item.icon

	# A "1" on every single item is just noise.
	count_label.visible = new_slot.amount > 1
	count_label.text = str(new_slot.amount)

	tooltip_text = "%s\n%s" % [item.display_name, item.description]


func _get_drag_data(_at: Vector2) -> Variant:
	var payload := _make_drag_payload()
	if payload.is_empty():
		return null
	set_drag_preview(_make_item_preview(slot.item, Vector2(48, 48)))
	return payload


func _on_gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button and button.button_index == MOUSE_BUTTON_LEFT:
		_press_at = button.position if button.pressed else Vector2.INF
		return
	var motion := event as InputEventMouseMotion
	if motion == null or _press_at == Vector2.INF:
		return
	if motion.position.distance_to(_press_at) < 8.0:
		return
	var payload := _make_drag_payload()
	if payload.is_empty():
		return
	force_drag(payload, _make_item_preview(slot.item, Vector2(48, 48)))
	_press_at = Vector2.INF


func _make_item_preview(item: ItemData, size: Vector2) -> Control:
	if item and item.icon:
		var picture := TextureRect.new()
		picture.custom_minimum_size = size
		picture.texture = item.icon
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		return picture
	var swatch := ColorRect.new()
	swatch.custom_minimum_size = size
	swatch.color = item.color if item else Color(0.5, 0.5, 0.5)
	return swatch


func _make_drag_payload() -> Dictionary:
	if slot == null or slot.is_empty():
		return {}
	return {"item_id": slot.item.id, "from_hotbar": -1, "from_inventory": index}


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and int((data as Dictionary).get("from_hotbar", -1)) >= 0


func _drop_data(_at: Vector2, data: Variant) -> void:
	if data is Dictionary:
		stack_dropped.emit(data)


func _report_hover() -> void:
	slot_hovered.emit(slot)


## Clicking also selects, which makes the panel usable with a controller or on a
## touchscreen where there is no hover.
func _on_pressed() -> void:
	_report_hover()
	slot_clicked.emit(slot)
