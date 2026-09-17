extends PanelContainer
class_name HotbarSlotUI
## SCRAPLAND -- One square on the HUD hotbar.
##
## Accepts a drag from the inventory (or from another hotbar square). Click
## selects it; right-click clears the assignment. The items themselves never
## leave the cargo hold.

signal slot_selected
signal slot_cleared
signal item_dropped(payload: Dictionary)

const KEY_COLOR := Color(0.62, 0.68, 0.75, 1)
const KEY_COLOR_SELECTED := Color(1, 0.8, 0.4, 1)

var index: int = 0
var _item_id: String = ""
var _key_caption: String = ""

var _key: Label
var _swatch: ColorRect
var _count: Label


func _ready() -> void:
	custom_minimum_size = Vector2(64, 64)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_children()
	gui_input.connect(_on_gui_input)
	display("", 0, false, false)


func setup(slot_index: int, key_caption: String) -> void:
	index = slot_index
	_key_caption = key_caption
	if _key:
		_key.text = key_caption


func display(item_id: String, count: int, selected: bool, available: bool) -> void:
	_item_id = item_id
	var item := ItemDB.get_item(item_id)
	var empty := item == null

	add_theme_stylebox_override(&"panel", _style_for(selected, not empty, available))
	if _key:
		_key.text = _key_caption
		_key.add_theme_color_override(&"font_color", KEY_COLOR_SELECTED if selected else KEY_COLOR)

	if empty:
		_swatch.visible = false
		_count.visible = false
		tooltip_text = "Drag an item here to take it out of the cargo hold."
		return

	_swatch.visible = true
	_swatch.color = item.color
	if not available:
		_swatch.color = _swatch.color.darkened(0.45)
	_count.visible = count > 1
	_count.text = str(count)
	tooltip_text = item.display_name


func _get_drag_data(_at: Vector2) -> Variant:
	if _item_id.is_empty():
		return null
	_set_preview(_item_id)
	return {"item_id": _item_id, "from_hotbar": index, "from_inventory": -1}


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and not String((data as Dictionary).get("item_id", "")).is_empty()


func _drop_data(_at: Vector2, data: Variant) -> void:
	if data is Dictionary:
		item_dropped.emit(data)


func _on_gui_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse == null or not mouse.pressed:
		return
	if mouse.button_index == MOUSE_BUTTON_LEFT:
		slot_selected.emit()
	elif mouse.button_index == MOUSE_BUTTON_RIGHT:
		slot_cleared.emit()


func _build_children() -> void:
	_swatch = ColorRect.new()
	_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_swatch.set_anchors_preset(Control.PRESET_FULL_RECT)
	_swatch.offset_left = 10
	_swatch.offset_top = 16
	_swatch.offset_right = -10
	_swatch.offset_bottom = -10
	add_child(_swatch)

	_key = Label.new()
	_key.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_key.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_key.offset_bottom = 16
	_key.add_theme_font_size_override(&"font_size", 11)
	_key.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.9))
	_key.add_theme_constant_override(&"outline_size", 4)
	add_child(_key)

	_count = Label.new()
	_count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_count.set_anchors_preset(Control.PRESET_FULL_RECT)
	_count.offset_left = 4
	_count.offset_top = 4
	_count.offset_right = -5
	_count.offset_bottom = -3
	_count.add_theme_font_size_override(&"font_size", 13)
	_count.add_theme_color_override(&"font_color", Color(1, 1, 1, 1))
	_count.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.9))
	_count.add_theme_constant_override(&"outline_size", 5)
	add_child(_count)


func _set_preview(item_id: String) -> void:
	var item := ItemDB.get_item(item_id)
	var preview := ColorRect.new()
	preview.custom_minimum_size = Vector2(40, 40)
	preview.color = item.color if item else Color(0.5, 0.5, 0.5)
	set_drag_preview(preview)


func _style_for(selected: bool, filled: bool, available: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(6)
	style.set_content_margin_all(4)
	if selected:
		style.bg_color = Color(0.16, 0.2, 0.26, 0.92)
		style.border_color = Color(1, 0.75, 0.3, 1)
		style.set_border_width_all(2)
	elif filled and available:
		style.bg_color = Color(0.05, 0.06, 0.08, 0.78)
		style.border_color = Color(0.35, 0.38, 0.44, 1)
		style.set_border_width_all(1)
	else:
		style.bg_color = Color(0.04, 0.04, 0.05, 0.55)
		style.border_color = Color(0.22, 0.24, 0.28, 1)
		style.set_border_width_all(1)
	return style
