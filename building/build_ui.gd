extends CanvasLayer
class_name BuildUI
## SCRAPLAND -- The panel shown while build mode is on.
##
## A readout and nothing more: it handles no input and makes no decisions. The
## Builder finds it through the "build_ui" group and pushes text at it, so
## neither one holds a reference to the other in a scene file.

const OK_COLOR := Color(0.55, 1.0, 0.65, 1)
const BAD_COLOR := Color(1.0, 0.62, 0.4, 1)

@onready var root: Control = $Root
@onready var structure_label: Label = $Root/Frame/Margin/VBox/Structure
@onready var status_label: Label = $Root/Frame/Margin/VBox/Status
@onready var choices_label: Label = $Root/Frame/Margin/VBox/Choices

## The status arrives every physics frame, so the text is only touched when it
## actually says something new.
var _last_status: String = ""


func _ready() -> void:
	root.visible = false


func open() -> void:
	_last_status = ""
	root.visible = true


func close() -> void:
	root.visible = false


func is_open() -> bool:
	return root != null and root.visible


## What is about to be placed, how many are left, and the full list of choices
## with the current one marked.
func set_structure(display_name: String, count: int, choices: PackedStringArray, selected: int) -> void:
	structure_label.text = "%s   x%d" % [display_name, count]

	if choices.size() <= 1:
		choices_label.visible = false
		return

	# A plain Label has no per-word styling, so the selection is marked with
	# brackets rather than a colour.
	var parts := PackedStringArray()
	for i in choices.size():
		if i == selected:
			parts.append("[ %s ]" % choices[i])
		else:
			parts.append(choices[i])
	choices_label.text = "    ".join(parts)
	choices_label.visible = true


func set_status(ok: bool, message: String) -> void:
	if message == _last_status:
		return
	_last_status = message
	status_label.text = message
	status_label.add_theme_color_override(&"font_color", OK_COLOR if ok else BAD_COLOR)
