extends CanvasLayer
## SCRAPLAND -- Regeneration bay upgrade screen. Opened with E at a working station.

@export var pause_player: bool = true

@onready var root: Control = $Root
@onready var slot_list: VBoxContainer = $Root/Frame/Margin/VBox/Body/Slots/Scroll/List
@onready var detail_name: Label = $Root/Frame/Margin/VBox/Body/Details/DetailName
@onready var detail_description: Label = $Root/Frame/Margin/VBox/Body/Details/DetailDescription
@onready var integrity_label: Label = $Root/Frame/Margin/VBox/Body/Details/Integrity
@onready var parts_list: VBoxContainer = $Root/Frame/Margin/VBox/Body/Details/PartsList
@onready var action_button: Button = $Root/Frame/Margin/VBox/Body/Details/ActionButton
@onready var status_label: Label = $Root/Frame/Margin/VBox/Body/Details/StatusLabel

var _player: Player
var _upgrades: RobotUpgrades
var _station: Node
var _selected_slot: String = "back"
var _rows: Dictionary = {}


func _ready() -> void:
	root.visible = false
	action_button.pressed.connect(_on_action_pressed)
	GameEvents.menu_opened.connect(_on_menu_opened)
	SaveManager.loaded.connect(close)
	_bind_player()
	_build_rows()


func _input(event: InputEvent) -> void:
	if not root.visible:
		return
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"interact"):
		close()
		get_viewport().set_input_as_handled()


func _bind_player() -> void:
	if _upgrades:
		return
	_player = get_tree().get_first_node_in_group(&"player") as Player
	if _player == null:
		return
	_upgrades = _player.get_node_or_null("Upgrades") as RobotUpgrades
	if _upgrades and not _upgrades.changed.is_connected(_refresh):
		_upgrades.changed.connect(_refresh)
	var inventory := _player.get_node_or_null("Inventory") as Inventory
	if inventory and not inventory.changed.is_connected(_refresh):
		inventory.changed.connect(_refresh)


func open_for(station: Node) -> void:
	_bind_player()
	if _rows.is_empty():
		_build_rows()
	if _upgrades == null or station == null:
		return
	if is_showing(station):
		close()
		return
	_station = station
	GameEvents.announce_menu_opened(self)
	root.visible = true
	_set_gameplay_input_enabled(false)
	_refresh()


func close() -> void:
	if not root.visible:
		return
	root.visible = false
	_station = null
	_set_gameplay_input_enabled(true)
	GameEvents.announce_menu_closed(self)
	var hotbar := _player.get_node_or_null("Hotbar") as Hotbar if _player else null
	if hotbar:
		hotbar.apply_selected()


func is_open() -> bool:
	return root != null and root.visible


func is_showing(station: Node) -> bool:
	return is_open() and _station == station


func _on_menu_opened(menu: Node) -> void:
	if menu != self and is_open():
		root.visible = false
		_station = null
		GameEvents.announce_menu_closed(self)


func _set_gameplay_input_enabled(enabled: bool) -> void:
	if _player == null:
		return
	if pause_player:
		_player.can_move = enabled
	_player.camera_rig.set_look_enabled(enabled)


func _build_rows() -> void:
	for child in slot_list.get_children():
		slot_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	if _upgrades == null:
		return
	for slot in _upgrades.get_slots():
		var row := Button.new()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.custom_minimum_size = Vector2(0, 40)
		row.focus_mode = Control.FOCUS_NONE
		row.pressed.connect(_select_slot.bind(slot))
		slot_list.add_child(row)
		_rows[slot] = row


func _select_slot(slot: String) -> void:
	_selected_slot = slot
	_refresh()


func _refresh() -> void:
	if _upgrades == null:
		return
	for slot in _upgrades.get_slots():
		var row := _rows.get(slot) as Button
		if row == null:
			continue
		var item := _upgrades.get_equipped_item(slot)
		var mark := " <" if slot == _selected_slot else ""
		if item:
			var pct := int(round(_upgrades.get_integrity_ratio(slot) * 100.0))
			row.text = "%s  —  %s  %d%%%s" % [slot.capitalize(), item.display_name, pct, mark]
			row.add_theme_color_override(&"font_color", item.color)
		else:
			row.text = "%s  —  empty%s" % [slot.capitalize(), mark]
			row.add_theme_color_override(&"font_color", Color(0.62, 0.66, 0.72))
	_refresh_details()


func _refresh_details() -> void:
	for child in parts_list.get_children():
		parts_list.remove_child(child)
		child.queue_free()

	var item := _upgrades.get_equipped_item(_selected_slot)
	if item:
		detail_name.text = item.display_name
		detail_name.add_theme_color_override(&"font_color", item.color)
		detail_description.text = item.description
		var pct := int(round(_upgrades.get_integrity_ratio(_selected_slot) * 100.0))
		integrity_label.text = "INTEGRITY  %d%%" % pct
		action_button.text = "Remove"
		action_button.disabled = false
		status_label.text = "Stand on the pad to restore damaged parts."
		return

	detail_name.text = "%s slot" % _selected_slot.capitalize()
	detail_name.add_theme_color_override(&"font_color", Color(0.9, 0.9, 0.92))
	detail_description.text = "Empty. Craft a part, then install it here."
	integrity_label.text = ""
	var parts := _upgrades.items_for_slot(_selected_slot)
	if parts.is_empty():
		action_button.text = "Install"
		action_button.disabled = true
		status_label.text = "No matching part in cargo."
		return
	for part in parts:
		var row := Button.new()
		row.text = part.display_name
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.pressed.connect(_install.bind(part))
		parts_list.add_child(row)
	action_button.text = "Install %s" % parts[0].display_name
	action_button.disabled = false
	status_label.text = "Choose a part below, or press Install for the first one."


func _on_action_pressed() -> void:
	if _upgrades.is_slot_filled(_selected_slot):
		_upgrades.uninstall(_selected_slot)
		return
	var parts := _upgrades.items_for_slot(_selected_slot)
	if not parts.is_empty():
		_install(parts[0])


func _install(item: ItemData) -> void:
	_upgrades.install(item)
