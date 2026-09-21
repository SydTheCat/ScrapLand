extends Control
## SCRAPLAND -- Jetpack fuel gauge. Bind with bind_jetpack(); do not reach into the pack.

@export_group("Fill Colours")
@export var color_full: Color = Color(1.0, 0.62, 0.22)
@export var color_low: Color = Color(1.0, 0.28, 0.18)
@export var color_empty: Color = Color(0.34, 0.3, 0.32)
@export var color_thrust: Color = Color(1.0, 0.82, 0.35)
@export var color_refill: Color = Color(0.55, 0.9, 1.0)

@export var fill_speed: float = 18.0
@export var pulse_speed: float = 6.0

@onready var fill: ColorRect = $FillBar
@onready var percent_label: Label = $PercentLabel
@onready var status_label: Label = $StatusLabel

var _pack: Node
var _max_fill_width: float = 200.0
var _target_ratio: float = 1.0
var _shown_ratio: float = 1.0
var _pulse_time: float = 0.0
var _thrusting: bool = false


func _ready() -> void:
	if fill:
		_max_fill_width = maxf(fill.size.x, 200.0)


func bind_jetpack(pack: Node) -> void:
	_pack = pack
	if pack == null:
		return
	if pack.has_signal("fuel_changed"):
		pack.connect("fuel_changed", _on_fuel_changed)
	if pack.has_signal("burst_started"):
		pack.connect("burst_started", _on_burst_started)
	if pack.has_signal("burst_ended"):
		pack.connect("burst_ended", _on_burst_ended)
	_sync_from_pack()
	_shown_ratio = _target_ratio
	_refresh_appearance()


func _process(delta: float) -> void:
	_sync_from_pack()
	_shown_ratio = lerpf(_shown_ratio, _target_ratio, clampf(fill_speed * delta, 0.0, 1.0))
	if fill:
		fill.size.x = _max_fill_width * _shown_ratio
	if _thrusting:
		_pulse_time += delta * pulse_speed
		if fill:
			fill.modulate.a = lerpf(0.45, 1.0, absf(sin(_pulse_time * PI)))
	elif fill and not is_equal_approx(fill.modulate.a, 1.0):
		fill.modulate.a = 1.0


func _sync_from_pack() -> void:
	if _pack == null:
		return
	if _pack.has_method("is_bursting"):
		_thrusting = bool(_pack.call("is_bursting"))
	if _pack.has_method("get_fuel_ratio"):
		_target_ratio = clampf(float(_pack.call("get_fuel_ratio")), 0.0, 1.0)
	elif _pack.has_method("get_fuel"):
		var maximum := float(_pack.get("max_fuel")) if _pack.get("max_fuel") != null else 1.0
		_target_ratio = clampf(float(_pack.call("get_fuel")) / maxf(maximum, 0.001), 0.0, 1.0)
	if percent_label:
		percent_label.text = "%d%%" % roundi(_target_ratio * 100.0)
	_refresh_appearance()


func _on_fuel_changed(current: float, maximum: float) -> void:
	_target_ratio = clampf(current / maxf(maximum, 0.001), 0.0, 1.0)
	if percent_label:
		percent_label.text = "%d%%" % roundi(_target_ratio * 100.0)
	_refresh_appearance()


func _on_burst_started() -> void:
	_thrusting = true
	_refresh_appearance()


func _on_burst_ended() -> void:
	_thrusting = false
	_refresh_appearance()


func _refresh_appearance() -> void:
	if fill == null or status_label == null:
		return
	if _thrusting:
		fill.color = color_thrust
		_set_status("THRUST", color_thrust)
		return
	if _target_ratio <= 0.02:
		fill.color = color_empty
		_set_status("EMPTY", color_empty)
		return
	if _target_ratio < 0.999:
		if _target_ratio < 0.35:
			fill.color = color_low
			_set_status("LOW", color_low)
		else:
			fill.color = color_refill
			_set_status("REFILL", color_refill)
		return
	fill.color = color_full
	_set_status("JETPACK", color_full)


func _set_status(text: String, color: Color) -> void:
	status_label.text = text
	status_label.add_theme_color_override(&"font_color", color)
