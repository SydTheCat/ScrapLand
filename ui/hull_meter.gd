extends Control
class_name HullMeter
## SCRAPLAND -- Chassis gauge. Bind with bind_hull(); do not reach into Hull.

@export_group("Fill Colours")
@export var color_sound: Color = Color(0.55, 0.82, 0.95)
@export var color_dented: Color = Color(0.96, 0.8, 0.35)
@export var color_damaged: Color = Color(0.95, 0.5, 0.22)
@export var color_critical: Color = Color(1.0, 0.28, 0.24)
@export var color_ruined: Color = Color(0.32, 0.3, 0.33)

@export var fill_speed: float = 8.0
@export var pulse_speed: float = 4.0

@onready var fill: ColorRect = $FillBar
@onready var percent_label: Label = $PercentLabel
@onready var status_label: Label = $StatusLabel

var _hull: Node
var _max_fill_width: float = 0.0
var _target_ratio: float = 1.0
var _shown_ratio: float = 1.0
var _pulse_time: float = 0.0


func _ready() -> void:
	_max_fill_width = fill.size.x
	if _max_fill_width <= 1.0:
		_max_fill_width = 200.0


func bind_hull(hull: Node) -> void:
	_hull = hull
	if hull.has_signal("integrity_changed"):
		hull.connect("integrity_changed", _on_integrity_changed)
	if hull.has_signal("state_changed"):
		hull.connect("state_changed", _on_state_changed)
	if hull.has_method("get_integrity") and hull.get("max_integrity") != null:
		_on_integrity_changed(float(hull.call("get_integrity")), float(hull.get("max_integrity")))
	_shown_ratio = _target_ratio
	_refresh_appearance()


func _process(delta: float) -> void:
	_shown_ratio = lerpf(_shown_ratio, _target_ratio, clampf(fill_speed * delta, 0.0, 1.0))
	fill.size.x = _max_fill_width * _shown_ratio
	if _is_critical():
		_pulse_time += delta * pulse_speed
		fill.modulate.a = lerpf(0.35, 1.0, absf(sin(_pulse_time * PI)))
	elif not is_equal_approx(fill.modulate.a, 1.0):
		fill.modulate.a = 1.0


func _on_integrity_changed(current: float, maximum: float) -> void:
	_target_ratio = clampf(current / maxf(maximum, 0.001), 0.0, 1.0)
	percent_label.text = "%d%%" % roundi(_target_ratio * 100.0)
	_refresh_appearance()


func _on_state_changed(_state: Variant, _previous: Variant) -> void:
	_refresh_appearance()


func _refresh_appearance() -> void:
	if _hull == null:
		return
	var state: Variant = _hull.call("get_state") if _hull.has_method("get_state") else 0
	var index := int(state)
	match index:
		0:
			fill.color = color_sound
			_set_status("HULL", color_sound)
		1:
			fill.color = color_dented
			_set_status("HULL DENTED", color_dented)
		2:
			fill.color = color_damaged
			_set_status("HULL DAMAGED", color_damaged)
		3:
			fill.color = color_critical
			_set_status("HULL CRITICAL", color_critical)
		_:
			fill.color = color_ruined
			_set_status("HULL RUINED", color_ruined)


func _is_critical() -> bool:
	if _hull == null or not _hull.has_method("get_state"):
		return false
	var index := int(_hull.call("get_state"))
	return index >= 3


func _set_status(text: String, color: Color) -> void:
	status_label.text = text
	status_label.add_theme_color_override(&"font_color", color)
