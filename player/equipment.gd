extends Node
class_name Equipment
## SCRAPLAND -- Which tool is actually in the robot's hand.
##
## The tools are this node's own children. The hotbar decides *which* item is
## selected; this script only turns the matching PlayerTool on or off. Number
## keys live on the hotbar, not here.
##
## Note on naming: "tool" is a reserved word in GDScript 2.0, hence tool_node
## throughout this file.

signal equipped_changed(tool_node: PlayerTool, index: int)
signal availability_changed

const EQUIP_COLOR := Color(0.75, 0.9, 1.0)

var _tools: Array[PlayerTool] = []
var _equipped_index: int = -1

@onready var _inventory: Inventory = get_parent().get_node_or_null("Inventory") as Inventory
@onready var _hotbar: Hotbar = get_parent().get_node_or_null("Hotbar") as Hotbar


func _ready() -> void:
	for child in get_children():
		var tool_node := child as PlayerTool
		if tool_node:
			_tools.append(tool_node)

	if _tools.is_empty():
		push_warning("equipment.gd: no PlayerTool children; the robot has no tools.")
		return

	if _inventory:
		_inventory.changed.connect(_on_inventory_changed)
	if _hotbar:
		_hotbar.changed.connect(_on_inventory_changed)
	# Nothing in the hand until the hotbar says so.
	unequip()


func is_owned(tool_node: PlayerTool) -> bool:
	if tool_node == null or tool_node.item_id.is_empty():
		return false
	# The item has to be on the bar. Sitting in the backpack is not enough.
	if _hotbar and _hotbar.count(tool_node.item_id) > 0:
		return true
	return false


func get_tools() -> Array[PlayerTool]:
	return _tools


func get_equipped_index() -> int:
	return _equipped_index


func get_equipped() -> PlayerTool:
	if _equipped_index < 0 or _equipped_index >= _tools.size():
		return null
	return _tools[_equipped_index]


func find_for_item(item_id: String) -> PlayerTool:
	if item_id.is_empty():
		return null
	for tool_node in _tools:
		if tool_node.item_id == item_id:
			return tool_node
	return null


func equip_tool(tool_node: PlayerTool) -> void:
	if tool_node == null or not is_owned(tool_node):
		unequip()
		return
	var index := _tools.find(tool_node)
	if index < 0:
		return
	_equip(index)


func unequip() -> void:
	var previous := get_equipped()
	if previous:
		previous.set_equipped(false)
	_equipped_index = -1
	equipped_changed.emit(null, -1)


func _equip(index: int) -> void:
	if index == _equipped_index:
		return
	var previous := get_equipped()
	if previous:
		previous.set_equipped(false)

	_equipped_index = index
	var tool_node := _tools[index]
	tool_node.set_equipped(true)
	equipped_changed.emit(tool_node, index)


func _on_inventory_changed() -> void:
	var tool_node := get_equipped()
	if tool_node and not is_owned(tool_node):
		unequip()
	availability_changed.emit()
